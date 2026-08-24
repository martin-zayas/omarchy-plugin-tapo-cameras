import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

Item {
  id: panel

  property var widget: null
  property QtObject bar: null

  readonly property var service: widget ? widget.service : null
  readonly property bool keysBlocked: formName.activeFocus || formHost.activeFocus
      || formPort.activeFocus || formPath.activeFocus
      || formUser.activeFocus || formPass.activeFocus

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.5)

  property string editId: ""
  property bool editing: false

  function plainName(s) { return String(s).replace(/[<>]/g, "") }

  readonly property string stateText: {
    if (!service) return "Service unavailable"
    if (service.cameras.length === 0) return "No cameras configured"
    if (!service.activeCameraId) return "No camera selected"
    if (!service.enabled) return "Stopped"
    if (service.streamState === "error") return "Stream error"
    if (service.streamState === "disconnected") return "Disconnected"
    if (service.manualPaused) return "Paused"
    if (service.streamState === "playing") return "Playing"
    return "Ready"
  }

  readonly property string metaText: {
    var name = service ? plainName(service.activeCameraName() || "") : ""
    return stateText + (name !== "" ? "  ·  " + name : "")
  }

  readonly property bool isPlaying: !!service && service.enabled
      && service.streamState === "playing" && !service.manualPaused
  readonly property bool isPaused: !!service && service.enabled && service.manualPaused

  readonly property var cameraList: service ? service.cameras : []

  function resetForm() {
    panel.editId = ""
    panel.editing = false
    formName.text = ""
    formHost.text = ""
    formPort.text = "554"
    formPath.text = "/stream2"
    formUser.text = ""
    formPass.text = ""
  }

  function loadCamera(cam) {
    if (!cam) { resetForm(); return }
    panel.editId = String(cam.id)
    panel.editing = true
    formName.text = String(cam.name || "")
    formHost.text = String(cam.host || "")
    formPort.text = String(cam.port || 554)
    formPath.text = String(cam.path || "/stream2")
    formUser.text = String(cam.username || "")
    formPass.text = ""
  }

  function saveForm() {
    if (!widget) return
    var payload = JSON.stringify({
      id: panel.editId || formName.text.trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "-"),
      name: formName.text.trim(),
      host: formHost.text.trim(),
      port: parseInt(formPort.text, 10) || 554,
      path: formPath.text.trim() || "/stream2",
      username: formUser.text.trim()
    })
    widget.upsertCamera(payload, formPass.text)
    resetForm()
  }

  Component.onCompleted: resetForm()

  Connections {
    target: panel.widget || null
    function onOpenedChanged() {
      if (!panel.widget || !panel.widget.opened) return
      panel.resetForm()
    }
  }

  implicitWidth: Style.space(320)
  implicitHeight: col.implicitHeight

  Column {
    id: col
    width: parent.width
    spacing: Style.spacing.panelGap

    PanelHero {
      width: parent.width
      title: "TAPO Cameras"
      meta: panel.metaText
      foreground: panel.fg
      fontFamily: panel.fontFamily
      iconComponent: Component {
        Text {
          textFormat: Text.PlainText
          text: "󰄀"
          color: panel.widget ? panel.widget.iconColor : panel.fg
          font.family: panel.fontFamily
          font.pixelSize: Style.font.display
        }
      }
    }

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      Button {
        foreground: panel.fg
        fontFamily: panel.fontFamily
        iconText: panel.isPlaying ? "󰏤" : "󰐊"
        text: panel.isPlaying ? "Pause" : (panel.isPaused ? "Resume" : "Play")
        bordered: true
        onClicked: if (panel.widget) panel.widget.togglePlayPause()
      }

      Button {
        foreground: panel.fg
        fontFamily: panel.fontFamily
        iconText: "󰓛"
        text: "Stop"
        bordered: true
        opacity: (panel.service && panel.service.enabled) ? 1.0 : 0.5
        onClicked: if (panel.widget) panel.widget.stopPlayback()
      }
    }

    Toggle {
      width: parent.width
      label: "Pause on fullscreen"
      description: "Pause while a window is fullscreen on the PiP monitor"
      foreground: panel.fg
      checked: panel.service ? panel.service.pauseOnFullscreen === true : false
      onClicked: if (panel.widget) panel.widget.setPauseOnFullscreen(!checked)
    }

    Toggle {
      width: parent.width
      label: "Auto-reconnect"
      description: "Retry the stream every 5s after a disconnect"
      foreground: panel.fg
      checked: panel.service ? panel.service.autoReconnect !== false : true
      onClicked: if (panel.widget) panel.widget.setAutoReconnect(!checked)
    }

    PanelSectionHeader {
      text: "PIP SIZE"
      foreground: panel.fg
      fontFamily: panel.fontFamily
    }

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      Button {
        foreground: panel.fg
        fontFamily: panel.fontFamily
        text: "S"
        bordered: true
        onClicked: if (panel.widget) panel.widget.setPipSize("S")
      }
      Button {
        foreground: panel.fg
        fontFamily: panel.fontFamily
        text: "M"
        bordered: true
        onClicked: if (panel.widget) panel.widget.setPipSize("M")
      }
      Button {
        foreground: panel.fg
        fontFamily: panel.fontFamily
        text: "L"
        bordered: true
        onClicked: if (panel.widget) panel.widget.setPipSize("L")
      }
    }

    PanelSeparator { foreground: panel.fg }

    PanelSectionHeader {
      text: "CAMERAS"
      foreground: panel.fg
      fontFamily: panel.fontFamily
    }

    Text {
      textFormat: Text.PlainText
      visible: panel.cameraList.length === 0
      width: parent.width
      text: "Add a camera below (RTSP / TAPO Camera Account)"
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    ListView {
      id: cameraListView
      visible: panel.cameraList.length > 0
      width: parent.width
      height: Math.min(contentHeight, Style.space(160))
      clip: true
      spacing: Style.spacing.xxs
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      model: panel.cameraList

      delegate: Rectangle {
        id: crow
        required property var modelData
        required property int index
        readonly property bool current: panel.service
            && String(panel.service.activeCameraId) === String(modelData.id)
        width: cameraListView.width
        height: Style.spacing.controlHeight
        radius: Style.cornerRadius
        color: current
          ? Style.selectedFillFor(panel.fg, Color.accent)
          : (rowMouse.containsMouse ? Style.hoverFillFor(panel.fg, Color.accent) : "transparent")

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: editBtn.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.controlPaddingX
          anchors.rightMargin: Style.spacing.sm
          text: panel.plainName(modelData.name) + "  ·  " + modelData.host
          color: crow.current ? Style.selectedStateColor(panel.fg, Color.accent) : panel.fg
          font.family: panel.fontFamily
          font.pixelSize: Style.font.body
          font.bold: crow.current
          elide: Text.ElideMiddle
        }

        Text {
          id: editBtn
          textFormat: Text.PlainText
          anchors.right: playMark.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.rightMargin: Style.spacing.sm
          text: "󰏫"
          color: panel.dim
          font.family: panel.fontFamily
          font.pixelSize: Style.font.bodySmall
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: panel.loadCamera(crow.modelData)
          }
        }

        Text {
          id: playMark
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.rightMargin: Style.spacing.controlPaddingX
          visible: crow.current
          text: panel.isPaused ? "󰏤" : "󰐊"
          color: Style.selectedStateColor(panel.fg, Color.accent)
          font.family: panel.fontFamily
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          z: -1
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (!panel.widget) return
            panel.widget.playCamera(String(crow.modelData.id))
          }
        }
      }
    }

    PanelSeparator { foreground: panel.fg }

    PanelSectionHeader {
      text: panel.editing ? "EDIT CAMERA" : "ADD CAMERA"
      foreground: panel.fg
      fontFamily: panel.fontFamily
    }

  Column {
    width: parent.width
    spacing: Style.spacing.controlGap

    Text {
      textFormat: Text.PlainText
      text: "Name"
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    TextField {
      id: formName
      width: parent.width
      foreground: panel.fg
      placeholderText: "Entrada"
    }

    Text {
      textFormat: Text.PlainText
      text: "Host / IP"
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    TextField {
      id: formHost
      width: parent.width
      foreground: panel.fg
      placeholderText: "192.168.1.50"
    }

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      Column {
        width: (parent.width - Style.spacing.controlGap) / 2
        spacing: Style.spacing.xxs
        Text {
          textFormat: Text.PlainText
          text: "Port"
          color: panel.dim
          font.family: panel.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        TextField {
          id: formPort
          width: parent.width
          foreground: panel.fg
          text: "554"
        }
      }

      Column {
        width: (parent.width - Style.spacing.controlGap) / 2
        spacing: Style.spacing.xxs
        Text {
          textFormat: Text.PlainText
          text: "Path"
          color: panel.dim
          font.family: panel.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        TextField {
          id: formPath
          width: parent.width
          foreground: panel.fg
          text: "/stream2"
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      text: "Username (Camera Account)"
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    TextField {
      id: formUser
      width: parent.width
      foreground: panel.fg
      placeholderText: "tapo_user"
    }

    Text {
      textFormat: Text.PlainText
      text: "Password"
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    TextField {
      id: formPass
      width: parent.width
      foreground: panel.fg
      password: true
      placeholderText: panel.editing ? "(unchanged if empty)" : "Camera Account password"
    }

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      Button {
        foreground: panel.fg
        fontFamily: panel.fontFamily
        text: panel.editing ? "Save" : "Add"
        bordered: true
        onClicked: panel.saveForm()
      }

      Button {
        visible: panel.editing
        foreground: panel.fg
        fontFamily: panel.fontFamily
        text: "Delete"
        bordered: true
        onClicked: {
          if (panel.widget && panel.editId !== "") panel.widget.removeCamera(panel.editId)
          panel.resetForm()
        }
      }

      Button {
        visible: panel.editing
        foreground: panel.fg
        fontFamily: panel.fontFamily
        text: "Cancel"
        bordered: true
        onClicked: panel.resetForm()
      }
    }
  }
  }
}
