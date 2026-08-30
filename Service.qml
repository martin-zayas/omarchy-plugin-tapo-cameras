import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// TAPO Cameras service: RTSP playback in a floating PiP layer-shell window.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: "martin-zayas-tapo-cameras"
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/martin-zayas-tapo-cameras"
  readonly property string statePath: stateDir + "/state.json"
  readonly property string credPath: stateDir + "/credentials.json"

  readonly property int maxStateBytes: 262144
  readonly property int maxNameLength: 256
  readonly property int maxHostLength: 253
  readonly property int maxPathLength: 128
  readonly property int maxCameras: 32
  readonly property int helperSeconds: 5
  readonly property var timeoutPrefix: ["timeout", "-k", "1", String(root.helperSeconds)]

  readonly property var pluginConfig: {
    var cfg = shell && shell.shellConfig ? shell.shellConfig : null
    if (!cfg || !Array.isArray(cfg.plugins)) return ({})
    for (var i = 0; i < cfg.plugins.length; i++) {
      var e = cfg.plugins[i]
      if (e && String(e.id).replace(/^@/, "") === pluginId) return e
    }
    return ({})
  }

  function cfg(name, fallback) {
    var v = pluginConfig ? pluginConfig[name] : undefined
    return (v === undefined || v === null) ? fallback : v
  }

  function safeName(v, fallback) {
    var t = String(v === null || v === undefined ? "" : v).trim()
    if (t === "" || t.length > root.maxNameLength) return fallback
    return t
  }

  function safeId(v) {
    var t = String(v || "").trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "")
    if (t === "" || t.length > root.maxNameLength) return ""
    return t
  }

  function safeHost(v) {
    var t = String(v || "").trim()
    if (t === "" || t.length > root.maxHostLength) return ""
    return t
  }

  function safeStreamPath(v) {
    var t = String(v || "").trim()
    if (t === "") return "/stream2"
    if (!t.startsWith("/")) t = "/" + t
    if (t.length > root.maxPathLength) return "/stream2"
    return t
  }

  function safePort(v) {
    var n = parseInt(v, 10)
    if (isNaN(n) || n < 1 || n > 65535) return 554
    return n
  }

  // Runtime state
  property var cameras: []
  property string activeCameraId: ""
  property bool enabled: false
  property bool pipVisible: true
  property int pipX: -1
  property int pipY: -1
  property int pipWidth: 640
  property int pipHeight: 360
  property string pipScreen: ""
  property bool pauseOnFullscreen: false
  property bool autoReconnect: true
  property bool hqStream: false
  property bool pipMaximized: false
  property int pipRestoreX: 1200
  property int pipRestoreY: 80
  property int pipRestoreWidth: 640
  property int pipRestoreHeight: 360
  property bool manualPaused: false
  property string streamState: "stopped"   // stopped | playing | paused | disconnected | error
  property var credentials: ({})
  property bool _stateLoaded: false
  property bool _credsLoaded: false
  property string _seedSig: ""

  function activeCamera() {
    var id = String(root.activeCameraId || "")
    for (var i = 0; i < root.cameras.length; i++) {
      if (String(root.cameras[i].id) === id) return root.cameras[i]
    }
    return null
  }

  function activeCameraName() {
    var c = activeCamera()
    return c ? String(c.name || c.id || "") : ""
  }

  function encodeUserInfo(s) {
    return encodeURIComponent(String(s || ""))
  }

  function playbackStreamPath(path) {
    var p = safeStreamPath(path)
    if (root.hqStream && p === "/stream2") return "/stream1"
    return p
  }

  function buildRtspUrl(camera) {
    if (!camera) return ""
    var host = safeHost(camera.host)
    if (host === "") return ""
    var port = safePort(camera.port)
    var path = playbackStreamPath(camera.path)
    var user = encodeUserInfo(camera.username)
    var pass = encodeUserInfo(root.credentials[String(camera.id)] || "")
    if (user !== "" || pass !== "") {
      return "rtsp://" + user + ":" + pass + "@" + host + ":" + port + path
    }
    return "rtsp://" + host + ":" + port + path
  }

  readonly property string activeRtspUrl: {
    var c = activeCamera()
    return c ? buildRtspUrl(c) : ""
  }

  function pipScreenInfo() {
    var want = String(root.pipScreen || "")
    var screens = Quickshell.screens
    if (want !== "") {
      for (var i = 0; i < screens.length; i++) {
        if (String(screens[i].name) === want) return screens[i]
      }
    }
    return screens.length > 0 ? screens[0] : null
  }

  readonly property bool pipMonFullscreen: root.pauseOnFullscreen
    && pipScreenInfo()
    && (root.fullscreenMonitors[String(pipScreenInfo().name)] === true)

  readonly property bool shouldPlay: root.enabled
    && root.pipVisible
    && root.activeRtspUrl !== ""
    && !root.manualPaused
    && !root.pipMonFullscreen

  readonly property bool rendering: root.enabled && root.pipVisible && root.activeRtspUrl !== ""
    && (root.streamState === "playing" || root.streamState === "paused" || root.streamState === "disconnected")

  function normalizeCameras(list) {
    var out = []
    if (!Array.isArray(list)) return out
    for (var i = 0; i < list.length && out.length < root.maxCameras; i++) {
      var c = list[i]
      if (!c || typeof c !== "object") continue
      var id = safeId(c.id) || safeId(c.name) || ("cam-" + (i + 1))
      var name = safeName(c.name, id)
      var host = safeHost(c.host)
      if (host === "") continue
      out.push({
        id: id,
        name: name,
        host: host,
        port: safePort(c.port),
        path: safeStreamPath(c.path),
        username: safeName(c.username, "")
      })
    }
    return out
  }

  function persistState() {
    var payload = JSON.stringify({
      cameras: root.cameras,
      activeCameraId: root.activeCameraId,
      enabled: root.enabled,
      pipVisible: root.pipVisible,
      pipX: root.pipX,
      pipY: root.pipY,
      pipWidth: root.pipWidth,
      pipHeight: root.pipHeight,
      pipScreen: root.pipScreen,
      pauseOnFullscreen: root.pauseOnFullscreen,
      autoReconnect: root.autoReconnect,
      hqStream: root.hqStream,
      pipMaximized: root.pipMaximized,
      pipRestoreX: root.pipRestoreX,
      pipRestoreY: root.pipRestoreY,
      pipRestoreWidth: root.pipRestoreWidth,
      pipRestoreHeight: root.pipRestoreHeight
    }, null, 2) + "\n"
    root.writeFile(root.statePath, payload)
  }

  function persistCredentials() {
    var payload = JSON.stringify(root.credentials || ({}), null, 2) + "\n"
    root.writeFile(root.credPath, payload)
  }

  function applyStateText(txt) {
    var t = String(txt || "").trim()
    if (!t) return false
    if (t.length > root.maxStateBytes) {
      console.warn("tapo-cameras: state.json too large, ignoring")
      return false
    }
    try {
      var o = JSON.parse(t)
      if (!o || typeof o !== "object") return false
      if (o.cameras !== undefined) root.cameras = normalizeCameras(o.cameras)
      if (o.activeCameraId !== undefined) root.activeCameraId = safeId(o.activeCameraId)
      if (o.enabled !== undefined) root.enabled = (o.enabled === true || String(o.enabled) === "true")
      if (o.pipVisible !== undefined) root.pipVisible = (o.pipVisible !== false && String(o.pipVisible) !== "false")
      if (o.pipX !== undefined) root.pipX = Math.max(0, parseInt(o.pipX, 10) || 0)
      if (o.pipY !== undefined) root.pipY = Math.max(0, parseInt(o.pipY, 10) || 0)
      if (o.pipWidth !== undefined) root.pipWidth = Math.max(160, parseInt(o.pipWidth, 10) || 640)
      if (o.pipHeight !== undefined) root.pipHeight = Math.max(90, parseInt(o.pipHeight, 10) || 360)
      if (o.hqStream !== undefined) root.hqStream = (o.hqStream === true || String(o.hqStream) === "true")
      if (o.pipMaximized !== undefined) root.pipMaximized = (o.pipMaximized === true || String(o.pipMaximized) === "true")
      if (o.pipRestoreX !== undefined) root.pipRestoreX = Math.max(0, parseInt(o.pipRestoreX, 10) || 0)
      if (o.pipRestoreY !== undefined) root.pipRestoreY = Math.max(0, parseInt(o.pipRestoreY, 10) || 0)
      if (o.pipRestoreWidth !== undefined) root.pipRestoreWidth = Math.max(160, parseInt(o.pipRestoreWidth, 10) || 640)
      if (o.pipRestoreHeight !== undefined) root.pipRestoreHeight = Math.max(90, parseInt(o.pipRestoreHeight, 10) || 360)
      if (o.pipScreen !== undefined) root.pipScreen = safeName(o.pipScreen, "")
      if (o.pauseOnFullscreen !== undefined) {
        root.pauseOnFullscreen = (o.pauseOnFullscreen === true || String(o.pauseOnFullscreen) === "true")
      }
      if (o.autoReconnect !== undefined) {
        root.autoReconnect = (o.autoReconnect !== false && String(o.autoReconnect) !== "false")
      }
      if (root.pipMaximized) root.applyPipMaximizedLayout()
      else root.normalizePipPosition()
      return true
    } catch (e) {
      console.warn("tapo-cameras: bad state.json:", e)
    }
    return false
  }

  function applyCredText(txt) {
    var t = String(txt || "").trim()
    if (!t) return false
    if (t.length > root.maxStateBytes) return false
    try {
      var o = JSON.parse(t)
      if (!o || typeof o !== "object" || Array.isArray(o)) return false
      var out = ({})
      var n = 0
      for (var k in o) {
        if (n >= root.maxCameras) break
        var id = safeId(k)
        if (id === "") continue
        out[id] = String(o[k] || "")
        n++
      }
      root.credentials = out
      return true
    } catch (e) {
      console.warn("tapo-cameras: bad credentials.json:", e)
    }
    return false
  }

  function syncSeedFromConfig() {
    var seeded = normalizeCameras(cfg("cameras", []))
    var sig = JSON.stringify(seeded)
    if (!root._stateLoaded) return
    if (root._seedSig === "") {
      root._seedSig = sig
      if (root.cameras.length === 0 && seeded.length > 0) root.cameras = seeded
      if (!root.activeCameraId && seeded.length > 0) root.activeCameraId = seeded[0].id
      persistState()
      return
    }
    if (sig !== root._seedSig && seeded.length > 0) {
      root._seedSig = sig
      root.cameras = seeded
      persistState()
    }
  }

  onPluginConfigChanged: syncSeedFromConfig()

  Process {
    id: stateReadProc
    command: root.timeoutPrefix.concat(
      ["bash", "-c",
       'if [ -L "$2" ] || [ ! -f "$2" ]; then exit 0; fi; ' +
       'head -c "$1" -- "$2" 2>/dev/null || true',
       "_", String(root.maxStateBytes + 1), root.statePath])
    stdout: StdioCollector {
      onStreamFinished: root.finishStateLoad(text())
    }
    onExited: stateReadFallback.restart()
  }

  Timer {
    id: stateReadFallback
    interval: 250
    onTriggered: root.finishStateLoad("")
  }

  function finishStateLoad(txt) {
    if (root._stateLoaded) return
    root.applyStateText(txt)
    root._stateLoaded = true
    root.syncSeedFromConfig()
    if (root._credsLoaded) root.syncStream()
  }

  Process {
    id: credReadProc
    command: root.timeoutPrefix.concat(
      ["bash", "-c",
       'if [ -L "$2" ] || [ ! -f "$2" ]; then exit 0; fi; ' +
       'head -c "$1" -- "$2" 2>/dev/null || true',
       "_", String(root.maxStateBytes + 1), root.credPath])
    stdout: StdioCollector {
      onStreamFinished: root.finishCredLoad(text())
    }
    onExited: credReadFallback.restart()
  }

  Timer {
    id: credReadFallback
    interval: 250
    onTriggered: root.finishCredLoad("")
  }

  function finishCredLoad(txt) {
    if (root._credsLoaded) return
    root.applyCredText(txt)
    root._credsLoaded = true
    if (root._stateLoaded) root.syncStream()
  }

  Process {
    id: fileWriteProc
    onExited: if (root._pendingWrite.path !== "") {
      var w = root._pendingWrite
      root._pendingWrite = ({ path: "", payload: "" })
      root.writeFile(w.path, w.payload)
    }
  }

  property var _pendingWrite: ({ path: "", payload: "" })

  function writeFile(path, payload) {
    if (fileWriteProc.running) {
      root._pendingWrite = { path: path, payload: payload }
      return
    }
    fileWriteProc.command = root.timeoutPrefix.concat(["bash", "-c",
      'd=$(dirname -- "$1"); mkdir -p -- "$d" || exit 1; ' +
      't=$(mktemp -- "$1.XXXXXX") || exit 1; ' +
      'printf %s "$2" > "$t" && chmod 600 -- "$t" && mv -f -- "$t" "$1" || { rm -f -- "$t"; exit 1; }',
      "_", path, payload])
    fileWriteProc.running = true
  }

  Process {
    id: mkStateDir
    command: root.timeoutPrefix.concat(["mkdir", "-p", root.stateDir])
    onExited: {
      stateReadProc.running = true
      credReadProc.running = true
    }
  }

  Component.onCompleted: mkStateDir.running = true

  // Fullscreen watch (same pattern as Motion Wallpaper)
  property var fullscreenMonitors: ({})

  readonly property string fsScript:
    "import json,subprocess\n" +
    "def q(c):\n" +
    "    return json.loads(subprocess.check_output(['hyprctl','-j',c]))\n" +
    "try:\n" +
    "    mons=q('monitors'); wss=q('workspaces')\n" +
    "    fs={w.get('id'): bool(w.get('hasfullscreen')) for w in wss}\n" +
    "    for m in mons:\n" +
    "        aw=m.get('activeWorkspace') or {}\n" +
    "        if fs.get(aw.get('id')):\n" +
    "            print(m.get('name'))\n" +
    "except Exception:\n" +
    "    pass\n"

  function refreshFullscreen() {
    if (fsProc.running) { fsDebounce.restart(); return }
    fsProc.running = true
  }

  Process {
    id: fsProc
    command: root.timeoutPrefix.concat(["python3", "-c", root.fsScript])
    stdout: StdioCollector {
      onStreamFinished: {
        var set = ({})
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var n = lines[i].trim()
          if (n) set[n] = true
        }
        root.fullscreenMonitors = set
      }
    }
  }

  Timer {
    id: fsDebounce
    interval: 120
    repeat: false
    onTriggered: root.refreshFullscreen()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      switch (event.name) {
        case "fullscreen":
        case "fullscreenv2":
        case "activewindow":
        case "activewindowv2":
        case "openwindow":
        case "closewindow":
        case "workspace":
        case "workspacev2":
        case "focusedmon":
        case "focusedmonv2":
          fsDebounce.restart()
          break
      }
    }
  }

  Timer { interval: 400; running: true; repeat: false; onTriggered: root.refreshFullscreen() }

  function pipBorderThickness() {
    return Math.max(1, Style.space(2)) * 2
  }

  function anchorPipTopRight() {
    var s = pipScreenInfo()
    if (!s) return
    var margin = Style.gapsOut
    var borderW = pipBorderThickness()
    root.pipX = Math.max(margin, (s.width || 1920) - root.pipWidth - borderW - margin)
    root.pipY = margin
  }

  function normalizePipPosition() {
    if (root.pipMaximized) {
      root.applyPipMaximizedLayout()
      return
    }
    if (root.pipX < 0 || root.pipY < 0 || (root.pipX === 1200 && root.pipY === 80)) {
      root.anchorPipTopRight()
    }
    root.clampPipToScreen()
  }

  function pipChromeHeight() {
    return pipBorderThickness()
  }

  function applyPipMaximizedLayout() {
    var s = pipScreenInfo()
    if (!s) return
    var margin = Style.gapsOut
    var chromeV = pipChromeHeight()
    root.pipX = margin
    root.pipY = margin
    root.pipWidth = Math.max(160, (s.width || 1920) - margin * 2)
    root.pipHeight = Math.max(90, (s.height || 1080) - margin * 2 - chromeV)
  }

  function togglePipMaximize() {
    if (!root.pipMaximized) {
      root.pipRestoreX = root.pipX
      root.pipRestoreY = root.pipY
      root.pipRestoreWidth = root.pipWidth
      root.pipRestoreHeight = root.pipHeight
      root.pipMaximized = true
      root.applyPipMaximizedLayout()
    } else {
      root.pipMaximized = false
      root.pipX = root.pipRestoreX
      root.pipY = root.pipRestoreY
      root.pipWidth = root.pipRestoreWidth
      root.pipHeight = root.pipRestoreHeight
      root.clampPipToScreen()
    }
    root.persistState()
  }

  function clampPipToScreen() {
    var s = pipScreenInfo()
    if (!s) return
    var sw = s.width || 1920
    var sh = s.height || 1080
    var borderV = pipBorderThickness()
    if (root.pipX + root.pipWidth + borderV > sw) root.pipX = Math.max(0, sw - root.pipWidth - borderV)
    if (root.pipY + root.pipHeight + borderV > sh) root.pipY = Math.max(0, sh - root.pipHeight - borderV)
  }

  function setPipSizePreset(preset) {
    root.pipMaximized = false
    switch (String(preset || "M").toUpperCase()) {
      case "S":
        root.pipWidth = 480
        root.pipHeight = 270
        break
      case "L":
        root.pipWidth = 960
        root.pipHeight = 540
        break
      default:
        root.pipWidth = 640
        root.pipHeight = 360
        break
    }
    clampPipToScreen()
    persistState()
  }

  function pipDragModifiersActive(modifiers) {
    // Super/Mod4 may be consumed by Hyprland before it reaches layer-shell surfaces.
    // Accept drag when modifiers are present, or when none are reported (Wayland fallback).
    return (modifiers & Qt.MetaModifier)
      || (modifiers & Qt.ControlModifier)
      || modifiers === Qt.NoModifier
  }

  function syncStream() {
    if (!pipPlayer) return
    var url = root.activeRtspUrl
    if (!root.shouldPlay || url === "") {
      if (url === "" || !root.enabled) {
        pipPlayer.stop()
        pipPlayer.source = ""
        root.streamState = "stopped"
        reconnectTimer.stop()
        return
      }
      if (pipPlayer.playbackState === MediaPlayer.PlayingState) pipPlayer.pause()
      root.streamState = root.manualPaused ? "paused" : "paused"
      return
    }
    if (pipPlayer.source !== url) {
      pipPlayer.source = url
    }
    if (pipPlayer.playbackState !== MediaPlayer.PlayingState) pipPlayer.play()
    root.streamState = "playing"
  }

  onEnabledChanged: syncStream()
  onPipVisibleChanged: syncStream()
  onActiveRtspUrlChanged: syncStream()
  onShouldPlayChanged: syncStream()
  onManualPausedChanged: syncStream()
  onCredentialsChanged: syncStream()
  onHqStreamChanged: syncStream()

  Timer {
    id: reconnectTimer
    interval: 5000
    repeat: true
    onTriggered: {
      if (!root.autoReconnect || !root.enabled || root.activeRtspUrl === "") return
      if (root.streamState !== "disconnected" && root.streamState !== "error") return
      root.syncStream()
    }
  }

  // PiP window — full-screen transparent layer with positioned card
  PanelWindow {
    id: pipWindow
    visible: root.enabled && root.pipVisible && root.pipScreenInfo() !== null
    screen: root.pipScreenInfo()
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }

    WlrLayershell.namespace: "martin-zayas-tapo-cameras-pip"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: pipCard.containsPointer
      ? WlrKeyboardFocus.OnDemand
      : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region { item: pipCard }

    readonly property color chromeFg: Color.popups.text
    readonly property string fontFamily: Style.font.family
    readonly property var chromeBorderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

    BorderSurface {
      id: pipCard
      x: root.pipX
      y: root.pipY
      width: root.pipWidth
      height: root.pipHeight + pipCard.borderTop + pipCard.borderBottom
      color: Color.popups.background
      borderSpec: pipWindow.chromeBorderSpec
      radius: Style.cornerRadius
      property bool containsPointer: pipHover.hovered || pipDragArea.containsMouse

      HoverHandler {
        id: pipHover
      }

      Item {
        id: videoFrame
        anchors.fill: parent
        anchors.margins: 0
        anchors.topMargin: pipCard.borderTop
        anchors.leftMargin: pipCard.borderLeft
        anchors.rightMargin: pipCard.borderRight
        anchors.bottomMargin: pipCard.borderBottom
        clip: true
        layer.enabled: true
        layer.smooth: true

        VideoOutput {
          id: videoOut
          anchors.fill: parent
          fillMode: VideoOutput.PreserveAspectFit
        }
      }

      MouseArea {
        id: pipDragArea
        anchors.fill: videoFrame
        z: 1
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        propagateComposedEvents: true

        property real _dragStartX: 0
        property real _dragStartY: 0
        property real _pressX: 0
        property real _pressY: 0
        property bool dragging: false

        onEntered: videoControls.reveal()
        onPositionChanged: function(mouse) {
          videoControls.reveal()
          if (!dragging) return
          root.pipX = Math.max(0, _dragStartX + mouse.x - _pressX)
          root.pipY = Math.max(0, _dragStartY + mouse.y - _pressY)
        }

        onPressed: function(mouse) {
          if (videoControls._shown && pipActionBtn.contains(mapToItem(pipActionBtn, mouse.x, mouse.y))) {
            mouse.accepted = false
            return
          }
          if (!root.pipDragModifiersActive(mouse.modifiers)) {
            mouse.accepted = false
            return
          }
          dragging = true
          _dragStartX = root.pipX
          _dragStartY = root.pipY
          _pressX = mouse.x
          _pressY = mouse.y
        }

        onReleased: function(mouse) {
          if (!dragging) return
          dragging = false
          root.clampPipToScreen()
          root.persistState()
        }

        onCanceled: dragging = false
      }

      Item {
        id: videoControls
        anchors.fill: videoFrame
        z: 2
        opacity: _shown ? 1.0 : 0.0
        property bool _shown: false

        Behavior on opacity {
          NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
        }

        Timer {
          id: hideControlsTimer
          interval: 3000
          repeat: false
          onTriggered: videoControls._shown = false
        }

        function reveal() {
          _shown = true
          hideControlsTimer.restart()
        }

        Rectangle {
          id: pipActionBtn
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: Style.spacing.sm
          height: Style.space(36)
          width: Math.min(
            parent.width - Style.spacing.sm * 2,
            pipActionLabel.implicitWidth + Style.space(36) + Style.spacing.controlPaddingX * 2
          )
          radius: Style.cornerRadius
          color: Qt.rgba(0, 0, 0, 0.65)

          Row {
            id: pipActionLabel
            anchors.centerIn: parent
            spacing: Style.spacing.sm

            Text {
              textFormat: Text.PlainText
              text: root.activeCameraName() || "TAPO Camera"
              color: "#ffffff"
              font.family: fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: Math.min(
                implicitWidth,
                pipActionBtn.width - Style.space(36) - Style.spacing.controlPaddingX * 2 - Style.spacing.sm
              )
            }

            Text {
              textFormat: Text.PlainText
              text: root.pipMaximized ? "󰊓" : "󰊔"
              color: "#ffffff"
              font.family: fontFamily
              font.pixelSize: Style.font.body
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            enabled: videoControls._shown
            onEntered: videoControls.reveal()
            onClicked: {
              root.togglePipMaximize()
              videoControls.reveal()
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.streamState === "disconnected" || root.streamState === "error" || root.streamState === "stopped"
        anchors.centerIn: videoFrame
        z: 3
        width: videoFrame.width - Style.space(16)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: root.activeRtspUrl === "" ? "No camera selected"
            : (root.streamState === "error" ? "Stream error"
               : (root.streamState === "disconnected" ? "Disconnected" : "Stopped"))
        color: Qt.rgba(chromeFg.r, chromeFg.g, chromeFg.b, 0.6)
        font.family: fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  MediaPlayer {
    id: pipPlayer
    videoOutput: videoOut
    audioOutput: AudioOutput { muted: true; volume: 0 }
    onPlaybackStateChanged: {
      if (playbackState === MediaPlayer.PlayingState) {
        root.streamState = "playing"
        reconnectTimer.stop()
      } else if (playbackState === MediaPlayer.PausedState) {
        if (root.manualPaused || root.pipMonFullscreen) root.streamState = "paused"
      } else if (playbackState === MediaPlayer.StoppedState && root.shouldPlay && root.activeRtspUrl !== "") {
        root.streamState = "disconnected"
        if (root.autoReconnect) reconnectTimer.start()
      }
    }
    onErrorOccurred: function(err, str) {
      if (err === MediaPlayer.NoError) return
      console.warn("tapo-cameras: MediaPlayer error:", str)
      root.streamState = "error"
      if (root.autoReconnect) reconnectTimer.start()
    }
    onMediaStatusChanged: {
      if (mediaStatus === MediaPlayer.InvalidMedia) {
        root.streamState = "error"
        if (root.autoReconnect) reconnectTimer.start()
      }
      if (mediaStatus === MediaPlayer.BufferedMedia || mediaStatus === MediaPlayer.LoadedMedia) {
        if (root.shouldPlay) root.streamState = "playing"
      }
    }
  }

  // ---------------------------------------------------------------- mutations
  function statusObject() {
    return {
      enabled: root.enabled,
      pipVisible: root.pipVisible,
      activeCameraId: root.activeCameraId,
      activeCameraName: root.activeCameraName(),
      streamState: root.streamState,
      manualPaused: root.manualPaused,
      pauseOnFullscreen: root.pauseOnFullscreen,
      autoReconnect: root.autoReconnect,
      hqStream: root.hqStream,
      pipMaximized: root.pipMaximized,
      pipX: root.pipX,
      pipY: root.pipY,
      pipWidth: root.pipWidth,
      pipHeight: root.pipHeight,
      pipScreen: root.pipScreen,
      cameras: root.cameras,
      rendering: root.rendering
    }
  }

  function applyPlay(cameraId) {
    var id = safeId(cameraId)
    if (id !== "") root.activeCameraId = id
    root.enabled = true
    root.manualPaused = false
    root.pipVisible = true
    if (root.pipScreen === "" && Quickshell.screens.length > 0) {
      root.pipScreen = String(Quickshell.screens[0].name)
    }
    root.normalizePipPosition()
    root.persistState()
    root.syncStream()
    return root.statusObject()
  }

  function applyStop() {
    root.enabled = false
    root.manualPaused = false
    root.streamState = "stopped"
    reconnectTimer.stop()
    root.persistState()
    root.syncStream()
  }

  function applyToggle() {
    if (!root.enabled) return root.applyPlay(root.activeCameraId)
    root.manualPaused = !root.manualPaused
    root.persistState()
    root.syncStream()
    return root.manualPaused
  }

  function applyPause() {
    root.manualPaused = true
    root.persistState()
    root.syncStream()
  }

  function applyResume() {
    root.manualPaused = false
    root.enabled = true
    root.persistState()
    root.syncStream()
  }

  function applySelect(cameraId) {
    root.activeCameraId = safeId(cameraId)
    root.persistState()
    root.syncStream()
    return root.statusObject()
  }

  function applySetPauseOnFullscreen(on) {
    root.pauseOnFullscreen = (on === true || String(on) === "true")
    root.persistState()
    root.syncStream()
    return root.statusObject()
  }

  function applySetAutoReconnect(on) {
    root.autoReconnect = (on === true || String(on) === "true")
    root.persistState()
    return root.statusObject()
  }

  function applySetHqStream(on) {
    root.hqStream = (on === true || String(on) === "true")
    root.persistState()
    root.syncStream()
    return root.statusObject()
  }

  function applySetPipVisible(on) {
    root.pipVisible = (on === true || String(on) === "true")
    root.persistState()
    root.syncStream()
    return root.statusObject()
  }

  function applySetPipPosition(x, y) {
    root.pipX = Math.max(0, parseInt(x, 10) || 0)
    root.pipY = Math.max(0, parseInt(y, 10) || 0)
    clampPipToScreen()
    root.persistState()
  }

  function applyUpsertCamera(cameraJson, password) {
    var c = {}
    try { c = JSON.parse(cameraJson || "{}") } catch (e) { return root.statusObject() }
    var id = safeId(c.id) || safeId(c.name) || ("cam-" + Date.now())
    var entry = {
      id: id,
      name: safeName(c.name, id),
      host: safeHost(c.host),
      port: safePort(c.port),
      path: safeStreamPath(c.path),
      username: safeName(c.username, "")
    }
    if (entry.host === "") return root.statusObject()

    var list = []
    var found = false
    for (var i = 0; i < root.cameras.length; i++) {
      var existing = root.cameras[i]
      if (String(existing.id) === id) {
        list.push(entry)
        found = true
      } else {
        list.push(existing)
      }
    }
    if (!found) {
      if (list.length >= root.maxCameras) return root.statusObject()
      list.push(entry)
    }
    root.cameras = list
    if (password !== undefined && password !== null && String(password) !== "") {
      var creds = ({})
      for (var ck in root.credentials) creds[ck] = root.credentials[ck]
      creds[id] = String(password)
      root.credentials = creds
      root.persistCredentials()
    }
    if (!root.activeCameraId) root.activeCameraId = id
    root.persistState()
    return root.statusObject()
  }

  function applyRemoveCamera(cameraId) {
    var id = safeId(cameraId)
    if (id === "") return root.statusObject()
    var list = []
    for (var i = 0; i < root.cameras.length; i++) {
      if (String(root.cameras[i].id) !== id) list.push(root.cameras[i])
    }
    root.cameras = list
    var creds = ({})
    for (var ck in root.credentials) creds[ck] = root.credentials[ck]
    delete creds[id]
    root.credentials = creds
    if (root.activeCameraId === id) {
      root.activeCameraId = list.length > 0 ? String(list[0].id) : ""
    }
    root.persistState()
    root.persistCredentials()
    root.syncStream()
    return root.statusObject()
  }

  IpcHandler {
    target: "martin-zayas-tapo-cameras"

    function play(cameraId: string): string {
      return JSON.stringify(root.applyPlay(cameraId))
    }

    function stop(): string { root.applyStop(); return "stopped" }

    function toggle(): string {
      return root.applyToggle() ? "paused" : "playing"
    }

    function pause(): string { root.applyPause(); return "paused" }
    function resume(): string { root.applyResume(); return "playing" }

    function select(cameraId: string): string {
      return JSON.stringify(root.applySelect(cameraId))
    }

    function status(): string { return JSON.stringify(root.statusObject()) }

    function setPauseOnFullscreen(on: string): string {
      return JSON.stringify(root.applySetPauseOnFullscreen(on))
    }

    function setAutoReconnect(on: string): string {
      return JSON.stringify(root.applySetAutoReconnect(on))
    }

    function setHqStream(on: string): string {
      return JSON.stringify(root.applySetHqStream(on))
    }

    function addCamera(cameraJson: string, password: string): string {
      return JSON.stringify(root.applyUpsertCamera(cameraJson, password))
    }

    function removeCamera(cameraId: string): string {
      return JSON.stringify(root.applyRemoveCamera(cameraId))
    }

    function setPipSize(preset: string): string {
      root.setPipSizePreset(preset)
      return JSON.stringify(root.statusObject())
    }
  }
}
