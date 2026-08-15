import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.salemsayed.omaonedrive"
  ipcTarget: "io.github.salemsayed.omaonedrive.panel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property alias service: oneDrive

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Util.alpha(foreground, 0.62)
  readonly property color faint: Util.alpha(foreground, 0.42)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color iconColor: oneDrive.authenticated && oneDrive.active ? foreground : dim
  readonly property string toggleHint: oneDrive.active ? "Pause syncing" : "Resume syncing"

  function open() {
    root.controller.show()
    oneDrive.refresh(false)
    Qt.callLater(function() {
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) close()
    else open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function closeForPopoutSwitch() {
    root.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: oneDrive
    settings: root.settings
  }

  BarIconButton {
    id: button
    visible: false
    bar: root.bar
    text: ""
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: oneDrive.openFolder()
      onTextKey: function(value) {
        if (value === "r" || value === "R") oneDrive.refresh(true)
        else if (value === "p" || value === "P") oneDrive.toggleRunning()
        else if (value === "o" || value === "O") oneDrive.openFolder()
        else if (value === "l" || value === "L") oneDrive.login()
      }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: panelScroll.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "OneDrive"
            meta: oneDrive.statusText
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: oneDrive.active ? 1.0 : 0.55
            iconComponent: Component {
              OneDriveIcon {
                iconSize: Style.font.display
                color: root.iconColor
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                visible: oneDrive.installed && oneDrive.serviceAvailable && oneDrive.authenticated
                checked: oneDrive.active
                busy: oneDrive.busy
                foreground: root.foreground
                onToggled: oneDrive.toggleRunning()

                PanelToolTip {
                  visible: parent.containsMouse
                  text: root.toggleHint
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          Text {
            visible: oneDrive.actionStatus !== "" || oneDrive.lastError !== ""
            width: parent.width
            text: oneDrive.actionStatus !== "" ? oneDrive.actionStatus : oneDrive.lastError
            color: oneDrive.lastError !== "" && oneDrive.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          ActionRow {
            visible: !oneDrive.installed
            width: parent.width
            title: "OneDrive CLI is not installed"
            subtitle: "Install the abraunegg OneDrive client first"
            icon: "󰅟"
            actionIcon: ""
            actionEnabled: false
          }

          ActionRow {
            visible: oneDrive.installed && !oneDrive.authenticated
            width: parent.width
            title: "Login to OneDrive"
            subtitle: "Open the CLI authentication flow"
            icon: "󰌋"
            actionIcon: "󰐕"
            onActivated: oneDrive.login()
          }

          Column {
            visible: oneDrive.authenticated
            width: parent.width
            spacing: Style.space(8)

            InfoPair {
              label: "Cloud storage"
              value: Model.usageText(oneDrive.usedBytes, oneDrive.quotaBytes, oneDrive.quotaKnown)
            }
            InfoPair {
              label: "Cloud status"
              value: oneDrive.remoteStatus
            }
            InfoPair {
              label: "Last sync"
              value: Model.relativeTime(oneDrive.lastSyncTs)
            }
            InfoPair {
              label: "Starts on login"
              value: oneDrive.enabled ? "Yes" : "No"
            }
          }

          ActionRow {
            visible: oneDrive.authenticated
            width: parent.width
            title: "Check OneDrive cloud"
            subtitle: oneDrive.remoteCheckedTs > 0
              ? "Last checked " + Model.relativeTime(oneDrive.remoteCheckedTs)
              : "Load quota and verify pending changes"
            icon: "󰑓"
            actionIcon: "󰑓"
            actionEnabled: !oneDrive.busy
            onActivated: oneDrive.refresh(true)
          }

          ActionRow {
            visible: oneDrive.syncDir !== ""
            width: parent.width
            title: Model.folderName(oneDrive.syncDir)
            subtitle: oneDrive.syncDir
            icon: "󰉋"
            actionIcon: "󰏌"
            onActivated: oneDrive.openFolder()
          }

          PanelSeparator {
            visible: oneDrive.authenticated
            foreground: root.foreground
          }

          Column {
            visible: oneDrive.authenticated
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "RECENT LOCAL FILES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: oneDrive.files.length === 0
              width: parent.width
              text: "No local OneDrive files found."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: fileColumn
              visible: oneDrive.files.length > 0
              width: parent.width
              spacing: Style.space(5)

              Repeater {
                model: oneDrive.files
                FileRow {
                  required property var modelData
                  width: fileColumn.width
                  file: modelData
                }
              }
            }
          }

          Text {
            visible: oneDrive.installed
            width: parent.width
            text: "R check cloud  ·  P pause/resume  ·  O open folder"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow

    property string title: ""
    property string subtitle: ""
    property string icon: ""
    property string actionIcon: "󰐕"
    property bool actionEnabled: true
    signal activated()

    foreground: root.foreground
    implicitHeight: Math.max(Style.space(54), row.implicitHeight + Style.spacing.rowPaddingX)
    height: implicitHeight

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: actionRow.actionEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: actionRow.actionEnabled
      onClicked: actionRow.activated()
    }

    RowLayout {
      id: row
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(9)

      Text {
        text: actionRow.icon
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: actionRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: actionRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      PanelActionButton {
        visible: actionRow.actionIcon !== ""
        iconText: actionRow.actionIcon
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: actionRow.actionEnabled
        Layout.alignment: Qt.AlignVCenter
        onClicked: actionRow.activated()
      }
    }
  }

  component FileRow: CursorSurface {
    id: fileRow
    property var file: null
    readonly property string fileName: file ? String(file.name || "Untitled") : "Untitled"

    foreground: root.foreground
    implicitHeight: Math.max(Style.space(46), fileContent.implicitHeight + Style.spacing.rowPaddingX)
    height: implicitHeight

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: oneDrive.openFile(fileRow.file)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: Model.fileGlyph(fileRow.fileName)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: fileContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: fileRow.fileName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: Model.fileMeta(fileRow.file)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      width: parent.width * 0.42
      text: label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      width: parent.width * 0.58 - parent.spacing
      text: value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
    }
  }
}
