import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  property bool installed: false
  property bool serviceAvailable: false
  property bool running: false
  property bool enabled: false
  property string activeState: ""
  property bool serviceFailed: false
  property bool resyncRequired: false
  property bool authenticated: false
  property bool reauthRequired: false
  property bool syncing: false
  property string syncStage: ""
  property int _desired: -1
  readonly property bool active: _desired === -1
    ? (running || activeState === "activating") : _desired === 1
  property bool refreshing: false
  property string statusText: "Checking…"
  property string syncDir: ""
  property string syncMode: "Two-way"
  property string clientVersion: ""
  property double resumeAt: 0
  property double lastSyncTs: 0
  property double usedBytes: 0
  property double quotaBytes: 0
  property bool quotaKnown: false
  property double quotaCheckedTs: 0
  property string quotaError: ""
  property string remoteStatus: "Not checked"
  property double syncStatusCheckedTs: 0
  property string syncStatusError: ""
  property double remoteCheckedTs: 0
  property string remoteError: ""
  property var files: []
  property var activity: []
  property string actionStatus: ""
  property string lastError: ""

  readonly property bool notificationsEnabled: {
    var value = setting("notifications", true)
    return value === true || String(value).toLowerCase() === "true"
  }
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 10, 3600)
  readonly property int recentFileLimit: intSetting("recentFileLimit", 20, 5, 50)
  readonly property string helperPath: Model.filePath(Qt.resolvedUrl("onedrive-status.py"))
  readonly property bool busy: statusProcess.running || controlProcess.running
    || cancelTimerProcess.running || scheduleTimerProcess.running
  readonly property string resumeUnit: "omaonedrive-resume"
  readonly property bool cloudChecking: _activeCloudMode !== "" && statusProcess.running
  readonly property bool quotaChecking: _activeCloudMode === "quota" && statusProcess.running
  readonly property bool fullStatusChecking: _activeCloudMode === "sync-status" && statusProcess.running

  // Must match QUOTA_TIMEOUT_SECONDS / SYNC_STATUS_TIMEOUT_SECONDS in onedrive-status.py.
  readonly property int cloudTimeoutSec: 30
  readonly property int cloudRetryAfterSec: 300

  property string _cloudRequested: ""
  property string _activeCloudMode: ""
  property string _statusOutput: ""
  property string _statusError: ""
  property string _controlOutput: ""
  property string _controlError: ""
  property string _timerOutput: ""
  property string _timerError: ""
  property string _afterTimerCancel: ""
  property int _pauseMinutes: 0
  property int _controlDesired: -1
  property bool _scheduleRecovery: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  function refresh(remote) {
    if (remote === true) {
      checkQuota()
      return
    }
    if (statusProcess.running || helperPath === "") return
    startStatusProcess("")
  }

  function checkQuota() {
    requestCloudCheck("quota")
  }

  // Opening the panel is explicit user intent, so a failed storage result
  // older than cloudRetryAfterSec is retried once on open. The decision is
  // deferred until the next status poll returns, because at open() time the
  // in-memory state may predate the poll the panel just started.
  // quotaCheckedTs updates even on failure, which blocks another retry until
  // the window passes. Verify sync is never retried automatically — it is
  // the expensive full-drive check and stays strictly manual.
  property bool _quotaRetryQueued: false

  function retryStaleQuotaOnOpen() {
    _quotaRetryQueued = true
  }

  function maybeRetryStaleQuota() {
    if (quotaError === "" || quotaChecking) return
    if (Date.now() / 1000 - quotaCheckedTs < cloudRetryAfterSec) return
    checkQuota()
  }

  function checkFullStatus() {
    requestCloudCheck("sync-status")
  }

  function requestCloudCheck(mode) {
    if (helperPath === "") return
    if (statusProcess.running) {
      _cloudRequested = mode
      return
    }
    startStatusProcess(mode)
  }

  function startStatusProcess(cloudMode) {
    _activeCloudMode = cloudMode
    _statusOutput = ""
    _statusError = ""
    refreshing = true
    var command = ["python3", helperPath, "--limit", String(recentFileLimit)]
    if (cloudMode === "quota") command.push("--quota")
    else if (cloudMode === "sync-status") command.push("--sync-status")
    if (cloudMode !== "") {
      actionStatusTimer.stop()
      actionStatus = (cloudMode === "quota" ? "Refreshing storage" : "Verifying sync")
        + "… may take up to " + String(cloudTimeoutSec) + "s"
    }
    statusProcess.command = command
    statusProcess.running = true
  }

  function notify(urgency, summary, body) {
    if (!notificationsEnabled) return
    Quickshell.execDetached([
      "omarchy-notification-send", "--app-name", "OmaOneDrive", "--urgency", urgency,
      summary, body
    ])
  }

  function notifyWithAction(urgency, summary, body, behavior) {
    if (!notificationsEnabled) return
    var actionCommand = Model.notificationActionCommand(behavior)
    if (actionCommand === "") {
      notify(urgency, summary, body)
      return
    }
    Quickshell.execDetached([
      "omarchy-notification-send", "--app-name", "OmaOneDrive", "--urgency", urgency,
      "--exec", actionCommand, summary, body
    ])
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = parsed.lastError || "Failed to read OneDrive status"
      return
    }
    var wasFailed = serviceFailed
    var wasResync = resyncRequired
    var wasReauth = reauthRequired
    var hadAttention = serviceFailed || resyncRequired || reauthRequired
    var wasStorageSevere = Model.usageSevere(usedBytes, quotaBytes, quotaKnown)
    installed = parsed.installed === true
    serviceAvailable = parsed.serviceAvailable === true
    running = parsed.running === true
    enabled = parsed.enabled === true
    activeState = String(parsed.activeState || "")
    serviceFailed = parsed.serviceFailed === true
    resyncRequired = parsed.resyncRequired === true
    authenticated = parsed.authenticated === true
    reauthRequired = parsed.reauthRequired === true
    syncing = parsed.syncing === true
    syncStage = String(parsed.syncStage || "")
    if (_desired !== -1 && running === (_desired === 1)) _desired = -1
    statusText = String(parsed.statusText || (installed ? "Sync paused" : "Not installed"))
    syncDir = String(parsed.syncDir || "")
    syncMode = String(parsed.syncMode || "Two-way")
    clientVersion = String(parsed.clientVersion || "")
    resumeAt = Number(parsed.resumeAt || 0)
    lastSyncTs = Number(parsed.lastSyncTs || 0)
    usedBytes = Number(parsed.usedBytes || 0)
    quotaBytes = Number(parsed.quotaBytes || 0)
    quotaKnown = parsed.quotaKnown === true
    quotaCheckedTs = Number(parsed.quotaCheckedTs || 0)
    quotaError = String(parsed.quotaError || "")
    remoteStatus = String(parsed.remoteStatus || "Not checked")
    syncStatusCheckedTs = Number(parsed.syncStatusCheckedTs || 0)
    syncStatusError = String(parsed.syncStatusError || "")
    remoteCheckedTs = Number(parsed.remoteCheckedTs || 0)
    remoteError = String(parsed.remoteError || "")
    files = parsed.files || []
    activity = parsed.activity || []
    lastError = String(parsed.lastError || "")

    if (resyncRequired && !wasResync)
      notifyWithAction("critical", "OneDrive needs a resync",
        "Syncing stopped until the resync repair runs.",
        "repair")
    else if (serviceFailed && !wasFailed)
      notifyWithAction("critical", "OneDrive sync failed",
        lastError !== "" ? lastError : "The OneDrive service entered a failed state.",
        "open")
    if (reauthRequired && !wasReauth)
      notifyWithAction("critical", "OneDrive needs reauthentication",
        "Sign in again to keep syncing.",
        "open")
    if (hadAttention && !serviceFailed && !resyncRequired && !reauthRequired)
      notify("normal", "OneDrive recovered", "Syncing is healthy again.")
    if (!wasStorageSevere && Model.usageSevere(usedBytes, quotaBytes, quotaKnown))
      notify("normal", "OneDrive storage almost full",
        Model.freeText(usedBytes, quotaBytes, quotaKnown) + " of "
          + Model.formatBytes(quotaBytes) + " remains.")
  }

  function elideStatus(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 180 ? value.substring(0, 177) + "…" : value
  }

  function login() {
    if (!installed) return
    Quickshell.execDetached(["omarchy-launch-terminal", "onedrive"])
    actionStatus = "Opened OneDrive login"
    actionStatusTimer.restart()
  }

  function reauthenticate() {
    if (!installed || running) return
    Quickshell.execDetached(["omarchy-launch-terminal", "onedrive", "--reauth"])
    actionStatus = "Opened OneDrive reauthentication"
    actionStatusTimer.restart()
  }

  function repairResync() {
    if (!installed || running || busy) return
    Quickshell.execDetached(["omarchy-launch-terminal", "onedrive", "--sync", "--resync"])
    actionStatus = "Opened OneDrive resync repair"
    actionStatusTimer.restart()
  }

  function openWeb() {
    Quickshell.execDetached(["uwsm-app", "--", "xdg-open", "https://onedrive.live.com/"])
  }

  function pause() {
    if (busy) return
    _pauseMinutes = 0
    cancelResumeTimer("pause")
  }

  function pauseFor(minutes) {
    var requested = parseInt(String(minutes), 10)
    if (!isFinite(requested) || requested <= 0) return
    var duration = Math.max(5, Math.min(1440, requested))
    if (!installed || !serviceAvailable || !authenticated || busy
        || serviceFailed || resyncRequired || reauthRequired) return
    _pauseMinutes = duration
    cancelResumeTimer("pause")
  }

  function resume() {
    if (!authenticated) {
      login()
      return
    }
    if (busy) return
    _pauseMinutes = 0
    cancelResumeTimer("resume")
  }

  function toggleRunning() {
    if (active) pause()
    else resume()
  }

  function runControl(command, desired) {
    if (!installed || !serviceAvailable || controlProcess.running) return
    _desired = desired
    _controlDesired = desired
    _controlOutput = ""
    _controlError = ""
    controlProcess.command = command
    controlProcess.running = true
  }

  function cancelResumeTimer(afterAction) {
    _afterTimerCancel = afterAction
    _timerOutput = ""
    _timerError = ""
    cancelTimerProcess.command = [
      "systemctl", "--user", "stop",
      resumeUnit + ".timer", resumeUnit + ".service"
    ]
    cancelTimerProcess.running = true
  }

  function scheduleResume(minutes) {
    _timerOutput = ""
    _timerError = ""
    scheduleTimerProcess.command = [
      "systemd-run", "--user",
      "--unit=" + resumeUnit,
      "--description=Resume OneDrive after timed pause",
      "--on-active=" + String(minutes) + "m",
      "--timer-property=AccuracySec=1s",
      "--collect",
      "/usr/bin/systemctl", "--user", "start", "onedrive.service"
    ]
    scheduleTimerProcess.running = true
  }

  function openFolder() {
    if (syncDir !== "") Quickshell.execDetached(["uwsm-app", "--", "xdg-open", syncDir])
  }

  function openFile(file) {
    if (!file || !file.path) return
    Quickshell.execDetached(["uwsm-app", "--", "nautilus", "--select", fileUri(String(file.path))])
  }

  function fileUri(path) {
    var parts = String(path || "").split("/")
    for (var index = 0; index < parts.length; index++) parts[index] = encodeURIComponent(parts[index])
    return "file://" + parts.join("/")
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Timer {
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    running: true
    onTriggered: {
      ticks += 1
      if (root.running || ticks >= 15) startupRamp.running = false
      else root.refresh(false)
    }
  }

  Timer {
    id: delayedRefresh
    interval: 750
    repeat: false
    onTriggered: root.refresh(false)
  }

  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 1200
    repeat: true
    onTriggered: {
      ticks += 1
      root.refresh(false)
      if (ticks >= 5) {
        ticks = 0
        stop()
        root._desired = -1
      }
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 2500
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
      onStreamFinished: root._statusOutput = text
    }
    stderr: StdioCollector {
      id: statusStderr
      waitForEnd: true
      onStreamFinished: root._statusError = text
    }
    onExited: function(exitCode) {
      var cloudMode = root._activeCloudMode
      root.refreshing = false
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else root.lastError = root.elideStatus(stderr || stdout || "Could not read OneDrive status")
      if (cloudMode !== "") {
        if (exitCode !== 0) root.actionStatus = root.lastError
        else if (cloudMode === "quota")
          root.actionStatus = root.quotaError === "" ? "Storage refreshed" : root.quotaError
        else root.actionStatus = root.syncStatusError === ""
          ? "Sync verified" : root.syncStatusError
        actionStatusTimer.restart()
      }
      root._activeCloudMode = ""
      if (root._cloudRequested !== "") {
        var requested = root._cloudRequested
        root._cloudRequested = ""
        Qt.callLater(function() { root.requestCloudCheck(requested) })
      }
      if (root._quotaRetryQueued) {
        root._quotaRetryQueued = false
        Qt.callLater(function() { root.maybeRetryStaleQuota() })
      }
    }
  }

  Process {
    id: cancelTimerProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var action = root._afterTimerCancel
      root._afterTimerCancel = ""
      root.resumeAt = 0
      if (action === "resume") {
        root.runControl(["systemctl", "--user", "start", "onedrive.service"], 1)
      } else if (action === "pause") {
        if (root.running || root.active || root.activeState === "activating") {
          root.runControl(["systemctl", "--user", "stop", "onedrive.service"], 0)
        } else if (root._pauseMinutes > 0) {
          var minutes = root._pauseMinutes
          root._pauseMinutes = 0
          root.scheduleResume(minutes)
        } else {
          root.refresh(false)
        }
      }
    }
  }

  Process {
    id: scheduleTimerProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: timerStdout
      waitForEnd: true
      onStreamFinished: root._timerOutput = text
    }
    stderr: StdioCollector {
      id: timerStderr
      waitForEnd: true
      onStreamFinished: root._timerError = text
    }
    onExited: function(exitCode) {
      var stdout = String(timerStdout.text || root._timerOutput || "")
      var stderr = String(timerStderr.text || root._timerError || "")
      if (exitCode !== 0) {
        root.lastError = root.elideStatus(stderr || stdout || "Could not schedule OneDrive resume")
        root.actionStatus = "Timed pause failed; resuming syncing…"
        root._scheduleRecovery = true
        root.runControl(["systemctl", "--user", "start", "onedrive.service"], 1)
      } else {
        root.lastError = ""
        root.actionStatus = "Timed pause scheduled"
        actionStatusTimer.restart()
        root.refresh(false)
      }
    }
  }

  Process {
    id: controlProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: controlStdout
      waitForEnd: true
      onStreamFinished: root._controlOutput = text
    }
    stderr: StdioCollector {
      id: controlStderr
      waitForEnd: true
      onStreamFinished: root._controlError = text
    }
    onExited: function(exitCode) {
      var desired = root._controlDesired
      root._controlDesired = -1
      var stdout = String(controlStdout.text || root._controlOutput || "")
      var stderr = String(controlStderr.text || root._controlError || "")
      if (exitCode !== 0) {
        root._desired = -1
        root._pauseMinutes = 0
        root._scheduleRecovery = false
        root.lastError = root.elideStatus(stderr || stdout || "OneDrive service command failed")
      } else {
        root.lastError = ""
        settleTimer.ticks = 0
        settleTimer.start()
        if (desired === 0 && root._pauseMinutes > 0) {
          var minutes = root._pauseMinutes
          root._pauseMinutes = 0
          root.scheduleResume(minutes)
        } else if (root._scheduleRecovery) {
          root._scheduleRecovery = false
          root.actionStatus = "Timed pause failed; syncing resumed"
          actionStatusTimer.restart()
        }
      }
      delayedRefresh.restart()
    }
  }
}
