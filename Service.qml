import QtQuick
import QtQml.Models
import Quickshell.Io
import "Model.js" as Model
import "Commands.js" as Commands

// Coordinator over every discovered OneDrive account.
//
// It owns discovery, selection, aggregation and scheduling; each Account owns
// its own state and processes. The panel and bar widget bind to the selected
// account through the forwarding block near the bottom, so a single-account
// install behaves exactly as it did before discovery existed.
Item {
  id: root

  property var settings: ({})

  property var _accountObjects: []
  property int _aggregateRevision: 0

  readonly property var accounts: _accountObjects
  readonly property int accountCount: accounts.length
  property string selectedService: ""

  readonly property var selectedAccount: {
    var found = accountForService(selectedService)
    if (found) return found
    return accounts.length > 0 ? accounts[0] : null
  }

  readonly property var aggregate: {
    void(_aggregateRevision)
    return Model.aggregateAccounts(accounts)
  }

  readonly property bool notificationsEnabled: {
    var value = setting("notifications", true)
    return value === true || String(value).toLowerCase() === "true"
  }
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 10, 3600)
  readonly property int recentFileLimit: intSetting("recentFileLimit", 20, 5, 50)
  readonly property string helperPath: Model.filePath(Qt.resolvedUrl("onedrive-status.py"))

  property string discoveryError: ""

  signal openPanelRequested()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  function accountForService(service) {
    for (var index = 0; index < _accountObjects.length; index++) {
      if (_accountObjects[index].service === service) return _accountObjects[index]
    }
    return null
  }

  function selectAccount(service) {
    var found = accountForService(service)
    if (!found) return
    selectedService = found.service
    found.refresh(false)
    found.retryStaleQuotaOnOpen()
  }

  // --- discovery ------------------------------------------------------------

  // Reconcile by the stable service key rather than clearing and rebuilding:
  // recreating delegates would drop in-flight processes and the notification
  // edge history that decides whether a condition is new.
  function applyDiscovery(rows) {
    var current = []
    for (var scan = 0; scan < descriptors.count; scan++) current.push(descriptors.get(scan).service)

    var plan = Model.reconcilePlan(current, rows)
    for (var update = 0; update < plan.updates.length; update++) {
      descriptors.set(plan.updates[update].index, normalizeDescriptor(plan.updates[update].row))
    }
    for (var append = 0; append < plan.appends.length; append++) {
      descriptors.append(normalizeDescriptor(plan.appends[append]))
    }
    for (var remove = 0; remove < plan.removes.length; remove++) {
      descriptors.remove(plan.removes[remove])
    }

    if (descriptors.count === 0) descriptors.append(defaultDescriptor())
    // A removed selected account falls back to the first discovered one.
    if (accountForService(selectedService) === null) {
      selectedService = descriptors.count > 0 ? descriptors.get(0).service : ""
    }
  }

  function normalizeDescriptor(row) {
    return {
      service: String(row.service || ""),
      instance: String(row.instance || ""),
      confdir: String(row.confdir || ""),
      description: String(row.description || "")
    }
  }

  // The compatibility guarantee: with no template instances this is what
  // discovery returns, and it is also what we fall back to if discovery fails.
  function defaultDescriptor() {
    return {
      service: Commands.DEFAULT_SERVICE,
      instance: "",
      confdir: "",
      description: ""
    }
  }

  function reloadAccounts() {
    if (discoveryProcess.running || helperPath === "") return
    discoveryProcess.command = Commands.listAccounts(helperPath)
    discoveryProcess.running = true
  }

  function trackAccount(object) {
    var next = _accountObjects.slice()
    next.push(object)
    _accountObjects = next
    _aggregateRevision++
  }

  function untrackAccount(object) {
    var next = []
    for (var index = 0; index < _accountObjects.length; index++) {
      if (_accountObjects[index] !== object) next.push(_accountObjects[index])
    }
    _accountObjects = next
    _aggregateRevision++
  }

  // --- scheduling -----------------------------------------------------------

  property int _pollCursor: 0

  // One routine status process at a time across every account, so N accounts
  // cost one subprocess per slot rather than N at once.
  function routinePollRunning() {
    for (var index = 0; index < _accountObjects.length; index++) {
      if (_accountObjects[index].refreshing) return true
    }
    return false
  }

  // Accounts still ramping up at startup get the next slot ahead of the
  // round-robin, which preserves the old startup ramp without giving every
  // account its own two-second timer.
  function nextAccountToPoll() {
    if (_accountObjects.length === 0) return null
    for (var ramp = 0; ramp < _accountObjects.length; ramp++) {
      var candidate = _accountObjects[ramp]
      if (candidate.ramping && !candidate.refreshing) {
        candidate.rampTicks += 1
        return candidate
      }
    }
    for (var step = 0; step < _accountObjects.length; step++) {
      var index = (_pollCursor + step) % _accountObjects.length
      var account = _accountObjects[index]
      if (!account.refreshing) {
        _pollCursor = (index + 1) % _accountObjects.length
        return account
      }
    }
    return null
  }

  function pollNextAccount() {
    if (routinePollRunning()) return
    var account = nextAccountToPoll()
    if (account) account.refresh(false)
  }

  // --- cloud check semaphore ------------------------------------------------

  // Explicit cloud checks are slow (up to 30s) and are never automatic. One at a
  // time across all accounts, de-duplicated by (service, mode) so repeated
  // clicks cannot queue a backlog.
  property var _cloudQueue: []

  function requestCloud(account, mode) {
    if (!account || mode === "") return
    if (cloudBusyAccount() !== null) {
      for (var index = 0; index < _cloudQueue.length; index++) {
        if (_cloudQueue[index].service === account.service && _cloudQueue[index].mode === mode) return
      }
      var next = _cloudQueue.slice()
      next.push({ service: account.service, mode: mode })
      _cloudQueue = next
      return
    }
    account.startCloudCheck(mode)
  }

  function cloudBusyAccount() {
    for (var index = 0; index < _accountObjects.length; index++) {
      if (_accountObjects[index].cloudChecking) return _accountObjects[index]
    }
    return null
  }

  function cloudFinished() {
    // pollFinished fires for routine polls too; only advance when the shared
    // slot is actually free.
    if (cloudBusyAccount() !== null) return
    if (_cloudQueue.length === 0) return
    var next = _cloudQueue.slice()
    var entry = next.shift()
    _cloudQueue = next
    var account = accountForService(entry.service)
    // An account removed while queued simply drops out.
    if (account) account.startCloudCheck(entry.mode)
  }

  // --- selected-account facade ----------------------------------------------
  //
  // Panel.qml and BarWidget.qml still say `oneDrive.running`. Every forward is
  // null-safe: between startup and the first descriptor there is no account.

  readonly property bool installed: selectedAccount ? selectedAccount.installed : false
  readonly property bool serviceAvailable: selectedAccount ? selectedAccount.serviceAvailable : false
  readonly property bool running: selectedAccount ? selectedAccount.running : false
  readonly property bool enabled: selectedAccount ? selectedAccount.enabled : false
  readonly property string activeState: selectedAccount ? selectedAccount.activeState : ""
  readonly property bool serviceFailed: selectedAccount ? selectedAccount.serviceFailed : false
  readonly property bool resyncRequired: selectedAccount ? selectedAccount.resyncRequired : false
  readonly property bool authenticated: selectedAccount ? selectedAccount.authenticated : false
  readonly property bool reauthRequired: selectedAccount ? selectedAccount.reauthRequired : false
  readonly property bool syncing: selectedAccount ? selectedAccount.syncing : false
  readonly property string syncStage: selectedAccount ? selectedAccount.syncStage : ""
  readonly property bool active: selectedAccount ? selectedAccount.active : false
  readonly property bool refreshing: selectedAccount ? selectedAccount.refreshing : false
  readonly property string statusText: selectedAccount ? selectedAccount.statusText : "Checking…"
  readonly property string syncDir: selectedAccount ? selectedAccount.syncDir : ""
  readonly property string syncMode: selectedAccount ? selectedAccount.syncMode : "Two-way"
  readonly property string clientVersion: selectedAccount ? selectedAccount.clientVersion : ""
  readonly property double resumeAt: selectedAccount ? selectedAccount.resumeAt : 0
  readonly property double lastSyncTs: selectedAccount ? selectedAccount.lastSyncTs : 0
  readonly property double usedBytes: selectedAccount ? selectedAccount.usedBytes : 0
  readonly property double quotaBytes: selectedAccount ? selectedAccount.quotaBytes : 0
  readonly property bool quotaKnown: selectedAccount ? selectedAccount.quotaKnown : false
  readonly property double quotaCheckedTs: selectedAccount ? selectedAccount.quotaCheckedTs : 0
  readonly property string quotaError: selectedAccount ? selectedAccount.quotaError : ""
  readonly property string remoteStatus: selectedAccount ? selectedAccount.remoteStatus : "Not checked"
  readonly property double syncStatusCheckedTs: selectedAccount ? selectedAccount.syncStatusCheckedTs : 0
  readonly property string syncStatusError: selectedAccount ? selectedAccount.syncStatusError : ""
  readonly property double remoteCheckedTs: selectedAccount ? selectedAccount.remoteCheckedTs : 0
  readonly property string remoteError: selectedAccount ? selectedAccount.remoteError : ""
  readonly property var files: selectedAccount ? selectedAccount.files : []
  readonly property var activity: selectedAccount ? selectedAccount.activity : []
  readonly property string actionStatus: selectedAccount ? selectedAccount.actionStatus : ""
  readonly property string lastError: selectedAccount ? selectedAccount.lastError : discoveryError
  readonly property bool busy: selectedAccount ? selectedAccount.busy : false
  readonly property bool cloudChecking: selectedAccount ? selectedAccount.cloudChecking : false
  readonly property bool quotaChecking: selectedAccount ? selectedAccount.quotaChecking : false
  readonly property bool fullStatusChecking: selectedAccount ? selectedAccount.fullStatusChecking : false
  readonly property int cloudTimeoutSec: 30
  readonly property int cloudRetryAfterSec: 300

  function refresh(remote) { if (selectedAccount) selectedAccount.refresh(remote) }
  function checkQuota() { if (selectedAccount) selectedAccount.checkQuota() }
  function checkFullStatus() { if (selectedAccount) selectedAccount.checkFullStatus() }
  function retryStaleQuotaOnOpen() { if (selectedAccount) selectedAccount.retryStaleQuotaOnOpen() }
  function login() { if (selectedAccount) selectedAccount.login() }
  function reauthenticate() { if (selectedAccount) selectedAccount.reauthenticate() }
  function repairResync() { if (selectedAccount) selectedAccount.repairResync() }
  function openWeb() { if (selectedAccount) selectedAccount.openWeb() }
  function openFolder() { if (selectedAccount) selectedAccount.openFolder() }
  function openFile(file) { if (selectedAccount) selectedAccount.openFile(file) }
  function pause() { if (selectedAccount) selectedAccount.pause() }
  function pauseFor(minutes) { if (selectedAccount) selectedAccount.pauseFor(minutes) }
  function resume() { if (selectedAccount) selectedAccount.resume() }
  function toggleRunning() { if (selectedAccount) selectedAccount.toggleRunning() }

  // --- wiring ---------------------------------------------------------------

  ListModel { id: descriptors }

  Instantiator {
    id: accountInstances
    model: descriptors
    delegate: Account {
      required property string service
      required property string instance
      required property string confdir
      required property string description
      settings: root.settings
      coordinator: root
      onStateChanged: root._aggregateRevision++
      onOpenPanelRequested: root.openPanelRequested()
      onPollFinished: root.cloudFinished()
    }
    onObjectAdded: function(index, object) { root.trackAccount(object) }
    onObjectRemoved: function(index, object) { root.untrackAccount(object) }
  }

  Process {
    id: discoveryProcess
    running: false
    command: []
    stdout: StdioCollector { id: discoveryStdout; waitForEnd: true }
    stderr: StdioCollector { id: discoveryStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        // Non-destructive: keep whatever accounts we already have, and seed the
        // compatibility fallback if this was the first attempt.
        root.discoveryError = String(discoveryStderr.text || "").trim()
        if (descriptors.count === 0) root.applyDiscovery([root.defaultDescriptor()])
        return
      }
      root.discoveryError = ""
      var rows = []
      try {
        var parsed = JSON.parse(String(discoveryStdout.text || "[]"))
        if (Array.isArray(parsed)) rows = parsed
      } catch (error) {
        rows = []
      }
      if (rows.length === 0) rows = [root.defaultDescriptor()]
      root.applyDiscovery(rows)
    }
  }

  // Slots are spread across the interval, so three accounts at the default
  // setting start about ten seconds apart and each is still polled about every
  // thirty seconds.
  Timer {
    id: pollScheduler
    interval: Math.max(1000, Math.round(root.refreshIntervalSec * 1000 / Math.max(1, root.accountCount)))
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.pollNextAccount()
  }

  // Units can be enabled or removed while the widget runs.
  Timer {
    interval: 300000
    repeat: true
    running: true
    onTriggered: root.reloadAccounts()
  }

  Component.onCompleted: {
    // Seed the compatibility descriptor immediately so the panel has an account
    // to bind to before the first discovery returns; discovery then reconciles
    // it in place rather than replacing it.
    descriptors.append(defaultDescriptor())
    selectedService = Commands.DEFAULT_SERVICE
    reloadAccounts()
  }
}
