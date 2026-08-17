import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.salemsayed.omaonedrive"

  readonly property var service: panelLoader.item ? panelLoader.item.service : null
  readonly property bool active: service ? service.active : false
  readonly property bool syncing: service ? service.syncing : false
  readonly property bool starting: service ? service.activeState === "activating" : false
  readonly property bool installed: service ? service.installed : false
  readonly property bool authenticated: service ? service.authenticated : false
  readonly property bool attention: service
    ? service.serviceFailed || service.resyncRequired || service.reauthRequired
    : false
  readonly property color iconColor: active
    ? (bar ? bar.barForeground : Color.foreground)
    : Qt.darker(bar ? bar.barForeground : Color.foreground, 1.55)
  readonly property string badgeKind: !installed ? "missing"
    : (!authenticated ? "login"
      : (attention ? "attention"
        : (syncing || starting ? "syncing"
          : (!active ? "paused" : ""))))
  readonly property string badgeGlyph: badgeKind === "missing" ? "󰅖"
    : (badgeKind === "login" ? "󰌋"
      : (badgeKind === "paused" ? "󰏤"
        : (badgeKind === "syncing" ? "󰑓"
          : (badgeKind === "attention" ? "󰀪" : ""))))
  readonly property color badgeColor: badgeKind === "login" || badgeKind === "attention"
    ? (bar ? bar.urgent : Color.urgent)
    : (badgeKind === "syncing" ? Color.accent : iconColor)
  readonly property color badgeBackground: bar ? bar.background : Color.background
  readonly property string tooltipText: service
    ? Model.tooltip(service, Date.now())
    : "Checking OneDrive…"
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: Style.space(15)

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
      panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): string {
      if (root.service) root.service.refresh(false)
      return "ok"
    }
    function check(): string {
      if (root.service) root.service.checkQuota()
      return "ok"
    }
    function fullStatus(): string {
      if (root.service) root.service.checkFullStatus()
      return "ok"
    }
    function pause(): string {
      if (root.service) root.service.pause()
      return "ok"
    }
    function pauseFor(minutes: int): string {
      if (root.service) root.service.pauseFor(minutes)
      return "ok"
    }
    function resume(): string {
      if (root.service) root.service.resume()
      return "ok"
    }
    function toggleSync(): string {
      if (root.service) root.service.toggleRunning()
      return "ok"
    }
    function folder(): string {
      if (root.service) root.service.openFolder()
      return "ok"
    }
    function web(): string {
      if (root.service) root.service.openWeb()
      return "ok"
    }
    function resync(): string {
      if (root.service) root.service.repairResync()
      return "ok"
    }
    function status(): string { return root.service ? root.service.statusText : "Checking…" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.tooltipText
    dimmed: !root.installed
    iconComponent: Component {
      Item {
        OneDriveIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.iconColor
        }

        Rectangle {
          width: Style.space(4)
          height: width
          radius: width / 2
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          color: root.syncing ? Color.accent : root.iconColor
          visible: root.active && root.badgeKind === ""

          SequentialAnimation on opacity {
            running: root.syncing
            loops: Animation.Infinite
            NumberAnimation { to: 0.25; duration: 500 }
            NumberAnimation { to: 1.0; duration: 500 }
          }
        }

        StatusBadge {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          visible: root.badgeKind !== ""
          badgeSize: Style.space(8)
          glyph: root.badgeGlyph
          glyphColor: root.badgeColor
          ringColor: root.badgeColor
          background: root.badgeBackground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          pulsing: root.badgeKind === "syncing"
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && root.service) root.service.checkQuota()
      else if (buttonCode === Qt.MiddleButton && root.service) root.service.openFolder()
      else root.togglePanel()
    }
  }
}
