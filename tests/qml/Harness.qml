import QtQuick
import Quickshell
import "../../"

// Executes the REAL Service.qml and Account.qml against stub Quickshell types.
//
// Everything here was previously untestable: the scheduler, the cloud semaphore,
// discovery reconciliation, the notification broker and the per-account command
// vectors live in QML, and the node suites only reach the pure JS beneath them.
// A reviewer put it plainly -- "the suite is green; that is not evidence these
// paths work" -- and this is the answer to that.
//
// Run: qml -I tests/qmlstubs tests/qml/Harness.qml   (exit 0 = pass)

Item {
  id: harness

  property int failures: 0
  property var log: []

  function check(condition, description) {
    if (!condition) {
      failures += 1
      console.log("  FAIL  " + description)
    } else {
      console.log("  ok    " + description)
    }
  }

  function discoveryPayload(names) {
    var rows = []
    for (var i = 0; i < names.length; i++) {
      rows.push({
        service: "onedrive@" + names[i] + ".service",
        instance: names[i],
        confdir: "/c/" + names[i],
        description: "OneDrive sync (" + names[i] + " account)"
      })
    }
    return JSON.stringify(rows)
  }

  function statusPayload(overrides) {
    var base = {
      ok: true, installed: true, serviceAvailable: true, running: true,
      enabled: true, activeState: "active", serviceFailed: false,
      resyncRequired: false, authenticated: true, reauthRequired: false,
      syncing: false, syncStage: "", statusText: "Monitoring", syncDir: "/d",
      syncMode: "Two-way", clientVersion: "v", resumeAt: 0, lastSyncTs: 0,
      usedBytes: 0, quotaBytes: 0, quotaKnown: false, quotaCheckedTs: 0,
      quotaError: "", remoteStatus: "Not checked", syncStatusCheckedTs: 0,
      syncStatusError: "", remoteCheckedTs: 0, remoteError: "", files: [],
      activity: [], lastError: ""
    }
    for (var key in overrides) base[key] = overrides[key]
    return JSON.stringify(base)
  }

  // Finish whichever status process is running for a given service.
  function finishStatus(service, payload, exitCode) {
    var live = Quickshell.running()
    for (var i = 0; i < live.length; i++) {
      var command = live[i].command || []
      var isStatus = command.indexOf("--list-accounts") === -1
        && command.join(" ").indexOf("onedrive-status.py") !== -1
      if (!isStatus) continue
      var at = command.indexOf("--service")
      var target = at === -1 ? "onedrive.service" : command[at + 1]
      if (target === service) return live[i].finish(exitCode === undefined ? 0 : exitCode, payload)
    }
    return false
  }

  function runningStatusServices() {
    var out = []
    var live = Quickshell.running()
    for (var i = 0; i < live.length; i++) {
      var command = live[i].command || []
      if (command.indexOf("--list-accounts") !== -1) continue
      if (command.join(" ").indexOf("onedrive-status.py") === -1) continue
      var at = command.indexOf("--service")
      out.push(at === -1 ? "onedrive.service" : command[at + 1])
    }
    return out
  }

  Service {
    id: svc
    settings: ({ refreshIntervalSec: 10, recentFileLimit: 5, notifications: true })
  }

  property int step: 0
  property var firstObjects: []

  Timer {
    interval: 60
    repeat: true
    running: true
    onTriggered: {
      harness.step += 1
      var s = harness.step

      if (s === 1) {
        console.log("discovery and reconciliation")
        var disc = Quickshell.runningWith("--list-accounts")
        harness.check(disc.length === 1, "discovery runs once at startup")
        if (disc.length) disc[0].finish(0, harness.discoveryPayload(["a", "b", "c"]))
      }

      else if (s === 2) {
        harness.check(svc.accountCount === 3, "three accounts discovered")
        harness.firstObjects = svc.accounts.slice()
        // The identity the shadowing bug corrupted, read from INSIDE Account.
        harness.check(svc.accounts[1].service === "onedrive@b.service",
          "each Account carries its own service")
        harness.check(svc.accounts[1].confdir === "/c/b",
          "each Account carries its own confdir")
        harness.check(svc.accounts[1].resumeUnit === "omaonedrive-resume@b",
          "each Account derives its own resume unit")
        harness.check(svc.aggregate.kind === "checking",
          "aggregate is checking before any account reports")
      }

      else if (s === 3) {
        console.log("scheduler")
        var before = harness.runningStatusServices().length
        svc.pollNextAccount()
        var after = harness.runningStatusServices()
        harness.check(after.length === before + 1, "a slot starts exactly one status poll")
        // A second slot while one is in flight must start nothing.
        svc.pollNextAccount()
        harness.check(harness.runningStatusServices().length === after.length,
          "a second slot starts nothing while a poll is in flight")
        harness.polled = after[after.length - 1]
      }

      else if (s === 4) {
        harness.finishStatus(harness.polled, harness.statusPayload({}))
        svc.pollNextAccount()
        var now = harness.runningStatusServices()
        harness.check(now.length === 1 && now[0] !== harness.polled,
          "the next slot polls a DIFFERENT account (round-robin, no monopoly)")
        harness.second = now[0]
      }

      else if (s === 5) {
        harness.finishStatus(harness.second, harness.statusPayload({}))
        svc.pollNextAccount()
        var third = harness.runningStatusServices()
        harness.check(third.length === 1
          && third[0] !== harness.polled && third[0] !== harness.second,
          "all three accounts are reached within one round")
        harness.finishStatus(third[0], harness.statusPayload({}))
      }

      else if (s === 6) {
        console.log("aggregate and identity preservation")
        harness.check(svc.aggregate.initialized === true,
          "aggregate initialises once accounts report")
        harness.check(svc.accounts.length === 3, "still three accounts")
        // A repeat discovery must not recreate delegates.
        svc.reloadAccounts()
      }

      else if (s === 7) {
        var disc2 = Quickshell.runningWith("--list-accounts")
        if (disc2.length) disc2[0].finish(0, harness.discoveryPayload(["a", "b", "c"]))
      }

      else if (s === 8) {
        var same = svc.accounts.length === harness.firstObjects.length
        for (var i = 0; i < svc.accounts.length && same; i++) {
          if (svc.accounts[i] !== harness.firstObjects[i]) same = false
        }
        harness.check(same, "a repeat discovery preserves delegate identity (no churn)")
        harness.check(svc.accounts[0].initialized === true,
          "...and preserves the sample, so state is not wiped every 5 minutes")
      }

      else if (s === 9) {
        console.log("cloud semaphore")
        var beforeCloud = Quickshell.running().length
        svc.accounts[0].checkQuota()
        svc.accounts[1].checkQuota()
        svc.accounts[2].checkFullStatus()
        var quotaLive = Quickshell.runningWith("--quota").length
        var syncLive = Quickshell.runningWith("--sync-status").length
        harness.check(quotaLive + syncLive === 1,
          "three simultaneous cloud requests start exactly one process")
      }

      else if (s === 10) {
        console.log("per-account control vectors")
        Quickshell.detached = []
        svc.accounts[1].login()
        var loginCommand = Quickshell.detached.length ? Quickshell.detached[0] : []
        harness.check(loginCommand.indexOf("--confdir") !== -1
          && loginCommand[loginCommand.indexOf("--confdir") + 1] === "/c/b",
          "login targets the selected account's own confdir")
      }

      else if (s === 11) {
        console.log("an unknown confdir must not freeze the fleet")
        // The shape that bricked the widget: a non-default service with no
        // confdir yields an empty command, which must never reach a Process.
        // Drain anything still in flight first, or `refreshing` is legitimately
        // true from the cloud check above and the assertion below would pass or
        // fail for the wrong reason.
        var live = Quickshell.running()
        for (var d = 0; d < live.length; d++) live[d].finish(0, harness.statusPayload({}))
        harness.check(svc.accounts[0].refreshing === false, "drained before the freeze check")
        var spawnsBefore = Quickshell.spawnCount
        svc.accounts[0].confdir = ""
        svc.accounts[0].refresh(false)
        harness.check(Quickshell.spawnCount === spawnsBefore,
          "an account with no confdir spawns no process")
        harness.check(svc.accounts[0].refreshing === false,
          "...and does not latch `refreshing`, which would freeze every account")
        svc.pollNextAccount()
        harness.check(harness.runningStatusServices().length >= 1,
          "...so the scheduler keeps polling the other accounts")
      }

      else if (s >= 12) {
        console.log(harness.failures === 0
          ? "QML harness: all checks passed"
          : "QML harness: " + harness.failures + " FAILED")
        Qt.exit(harness.failures === 0 ? 0 : 1)
      }
    }
  }

  property string polled: ""
  property string second: ""
}
