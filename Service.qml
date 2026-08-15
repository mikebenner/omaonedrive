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
  property bool authenticated: false
  property bool syncing: false
  property int _desired: -1
  readonly property bool active: _desired === -1 ? running : _desired === 1
  property bool refreshing: false
  property string statusText: "Checking…"
  property string syncDir: ""
  property double lastSyncTs: 0
  property double usedBytes: 0
  property double quotaBytes: 0
  property bool quotaKnown: false
  property string remoteStatus: "Not checked"
  property double remoteCheckedTs: 0
  property var files: []
  property string actionStatus: ""
  property string lastError: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 10, 3600)
  readonly property int recentFileLimit: intSetting("recentFileLimit", 20, 5, 50)
  readonly property string helperPath: Model.filePath(Qt.resolvedUrl("onedrive-status.py"))
  readonly property bool busy: statusProcess.running || controlProcess.running

  property bool _remoteRequested: false
  property string _statusOutput: ""
  property string _statusError: ""
  property string _controlOutput: ""
  property string _controlError: ""

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
    if (remote === true) _remoteRequested = true
    if (statusProcess.running || helperPath === "") return
    var useRemote = _remoteRequested
    _remoteRequested = false
    _statusOutput = ""
    _statusError = ""
    refreshing = true
    if (useRemote) actionStatus = "Checking OneDrive cloud…"
    var command = ["python3", helperPath, "--limit", String(recentFileLimit)]
    if (useRemote) command.push("--remote")
    statusProcess.command = command
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = parsed.lastError || "Failed to read OneDrive status"
      return
    }
    installed = parsed.installed === true
    serviceAvailable = parsed.serviceAvailable === true
    running = parsed.running === true
    enabled = parsed.enabled === true
    authenticated = parsed.authenticated === true
    syncing = parsed.syncing === true
    if (_desired !== -1 && running === (_desired === 1)) _desired = -1
    statusText = String(parsed.statusText || (installed ? "Sync paused" : "Not installed"))
    syncDir = String(parsed.syncDir || "")
    lastSyncTs = Number(parsed.lastSyncTs || 0)
    usedBytes = Number(parsed.usedBytes || 0)
    quotaBytes = Number(parsed.quotaBytes || 0)
    quotaKnown = parsed.quotaKnown === true
    remoteStatus = String(parsed.remoteStatus || "Not checked")
    remoteCheckedTs = Number(parsed.remoteCheckedTs || 0)
    files = parsed.files || []
    lastError = String(parsed.lastError || "")
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

  function pause() {
    runControl(["systemctl", "--user", "stop", "onedrive.service"], 0)
  }

  function resume() {
    if (!authenticated) {
      login()
      return
    }
    runControl(["systemctl", "--user", "start", "onedrive.service"], 1)
  }

  function toggleRunning() {
    if (active) pause()
    else resume()
  }

  function runControl(command, desired) {
    if (!installed || !serviceAvailable || controlProcess.running) return
    _desired = desired
    _controlOutput = ""
    _controlError = ""
    controlProcess.command = command
    controlProcess.running = true
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
      root.refreshing = false
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else root.lastError = root.elideStatus(stderr || stdout || "Could not read OneDrive status")
      if (root.actionStatus === "Checking OneDrive cloud…") {
        root.actionStatus = exitCode === 0
          ? (root.lastError === "" ? "Cloud status updated" : "Cloud check incomplete")
          : root.lastError
        actionStatusTimer.restart()
      }
      if (root._remoteRequested) Qt.callLater(function() { root.refresh(true) })
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
      var stdout = String(controlStdout.text || root._controlOutput || "")
      var stderr = String(controlStderr.text || root._controlError || "")
      if (exitCode !== 0) {
        root._desired = -1
        root.lastError = root.elideStatus(stderr || stdout || "OneDrive service command failed")
      } else {
        root.lastError = ""
        settleTimer.ticks = 0
        settleTimer.start()
      }
      delayedRefresh.restart()
    }
  }
}
