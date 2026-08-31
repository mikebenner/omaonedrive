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

      else if (s === 12) {
        console.log("notification broker")
        Quickshell.detached = []
        harness.notifyBefore = Quickshell.spawnCount
        // Three accounts report attention across a poll round. The broker must
        // coalesce them into ONE popup, not one per account -- the defect that
        // survived two rounds because the burst window meant "900ms of quiet",
        // which a staggered scheduler never produces.
        for (var n = 0; n < svc.accounts.length; n++) {
          svc.accounts[n].refresh(false)
        }
        for (var m = 0; m < svc.accounts.length; m++) {
          harness.finishStatus(svc.accounts[m].service,
            harness.statusPayload({ reauthRequired: true, statusText: "Reauthentication required" }))
        }
      }

      else if (s === 13) {
        // Nothing may have fired yet: the window spans a poll round.
        var early = Quickshell.detached.length + Quickshell.runningWith("notify-send").length
        harness.check(early === 0, "no notification fires before the burst window closes")
        harness.burstStart = Date.now()
      }

      else if (s === 14) {
        var fired = Quickshell.detached.length + Quickshell.runningWith("notify-send").length
        harness.check(fired <= 1,
          "three accounts failing in one round produce at most ONE notification")
        harness.notified = fired
      }

      else if (s === 15) {
        console.log("per-account pause targets only its own units")
        Quickshell.detached = []
        // Step 12 left every account reauth-required, and pauseFor correctly
        // refuses an account in that state. Return them to healthy first, or
        // this would test the guard rather than the targeting.
        for (var h = 0; h < svc.accounts.length; h++) {
          svc.accounts[h].refresh(false)
        }
        for (var f = 0; f < svc.accounts.length; f++) {
          harness.finishStatus(svc.accounts[f].service, harness.statusPayload({}))
        }
        var target = svc.accounts[1]
        harness.check(target.reauthRequired === false && target.busy === false,
          "target account is healthy and idle before the pause")
        target.pauseFor(15)
        // The cancel runs first; find it and check it names only this account.
        var cancels = Quickshell.runningWith("stop")
        var named = false
        for (var c = 0; c < cancels.length; c++) {
          var joined = (cancels[c].command || []).join(" ")
          if (joined.indexOf("omaonedrive-resume@b") !== -1
              && joined.indexOf("omaonedrive-resume@a") === -1
              && joined.indexOf("omaonedrive-resume.timer") === -1) named = true
        }
        harness.check(named, "a timed pause cancels only that account's own resume unit")
        for (var k = 0; k < cancels.length; k++) cancels[k].finish(0, "")
      }

      else if (s === 16) {
        // After the cancel, the stop for that account's own service.
        var stops = Quickshell.runningWith("onedrive@b.service")
        harness.check(stops.length >= 1, "the pause stops that account's own service")
        var wrong = Quickshell.runningWith("onedrive@a.service").length
          + Quickshell.runningWith("onedrive.service").length
        harness.check(wrong === 0, "...and no other account's service is touched")
        var live = Quickshell.running()
        for (var w = 0; w < live.length; w++) live[w].finish(0, "")
      }

      else if (s === 17) {
        console.log("a repointed confdir forgets the previous account's sample")
        var acct = svc.accounts[2]
        // Deliberately NOT assigning acct.confdir here: a direct assignment
        // destroys the binding to the model role, so the descriptor update could
        // never reach it and the test would fail for a reason of its own making.
        harness.check(acct.initialized === true, "account is initialised before the repoint")
        harness.check(acct.confdir === "/c/c", "starts on its discovered confdir")
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" },
          { service: "onedrive@c.service", instance: "c", confdir: "/NEW/c", description: "C" }
        ])
        harness.check(acct.confdir === "/NEW/c", "the descriptor update reaches the account")
        harness.check(acct.initialized === false,
          "a repointed account forgets its sample")
        harness.check(acct.syncDir === "",
          "...including syncDir, so Open folder cannot open the PREVIOUS directory")
      }

      else if (s === 18) {
        console.log("a continuous stream of events must still flush")
        // The discriminating case. With burstTimer.restart() on every enqueue,
        // the window means "N ms of QUIET" -- so a stream of events arriving
        // closer together than the window never flushes at all, and the user is
        // told nothing. With start(), the window runs from the first event and
        // fires regardless. Reduce to ONE account so the window is 900ms and a
        // 60ms tick loop can outrun it.
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" }
        ])
        Quickshell.detached = []
        harness.streamTicks = 0
      }

      else if (s >= 19 && s <= 40) {
        // One event per tick, faster than the 900ms window.
        svc.enqueueTransition({
          service: "onedrive@a.service", name: "A", kind: "reauth",
          summary: "OneDrive needs reauthentication", short: "Reauthentication required",
          body: "b", action: "open", actionLabel: "Open OneDrive panel"
        })
        harness.streamTicks += 1
      }

      else if (s === 41) {
        var fired = Quickshell.detached.length + Quickshell.runningWith("notify-send").length
        harness.check(fired >= 1,
          "a stream of events flushes rather than being deferred forever (" +
          harness.streamTicks + " events over ~" + (harness.streamTicks * 60) + "ms)")
      }

      else if (s >= 42) {
        console.log(harness.failures === 0
          ? "QML harness: all checks passed"
          : "QML harness: " + harness.failures + " FAILED")
        Qt.exit(harness.failures === 0 ? 0 : 1)
      }
    }
  }

  property string polled: ""
  property string second: ""
  property int notifyBefore: 0
  property int notified: 0
  property double burstStart: 0
  property int streamTicks: 0
}
