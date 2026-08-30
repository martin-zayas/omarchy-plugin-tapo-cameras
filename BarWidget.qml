import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "martin-zayas-tapo-cameras"

  readonly property string pluginId: "martin-zayas-tapo-cameras"
  readonly property var service: (bar && bar.shell) ? bar.shell.serviceFor(pluginId) : null

  property bool opened: false
  property bool popoutSwitchClosing: false

  function open() { opened = true }
  function close() { opened = false }
  function toggle() { opened = !opened }

  readonly property bool hasStream: !!service && service.enabled && service.rendering === true
  readonly property bool isPaused: hasStream && service.manualPaused === true
  readonly property bool isError: !!service && (service.streamState === "error" || service.streamState === "disconnected")
  readonly property color warningColor: "#e5c07b"
  readonly property color errorColor: "#e06c75"
  readonly property color iconColor: !service ? Color.muted
                                   : isError ? errorColor
                                   : hasStream ? (isPaused ? warningColor : Color.accent)
                                   : Color.muted

  readonly property string glyph: "󰄀"  // nf-md-cctv

  readonly property string screenName: {
    var w = button.QsWindow ? button.QsWindow.window : null
    return w && w.screen ? String(w.screen.name || "") : ""
  }

  function playCamera(id) {
    if (service) service.applyPlay(id)
    else ipc("play", id)
  }

  function selectCamera(id) {
    if (service) service.applySelect(id)
    else ipc("select", id)
  }

  function togglePlayPause() {
    if (!service) { ipc("toggle"); return }
    if (!service.enabled) { service.applyPlay(service.activeCameraId || ""); return }
    if (service.manualPaused) service.applyResume()
    else service.applyPause()
  }

  function stopPlayback() {
    if (service) service.applyStop()
    else ipc("stop")
  }

  function setPauseOnFullscreen(on) {
    if (service) service.applySetPauseOnFullscreen(on)
    else ipc("setPauseOnFullscreen", on ? "true" : "false")
  }

  function setAutoReconnect(on) {
    if (service) service.applySetAutoReconnect(on)
    else ipc("setAutoReconnect", on ? "true" : "false")
  }

  function setHqStream(on) {
    if (service) service.applySetHqStream(on)
    else ipc("setHqStream", on ? "true" : "false")
  }

  function setPipSize(preset) {
    if (service) service.setPipSizePreset(preset)
    else ipc("setPipSize", preset)
  }

  function upsertCamera(cameraJson, password) {
    if (service) service.applyUpsertCamera(cameraJson, password)
    else ipc("addCamera", cameraJson, password)
  }

  function removeCamera(id) {
    if (service) service.applyRemoveCamera(id)
    else ipc("removeCamera", id)
  }

  function ipc(fn) {
    var cfgPath = (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell"
    var cmd = ["qs", "-p", cfgPath, "ipc", "call", "martin-zayas-tapo-cameras", fn]
    for (var i = 1; i < arguments.length; i++) {
      var a = arguments[i]
      cmd.push(a === undefined || a === null ? "" : String(a))
    }
    Quickshell.execDetached(cmd)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: "TAPO Cameras"
    useActiveColor: false
    foreground: root.iconColor
    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePlayPause()
      else root.toggle()
    }
  }

  function syncBarGeometryToService() {
    if (!root.service || !root.bar) return
    root.service.setBarGeometry(root.bar.position, root.bar.barSize)
  }

  Component.onCompleted: syncBarGeometryToService()

  Connections {
    target: root.bar
    function onBarSizeChanged() { root.syncBarGeometryToService() }
    function onPositionChanged() { root.syncBarGeometryToService() }
  }

  Connections {
    target: root.service
    function onPipScreenChanged() { root.syncBarGeometryToService() }
  }

  KeyboardPanel {
    id: kpanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: kpanel.fittedContentWidth(Style.space(320))
    contentHeight: kpanel.fittedContentHeight(contentLoader.item ? contentLoader.item.implicitHeight : Style.space(280))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: contentLoader.item ? contentLoader.item.keysBlocked : false
      onCloseRequested: root.close()

      Loader {
        id: contentLoader
        anchors.fill: parent
        source: "Panel.qml"
        onLoaded: {
          if (!item) return
          item.widget = root
          item.bar = root.bar
        }
      }
    }
  }
}
