import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.salemsayed.omaonedrive"
  // Moving a bar widget briefly overlaps its old and replacement instances.
  // Wait for the retired slot to release this process-wide IPC target.
  property bool ipcRegistrationReady: false

  readonly property var service: panelLoader.item ? panelLoader.item.service : null

  // Worst of N. With one account this resolves to exactly the state the old
  // flat ternary produced; the mapping and the precedence are table-tested in
  // tests/Aggregate.test.js rather than spelled out here.
  readonly property var aggregate: service
    ? service.aggregate
    : ({ kind: "checking", count: 0, anyActive: false, initialized: false })
  readonly property int accountCount: service ? service.accountCount : 0

  // The icon stays lit while ANY account is working, so one paused account does
  // not dim a bar that is still syncing two others.
  readonly property bool active: aggregate.anyActive === true
  readonly property bool syncing: aggregate.kind === "syncing" || aggregate.kind === "starting"
  // Dimming asks "is anything actually usable", which is not the question the
  // badge answers. Deriving it from the badge kind left the icon undimmed before
  // the first poll, and undimmed while showing the missing-client badge for an
  // account whose unit is merely unavailable.
  // Dimming asks whether ANYTHING is usable, so it follows anyActive rather than
  // the worst account's kind: one missing account must not dim a bar that has a
  // healthy one syncing.
  readonly property bool installed: aggregate.initialized === true
    && (aggregate.anyActive === true
        || (aggregate.kind !== "missing" && aggregate.kind !== "unavailable"))
  readonly property color iconColor: active
    ? (bar ? bar.barForeground : Color.foreground)
    : Qt.darker(bar ? bar.barForeground : Color.foreground, 1.55)
  readonly property string badgeKind: Model.badgeKind(aggregate.kind)
  readonly property string badgeGlyph: Model.badgeGlyph(badgeKind)
  readonly property color badgeColor: badgeKind === "login" || badgeKind === "attention"
    ? (bar ? bar.urgent : Color.urgent)
    : (badgeKind === "syncing" ? Color.accent : iconColor)
  readonly property color badgeBackground: bar ? bar.background : Color.background
  readonly property string tooltipText: service
    ? Model.aggregateTooltip(service.accounts, Date.now())
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
  Component.onCompleted: ipcRegistrationTimer.start()

  Timer {
    id: ipcRegistrationTimer
    interval: 100
    onTriggered: root.ipcRegistrationReady = true
  }

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
    enabled: root.ipcRegistrationReady
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
    // Enumerate and select, so automation can reach a non-default account before
    // invoking any of the controls above -- which all act on the selected one.
    function accounts(): string {
      if (!root.service) return "[]"
      var rows = []
      for (var index = 0; index < root.service.accounts.length; index++) {
        var account = root.service.accounts[index]
        rows.push({
          service: account.service,
          instance: account.instance,
          name: account.displayName,
          selected: account.service === root.service.selectedService,
          status: account.statusText
        })
      }
      return JSON.stringify(rows)
    }
    function selectAccount(target: string): string {
      if (!root.service) return "no accounts"
      // Accept either the full unit name or the bare instance, because a script
      // author will reach for "personal" before "onedrive@personal.service".
      for (var index = 0; index < root.service.accounts.length; index++) {
        var account = root.service.accounts[index]
        if (account.service === target || (account.instance !== "" && account.instance === target)) {
          root.service.selectAccount(account.service, false)
          return "ok"
        }
      }
      return "unknown account: " + target
    }
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
          anchors.bottomMargin: Style.space(3)
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
          anchors.bottomMargin: Style.space(3)
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
