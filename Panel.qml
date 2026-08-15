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
  readonly property string panelStyle: String(root.settings && root.settings.panelStyle
    ? root.settings.panelStyle : "full").toLowerCase() === "compact" ? "compact" : "full"
  readonly property var activityRows: Model.activityRows(oneDrive)

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
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(520))

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
          spacing: Style.space(10)

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

          CursorSurface {
            id: storageBlock
            visible: oneDrive.authenticated
            width: parent.width
            foreground: root.foreground
            hasCursor: storageMouse.containsMouse && storageMouse.enabled
            implicitHeight: storageContent.implicitHeight + Style.space(8)
            height: implicitHeight

            Column {
              id: storageContent
              width: parent.width - Style.space(8)
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: Math.max(storageHeader.implicitHeight, storageValue.implicitHeight)

                PanelSectionHeader {
                  id: storageHeader
                  text: "STORAGE"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: storageValue
                  text: Model.usageShort(oneDrive.usedBytes, oneDrive.quotaBytes, oneDrive.quotaKnown)
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Rectangle {
                id: storageTrack
                width: parent.width
                height: Style.space(6)
                radius: Style.cornerRadius
                color: Style.selectedFillFor(root.foreground, Color.accent)
                opacity: oneDrive.quotaKnown ? 1.0 : 0.5

                Rectangle {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  visible: oneDrive.quotaKnown
                  width: storageTrack.width * Model.usageFraction(
                    oneDrive.usedBytes, oneDrive.quotaBytes, oneDrive.quotaKnown)
                  height: storageTrack.height
                  radius: Style.cornerRadius
                  color: root.foreground
                }
              }

              Item {
                width: parent.width
                implicitHeight: Math.max(storageFree.implicitHeight, storageChecked.implicitHeight)

                Text {
                  id: storageFree
                  text: oneDrive.quotaKnown
                    ? Model.freeText(oneDrive.usedBytes, oneDrive.quotaBytes, oneDrive.quotaKnown)
                    : "Check cloud for exact usage"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: storageChecked
                  text: Model.checkedText(oneDrive.remoteCheckedTs)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            MouseArea {
              id: storageMouse
              anchors.fill: parent
              hoverEnabled: true
              enabled: !oneDrive.quotaKnown
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: oneDrive.refresh(true)
            }
          }

          Column {
            id: activityBlock
            visible: oneDrive.authenticated && root.panelStyle === "full"
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(activityHeader.implicitHeight, activityMeta.implicitHeight)

              PanelSectionHeader {
                id: activityHeader
                text: "ACTIVITY"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: activityMeta
                text: Model.activityMeta(root.activityRows)
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              visible: root.activityRows.length === 0
              width: parent.width
              text: "No recent OneDrive activity."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: activityColumn
              visible: root.activityRows.length > 0
              width: parent.width
              spacing: Style.space(3)

              Repeater {
                model: root.activityRows

                ActivityRow {
                  required property var modelData
                  width: activityColumn.width
                  rowData: modelData
                }
              }
            }
          }

          Row {
            id: chipRow
            visible: root.panelStyle === "full" && oneDrive.installed && oneDrive.authenticated
            width: parent.width
            spacing: Style.space(6)

            ActionChip {
              width: folderChip.visible ? (chipRow.width - chipRow.spacing) / 2 : chipRow.width
              text: "Check cloud"
              icon: "󰑓"
              enabled: !oneDrive.busy
              onActivated: oneDrive.refresh(true)
            }

            ActionChip {
              id: folderChip
              visible: oneDrive.syncDir !== ""
              width: (chipRow.width - chipRow.spacing) / 2
              text: "Folder"
              icon: "󰉋"
              onActivated: oneDrive.openFolder()
            }
          }

          Column {
            visible: oneDrive.authenticated && root.panelStyle === "compact"
            width: parent.width
            spacing: Style.space(5)

            CompactActionRow {
              width: parent.width
              title: "Check cloud"
              icon: "󰑓"
              meta: Model.relativeTime(oneDrive.remoteCheckedTs)
              selected: true
              actionEnabled: !oneDrive.busy
              onActivated: oneDrive.refresh(true)
            }

            CompactActionRow {
              width: parent.width
              title: "Open OneDrive folder"
              icon: "󰉋"
              actionEnabled: oneDrive.syncDir !== ""
              onActivated: oneDrive.openFolder()
            }
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

  component ActivityRow: CursorSurface {
    id: activityRow
    property var rowData: null
    readonly property string kind: String(rowData && rowData.kind || "")
    readonly property bool fileRow: kind === "file"
    readonly property string title: String(rowData && rowData.title || "")
    readonly property string detail: String(rowData && rowData.detail || "")

    foreground: root.foreground
    hasCursor: activityMouse.containsMouse && fileRow
    implicitHeight: Math.max(Style.space(32), activityContent.implicitHeight + Style.space(6))
    height: implicitHeight

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.topMargin: Style.space(5)
      anchors.bottomMargin: Style.space(5)
      width: Style.space(2)
      radius: width / 2
      color: activityRow.fileRow ? root.dim : Color.accent
    }

    MouseArea {
      id: activityMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: activityRow.fileRow
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: oneDrive.openFile({
        path: activityRow.rowData && activityRow.rowData.path || "",
        name: activityRow.title
      })
    }

    RowLayout {
      id: activityContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(7)

      Text {
        text: Model.activityGlyph(activityRow.rowData)
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
          text: activityRow.title
          color: activityRow.kind === "error" ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          visible: activityRow.detail !== ""
          Layout.fillWidth: true
          text: activityRow.detail
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      Text {
        text: Model.relativeTime(activityRow.rowData && activityRow.rowData.ts || 0)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        Layout.alignment: Qt.AlignTop | Qt.AlignRight
      }
    }
  }

  component ActionChip: CursorSurface {
    id: actionChip
    property string text: ""
    property string icon: ""
    signal activated()

    foreground: root.foreground
    bordered: true
    hasCursor: chipMouse.containsMouse && actionChip.enabled
    implicitHeight: Style.space(34)
    height: implicitHeight
    opacity: enabled ? 1.0 : 0.5

    Text {
      anchors.centerIn: parent
      text: actionChip.icon + "  " + actionChip.text
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: actionChip.enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: actionChip.activated()
    }
  }

  component CompactActionRow: CursorSurface {
    id: compactRow
    property string title: ""
    property string icon: ""
    property string meta: ""
    property bool selected: false
    property bool actionEnabled: true
    signal activated()

    foreground: root.foreground
    current: selected
    currentFill: Style.selectedFillFor(root.foreground, Color.accent)
    hasCursor: compactMouse.containsMouse && actionEnabled
    implicitHeight: Style.space(34)
    height: implicitHeight
    opacity: actionEnabled ? 1.0 : 0.5

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: compactRow.icon
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        Layout.fillWidth: true
        text: compactRow.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        visible: compactRow.meta !== ""
        text: compactRow.meta
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
      }
    }

    MouseArea {
      id: compactMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: compactRow.actionEnabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: compactRow.activated()
    }
  }
}
