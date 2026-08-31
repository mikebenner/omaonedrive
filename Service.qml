import QtQuick
import "Model.js" as Model

// Coordinator over one or more Account objects.
//
// This step keeps exactly one account -- the helper's own defaults -- so the
// panel and bar widget continue to bind to `oneDrive.foo` unchanged while the
// account-scoped state and processes live in Account.qml. Discovery and the
// multi-account fan-out land on top of this without moving that state again.
Item {
  id: root

  property var settings: ({})

  readonly property var accounts: [defaultAccount]
  readonly property int accountCount: accounts.length
  readonly property var selectedAccount: defaultAccount
  property string selectedService: defaultAccount.service

  readonly property var aggregate: {
    void(_aggregateRevision)
    return Model.aggregateAccounts(accounts)
  }
  property int _aggregateRevision: 0

  signal openPanelRequested()

  function accountForService(service) {
    for (var index = 0; index < accounts.length; index++) {
      if (accounts[index].service === service) return accounts[index]
    }
    return null
  }

  function selectAccount(service) {
    var found = accountForService(service)
    if (found) selectedService = found.service
  }

  // --- selected-account facade --------------------------------------------
  //
  // Every binding below forwards to the selected account. Panel.qml and
  // BarWidget.qml still say `oneDrive.running`, so this whole block exists to
  // let the state move without touching either of them in the same commit.

  readonly property bool installed: selectedAccount.installed
  readonly property bool serviceAvailable: selectedAccount.serviceAvailable
  readonly property bool running: selectedAccount.running
  readonly property bool enabled: selectedAccount.enabled
  readonly property string activeState: selectedAccount.activeState
  readonly property bool serviceFailed: selectedAccount.serviceFailed
  readonly property bool resyncRequired: selectedAccount.resyncRequired
  readonly property bool authenticated: selectedAccount.authenticated
  readonly property bool reauthRequired: selectedAccount.reauthRequired
  readonly property bool syncing: selectedAccount.syncing
  readonly property string syncStage: selectedAccount.syncStage
  readonly property bool active: selectedAccount.active
  readonly property bool refreshing: selectedAccount.refreshing
  readonly property string statusText: selectedAccount.statusText
  readonly property string syncDir: selectedAccount.syncDir
  readonly property string syncMode: selectedAccount.syncMode
  readonly property string clientVersion: selectedAccount.clientVersion
  readonly property double resumeAt: selectedAccount.resumeAt
  readonly property double lastSyncTs: selectedAccount.lastSyncTs
  readonly property double usedBytes: selectedAccount.usedBytes
  readonly property double quotaBytes: selectedAccount.quotaBytes
  readonly property bool quotaKnown: selectedAccount.quotaKnown
  readonly property double quotaCheckedTs: selectedAccount.quotaCheckedTs
  readonly property string quotaError: selectedAccount.quotaError
  readonly property string remoteStatus: selectedAccount.remoteStatus
  readonly property double syncStatusCheckedTs: selectedAccount.syncStatusCheckedTs
  readonly property string syncStatusError: selectedAccount.syncStatusError
  readonly property double remoteCheckedTs: selectedAccount.remoteCheckedTs
  readonly property string remoteError: selectedAccount.remoteError
  readonly property var files: selectedAccount.files
  readonly property var activity: selectedAccount.activity
  readonly property string actionStatus: selectedAccount.actionStatus
  readonly property string lastError: selectedAccount.lastError
  readonly property bool busy: selectedAccount.busy
  readonly property bool cloudChecking: selectedAccount.cloudChecking
  readonly property bool quotaChecking: selectedAccount.quotaChecking
  readonly property bool fullStatusChecking: selectedAccount.fullStatusChecking
  readonly property int cloudTimeoutSec: selectedAccount.cloudTimeoutSec
  readonly property int cloudRetryAfterSec: selectedAccount.cloudRetryAfterSec

  function refresh(remote) { selectedAccount.refresh(remote) }
  function checkQuota() { selectedAccount.checkQuota() }
  function checkFullStatus() { selectedAccount.checkFullStatus() }
  function retryStaleQuotaOnOpen() { selectedAccount.retryStaleQuotaOnOpen() }
  function login() { selectedAccount.login() }
  function reauthenticate() { selectedAccount.reauthenticate() }
  function repairResync() { selectedAccount.repairResync() }
  function openWeb() { selectedAccount.openWeb() }
  function openFolder() { selectedAccount.openFolder() }
  function openFile(file) { selectedAccount.openFile(file) }
  function pause() { selectedAccount.pause() }
  function pauseFor(minutes) { selectedAccount.pauseFor(minutes) }
  function resume() { selectedAccount.resume() }
  function toggleRunning() { selectedAccount.toggleRunning() }

  Account {
    id: defaultAccount
    settings: root.settings
    coordinator: root
    onStateChanged: root._aggregateRevision++
    onOpenPanelRequested: root.openPanelRequested()
  }
}
