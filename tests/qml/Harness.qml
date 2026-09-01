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
  property int checks: 0
  property var log: []

  function check(condition, description) {
    checks += 1
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
      activity: [], lastError: "", confdir: ""
    }
    for (var key in overrides) base[key] = overrides[key]
    return JSON.stringify(base)
  }

  // Every detached command issued so far whose argv contains `text`. Tests clear
  // Quickshell.detached first, so this reads as "what did THIS action launch".
  function detachedWith(text) {
    var hits = []
    for (var i = 0; i < Quickshell.detached.length; i++) {
      var command = (Quickshell.detached[i] || []).join(" ")
      if (command.indexOf(text) !== -1) hits.push(command)
    }
    return hits
  }

  // Live processes are reused objects, not new registrations, so a control or
  // status command is only observable while it is running -- read it in the same
  // tick that started it.
  function liveWith(text) {
    var hits = []
    var live = Quickshell.running()
    for (var i = 0; i < live.length; i++) {
      var command = (live[i].command || []).join(" ")
      if (command.indexOf(text) !== -1) hits.push(command)
    }
    return hits
  }

  // Finish every live process, so an action that chains through one (a resume
  // timer cancel before the control call) can reach its next stage.
  function drain(payload) {
    var live = Quickshell.running()
    for (var i = 0; i < live.length; i++) {
      var command = (live[i].command || []).join(" ")
      live[i].finish(0, command.indexOf("onedrive-status.py") === -1 ? "" : payload)
    }
  }

  // The live status process for a service, as an object (not just its argv), so
  // a test can decide HOW it ends -- exit, or a failure to start.
  function statusProcessFor(service) {
    var live = Quickshell.running()
    for (var i = 0; i < live.length; i++) {
      var command = live[i].command || []
      if (command.indexOf("--list-accounts") !== -1) continue
      if (command.join(" ").indexOf("onedrive-status.py") === -1) continue
      var at = command.indexOf("--service")
      if ((at === -1 ? "onedrive.service" : command[at + 1]) === service) return live[i]
    }
    return null
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
      // A throw inside a step used to abort that step and take every assertion
      // it had not yet reached with it -- silently, with the run still reporting
      // "all checks passed". A step that cannot finish is a failure.
      try {
        harness.runStep(s)
      } catch (error) {
        harness.check(false, "step " + s + " threw: " + error)
        Qt.exit(1)
      }
    }
  }

  function runStep(s) {
    {

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
        // Through discovery, for the same reason: keep the binding intact so
        // later steps can repoint this account.
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" },
          { service: "onedrive@c.service", instance: "c", confdir: "/c/c", description: "C" }
        ])
        // `attempted` is inherited from the polling above, so asserting it here
        // passed whether or not the empty-command branch set it. Clear it first
        // and the assertion is about this branch again.
        svc.accounts[0].forgetSample()
        harness.check(svc.accounts[0].attempted === false,
          "the account starts this check having never been attempted")
        svc.accounts[0].refresh(false)
        harness.check(Quickshell.spawnCount === spawnsBefore,
          "an account with no confdir spawns no process")
        harness.check(svc.accounts[0].refreshing === false,
          "...and does not latch `refreshing`, which would freeze every account")
        harness.check(svc.accounts[0].attempted === true,
          "...and counts as attempted, so the startup hold and ramp can end")
        // Poll every remaining account by name, so this cannot pass because the
        // round-robin happened to pick someone else. Count SPAWNS, not the
        // `refreshing` flag: a cloud check released by the drain above already
        // sets that, so the flag was true whether or not the refresh did
        // anything.
        var reached = 0
        for (var t2 = 0; t2 < svc.accounts.length; t2++) {
          if (svc.accounts[t2] === svc.accounts[0]) continue
          harness.drain(harness.statusPayload({}))
          var before2 = Quickshell.spawnCount
          svc.accounts[t2].refresh(false)
          if (Quickshell.spawnCount === before2 + 1) reached += 1
          harness.finishStatus(svc.accounts[t2].service, harness.statusPayload({}))
        }
        harness.check(reached === svc.accounts.length - 1,
          "...so every OTHER account still polls normally")
      }

      else if (s === 12) {
        console.log("notification broker")
        // Step 11 deliberately blanked this account's confdir to test the freeze
        // guard, so it stopped polling. Restore it through DISCOVERY, not by
        // assigning the property: a direct assignment destroys the binding to
        // the model role, and every later descriptor update would then be unable
        // to reach it.
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" },
          { service: "onedrive@c.service", instance: "c", confdir: "/c/c", description: "C" }
        ])
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
        // "at most one" is satisfied by ZERO, and the window here is 10s while
        // these steps are 60ms apart -- so asserting it now would pass whether
        // the broker emitted one, none, or never flushed at all. Force the flush
        // and assert on the real outcome instead.
        svc.flushTransitions()
      }

      else if (s === 14) {
        var fired = Quickshell.detached.length + Quickshell.runningWith("notify-send").length
        harness.check(fired === 1,
          "three accounts failing in one round produce EXACTLY one notification")
        var sent = Quickshell.detached.length
          ? Quickshell.detached[0]
          : (Quickshell.runningWith("notify-send").length
              ? Quickshell.runningWith("notify-send")[0].command : [])
        console.log("      notification argv: " + JSON.stringify(sent))
        var joined = sent.join(" ")
        harness.check(joined.indexOf("A") !== -1 && joined.indexOf("B") !== -1
          && joined.indexOf("C") !== -1,
          "...and it names every affected account rather than only one")
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
        // Finish the stop so the SCHEDULE is created. Snapshotting before this
        // meant the systemd-run vector -- the one that decides which account
        // actually resumes -- was never examined at all.
        for (var w = 0; w < stops.length; w++) stops[w].finish(0, "")
      }

      else if (s === 17) {
        var schedules = Quickshell.runningWith("systemd-run")
        harness.check(schedules.length === 1, "a timed pause schedules exactly one resume")
        var argv = schedules.length ? schedules[0].command : []
        var joined = argv.join(" ")
        harness.check(joined.indexOf("--unit=omaonedrive-resume@b") !== -1,
          "the resume timer is that account's own unit")
        harness.check(argv[argv.length - 1] === "onedrive@b.service",
          "the timer starts the SAME service the pause stopped")
        harness.check(joined.indexOf("onedrive.service ") === -1
          && argv[argv.length - 1] !== "onedrive.service",
          "...and not the default account's")
        for (var y = 0; y < schedules.length; y++) schedules[y].finish(0, "")
        var rest = Quickshell.running()
        for (var z = 0; z < rest.length; z++) rest[z].finish(0, harness.statusPayload({}))
      }

      else if (s === 18) {
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

      else if (s === 19) {
        console.log("a reply from the previous confdir must not be applied")
        // The condition grok pointed out the earlier repoint test lacked: a poll
        // already IN FLIGHT when the account is repointed. forgetSample keeps
        // in-flight processes by design, so without a generation stamp that
        // reply writes the OLD directory's syncDir, initialized and edge latches
        // back over the new account.
        var acct2 = svc.accounts[0]
        acct2.refresh(false)
        harness.check(acct2.refreshing === true, "a poll is in flight before the repoint")
        svc.applyDiscovery([
          { service: acct2.service, instance: "a", confdir: "/MOVED/a", description: "A" }
        ])
        harness.check(acct2.confdir === "/MOVED/a", "the repoint lands")
        harness.check(acct2.initialized === false, "the sample is forgotten")
        // Now let the OLD process finish with the previous directory's data.
        harness.finishStatus(acct2.service, harness.statusPayload({ syncDir: "/OLD/dir" }))
        harness.check(acct2.syncDir !== "/OLD/dir",
          "a reply started under the old confdir is discarded, not applied")
        harness.check(acct2.initialized === false,
          "...and does not resurrect `initialized` for the previous directory")
        harness.check(acct2.attempted === false,
          "...and does not mark the NEW identity attempted, which would skip its ramp")
      }

      else if (s === 20) {
        console.log("every routine refresh goes through the shared slot")
        // Step 18 reduced the payload to one account; this needs two, so the
        // selected account can differ from the one being polled.
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" }
        ])
        // IPC refresh(), the panel's open() and the settle/delayed timers all
        // reach Account.refresh, whose only guard is that account's OWN process.
        // Without the coordinator's gate, automation calling refresh while the
        // scheduler is mid-poll starts a second concurrent helper -- the thing
        // the whole slot discipline exists to forbid.
        var live0 = harness.runningStatusServices()
        for (var q0 = 0; q0 < Quickshell.running().length; q0++) {
          Quickshell.running()[q0].finish(0, harness.statusPayload({}))
        }
        svc.pollNextAccount()
        var inFlight = harness.runningStatusServices()
        harness.check(inFlight.length === 1, "the scheduler has exactly one poll in flight")
        // The selected account must be a DIFFERENT one, or Account.refresh
        // refuses it on its own process and the test passes either way.
        var other = ""
        for (var o = 0; o < svc.accounts.length; o++) {
          if (svc.accounts[o].service !== inFlight[0]) { other = svc.accounts[o].service; break }
        }
        svc.selectedService = other
        harness.check(svc.selectedAccount.service !== inFlight[0],
          "the selected account is not the one being polled")
        harness.check(svc.selectedAccount.refreshing === false,
          "...and is idle, so only the shared slot can stop it")
        svc.refresh(false)
        harness.check(harness.runningStatusServices().length === inFlight.length,
          "a facade refresh starts nothing while another account's poll is in flight")
        // A cloud check is explicit intent and has its own semaphore, so it is
        // still allowed through.
        for (var q1 = 0; q1 < Quickshell.running().length; q1++) {
          Quickshell.running()[q1].finish(0, harness.statusPayload({}))
        }
      }

      else if (s === 21) {
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

      else if (s >= 22 && s <= 43) {
        // One event per tick, faster than the 900ms window.
        svc.enqueueTransition({
          service: "onedrive@a.service", name: "A", kind: "reauth",
          summary: "OneDrive needs reauthentication", short: "Reauthentication required",
          body: "b", action: "open", actionLabel: "Open OneDrive panel"
        })
        harness.streamTicks += 1
      }

      else if (s === 44) {
        var fired = Quickshell.detached.length + Quickshell.runningWith("notify-send").length
        harness.check(fired >= 1,
          "a stream of events flushes rather than being deferred forever (" +
          harness.streamTicks + " events over ~" + (harness.streamTicks * 60) + "ms)")
      }


      // ---------------------------------------------------------------------
      // Every panel and IPC control acts on the SELECTED account. Neutering any
      // one of Service's sixteen facade functions -- pause, resume, login,
      // reauthenticate, repairResync, openFolder, checkQuota, checkFullStatus --
      // left this harness green, which is the same blind spot the delegate
      // property-shadowing bug hid in: the command was built correctly and sent
      // to the wrong account.
      else if (s === 45) {
        console.log("panel controls act on the selected account, and only on it")
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" }
        ])
        harness.drain(harness.statusPayload({}))
      }

      // Give the two accounts DISTINCT observable state, so a command carrying
      // the wrong account's identity cannot look like the right one.
      else if (s === 46 || s === 47) {
        svc.pollNextAccount()
        harness.finishStatus("onedrive@a.service", harness.statusPayload({
          syncDir: "/d/a", running: true, activeState: "active" }))
        // B is stopped: reauthenticate() and repairResync() both refuse a running
        // account, so the fixture has to make those paths reachable at all.
        harness.finishStatus("onedrive@b.service", harness.statusPayload({
          syncDir: "/d/b", running: false, activeState: "inactive" }))
      }

      else if (s === 48) {
        svc.selectAccount("onedrive@b.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: false, activeState: "inactive" }))
        harness.check(svc.selectedAccount.service === "onedrive@b.service",
          "B is selected")
        harness.check(svc.accounts[0].service === "onedrive@a.service",
          "...and is NOT the first account, so 'always account 0' cannot pass")

        Quickshell.detached = []
        svc.login()
        harness.check(harness.detachedWith("--confdir /c/b").length === 1,
          "login opens the selected account's config directory")
        harness.check(harness.detachedWith("/c/a").length === 0,
          "...and never the other account's")

        Quickshell.detached = []
        svc.reauthenticate()
        harness.check(harness.detachedWith("--confdir /c/b --reauth").length === 1,
          "reauthentication targets the selected account")
        harness.check(harness.detachedWith("/c/a").length === 0,
          "...and never the other account's")

        Quickshell.detached = []
        svc.repairResync()
        harness.check(harness.detachedWith("--confdir /c/b --sync --resync").length === 1,
          "resync repair targets the selected account")
        harness.check(harness.detachedWith("/c/a").length === 0,
          "...and never the other account's -- a resync on the wrong account " +
          "deletes and re-downloads the wrong drive")

        Quickshell.detached = []
        svc.openFolder()
        harness.check(harness.detachedWith("xdg-open /d/b").length === 1,
          "Open folder opens the selected account's sync directory")
        harness.check(harness.detachedWith("/d/a").length === 0,
          "...and never the other account's")
      }

      // The discriminating half: flip the selection and prove the commands
      // FOLLOW it. Without this, hard-coding account B passes every check above.
      else if (s === 49) {
        svc.selectAccount("onedrive@a.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/a", running: true, activeState: "active" }))
        harness.check(svc.selectedAccount.service === "onedrive@a.service",
          "the selection moved to A")

        Quickshell.detached = []
        svc.login()
        harness.check(harness.detachedWith("--confdir /c/a").length === 1,
          "login follows the selection to the other account")
        harness.check(harness.detachedWith("/c/b").length === 0,
          "...and leaves the previously selected account alone")

        Quickshell.detached = []
        svc.openFolder()
        harness.check(harness.detachedWith("xdg-open /d/a").length === 1,
          "Open folder follows the selection too")
        harness.check(harness.detachedWith("/d/b").length === 0,
          "...and not the previously selected account's directory")
      }

      else if (s === 50) {
        console.log("cloud checks name the selected account in the command itself")
        harness.drain(harness.statusPayload({}))
        svc.selectAccount("onedrive@b.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: false, activeState: "inactive" }))
        svc.checkQuota()
        var quota = harness.liveWith("--quota")
        harness.check(quota.length === 1, "exactly one quota check is in flight")
        harness.check(quota.length === 1
          && quota[0].indexOf("--service onedrive@b.service") !== -1
          && quota[0].indexOf("--confdir /c/b") !== -1,
          "the quota check carries the selected account's service AND confdir")
        harness.check(quota.length === 1 && quota[0].indexOf("/c/a") === -1,
          "...and nothing belonging to the other account")
      }

      else if (s === 51) {
        harness.drain(harness.statusPayload({}))
        svc.selectAccount("onedrive@a.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/a", running: true, activeState: "active" }))
        svc.checkFullStatus()
        var full = harness.liveWith("--sync-status")
        harness.check(full.length === 1, "exactly one sync-status check is in flight")
        harness.check(full.length === 1
          && full[0].indexOf("--service onedrive@a.service") !== -1
          && full[0].indexOf("--confdir /c/a") !== -1,
          "the full check follows the selection to the other account")
        harness.check(full.length === 1 && full[0].indexOf("/c/b") === -1,
          "...and carries nothing belonging to the previously selected account")
        harness.drain(harness.statusPayload({}))
      }

      // Pause and resume are the two that reach systemd. Each chains a resume-
      // timer cancel before the control call, and BOTH halves must name the same
      // account -- cancelling the wrong timer strands the other account's pause.
      else if (s === 52) {
        console.log("pause and resume reach the selected account's own units")
        svc.selectAccount("onedrive@b.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: false, activeState: "inactive" }))
        svc.resume()
        harness.check(harness.liveWith("omaonedrive-resume@b").length === 1,
          "resume first cancels the selected account's OWN resume timer")
        harness.check(harness.liveWith("omaonedrive-resume@a").length === 0,
          "...and not the other account's, which would strand its pause")
        harness.drain("")
      }

      else if (s === 53) {
        var starts = harness.liveWith("systemctl --user start")
        harness.check(starts.length === 1
          && starts[0].indexOf("onedrive@b.service") !== -1,
          "...and then starts the selected account's unit")
        harness.check(harness.liveWith("start onedrive@a.service").length === 0,
          "...leaving the other account's unit untouched")
        harness.drain("")
      }

      else if (s === 54) {
        svc.selectAccount("onedrive@a.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/a", running: true, activeState: "active" }))
        svc.pause()
        harness.check(harness.liveWith("omaonedrive-resume@a").length === 1,
          "pause cancels the selected account's own resume timer")
        harness.check(harness.liveWith("omaonedrive-resume@b").length === 0,
          "...and not the other account's")
        harness.drain("")
      }

      else if (s === 55) {
        var stops = harness.liveWith("systemctl --user stop onedrive@a.service")
        harness.check(stops.length === 1,
          "...and then stops the selected account's unit")
        harness.check(harness.liveWith("stop onedrive@b.service").length === 0,
          "...leaving the other account running")
        harness.drain("")
      }


      // ---------------------------------------------------------------------
      // The remaining facade functions. Each of these could be replaced with an
      // empty body and this harness stayed green: the refresh test below only
      // asserted the NEGATIVE case (that a refresh during a poll starts nothing),
      // which an empty body satisfies perfectly; and the timed pause was driven
      // on the Account directly, never through the coordinator the panel calls.
      else if (s === 56) {
        console.log("the facade actually does the thing, not just refuse to")
        harness.drain(harness.statusPayload({}))
        svc.selectAccount("onedrive@b.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: false, activeState: "inactive" }))
        harness.check(harness.runningStatusServices().length === 0,
          "nothing is polling, so a refresh has no excuse to do nothing")
        svc.refresh(false)
        harness.check(harness.runningStatusServices().length === 1,
          "an idle facade refresh DOES start a poll")
        harness.check(harness.runningStatusServices()[0] === "onedrive@b.service",
          "...for the selected account")
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: false, activeState: "inactive" }))
      }

      // The panel's "Pause for N" menu calls the COORDINATOR, not the account.
      else if (s === 57) {
        svc.selectAccount("onedrive@b.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: true, activeState: "active" }))
        svc.pauseFor(60)
        harness.check(harness.liveWith("omaonedrive-resume@b").length === 1,
          "a timed pause cancels the selected account's existing timer first")
        harness.drain("")
      }

      else if (s === 58) {
        harness.check(harness.liveWith("systemctl --user stop onedrive@b.service").length === 1,
          "...then stops the selected account's unit")
        harness.drain("")
      }

      else if (s === 59) {
        var scheduled = harness.liveWith("systemd-run")
        harness.check(scheduled.length === 1, "...and schedules exactly one resume timer")
        harness.check(scheduled.length === 1
          && scheduled[0].indexOf("--unit=omaonedrive-resume@b") !== -1,
          "the timer is the selected account's own unit")
        harness.check(scheduled.length === 1
          && scheduled[0].indexOf("--on-active=60m") !== -1,
          "...for the duration the menu asked for, not a default")
        harness.check(scheduled.length === 1
          && scheduled[0].indexOf("start onedrive@b.service") !== -1,
          "...and on expiry it starts the account it paused, not another")
        harness.check(scheduled.length === 1 && scheduled[0].indexOf("@a") === -1,
          "nothing in the schedule names the other account")
        harness.drain("")
      }

      // The bar's own click. It has to read the CURRENT state to pick a
      // direction: a toggle that always pauses is indistinguishable from a
      // correct one until you click it twice.
      else if (s === 60) {
        console.log("the bar toggle picks its direction from the account's state")
        harness.drain(harness.statusPayload({}))
        svc.selectAccount("onedrive@a.service", false)
        // Step 54 paused A, so its optimistic desired state is still "stopped"
        // and will stay so until a poll agrees. Let one poll agree, then bring it
        // back up -- otherwise `active` is false and this would be testing the
        // resume direction twice.
        harness.drain(harness.statusPayload({
          syncDir: "/d/a", running: false, activeState: "inactive" }))
        svc.refresh(false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/a", running: true, activeState: "active" }))
        harness.check(svc.selectedAccount.active === true,
          "A is running, so the toggle must choose to STOP it")
        svc.toggleRunning()
        harness.drain("")
      }

      else if (s === 61) {
        harness.check(harness.liveWith("systemctl --user stop onedrive@a.service").length === 1,
          "toggling a running account stops it")
        harness.drain("")
      }

      else if (s === 62) {
        svc.selectAccount("onedrive@b.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: false, activeState: "inactive" }))
        harness.check(svc.selectedAccount.active === false, "B is stopped")
        svc.toggleRunning()
        harness.drain("")
      }

      else if (s === 63) {
        harness.check(harness.liveWith("systemctl --user start onedrive@b.service").length === 1,
          "toggling a stopped account starts it -- the same call, the other way")
        harness.drain("")
      }

      else if (s === 64) {
        console.log("openWeb and openFile")
        Quickshell.detached = []
        svc.openWeb()
        harness.check(harness.detachedWith("xdg-open https://onedrive.live.com/").length === 1,
          "Open on the web launches the OneDrive site")
        Quickshell.detached = []
        svc.openFile({ path: "/d/b/Some Folder/a file.txt" })
        harness.check(harness.detachedWith("nautilus --select").length === 1,
          "Open file reveals the file in the file manager")
        harness.check(
          harness.detachedWith("file:///d/b/Some%20Folder/a%20file.txt").length === 1,
          "...with the path percent-encoded, so a space does not truncate it")
        harness.check(harness.detachedWith("file:///d/b/Some Folder").length === 0,
          "...and never as a raw path")
        Quickshell.detached = []
        svc.openFile(null)
        harness.check(Quickshell.detached.length === 0,
          "a missing file launches nothing")
      }

      // The cloud semaphore's release half. A queued check must actually run
      // when the one in flight finishes -- otherwise the second account's storage
      // figure never arrives and the panel shows "Not checked" forever.
      else if (s === 65) {
        console.log("a queued cloud check runs when the slot frees")
        harness.drain(harness.statusPayload({}))
        svc.accounts[0].checkQuota()
        svc.accounts[1].checkQuota()
        var live = harness.liveWith("--quota")
        harness.check(live.length === 1, "only one cloud check runs at a time")
        harness.check(live[0].indexOf("--confdir /c/a") !== -1,
          "the first request is the one in flight")
        harness.drain(harness.statusPayload({}))
      }

      else if (s === 66) {
        var second = harness.liveWith("--quota")
        harness.check(second.length === 1,
          "the queued check starts once the slot frees, rather than being dropped")
        harness.check(second.length === 1 && second[0].indexOf("--confdir /c/b") !== -1,
          "...and it is the account that was waiting, with its own confdir")
        harness.drain(harness.statusPayload({}))
      }

      else if (s === 67) {
        harness.check(harness.liveWith("--quota").length === 0,
          "the queue is then empty -- a drained entry is not re-run forever")
      }


      // ---------------------------------------------------------------------
      // Real Quickshell takes `running` true -> false WITHOUT emitting `exited`
      // when the executable cannot be started. Every cleanup lived in onExited,
      // and the coordinator's single poll slot hangs off `refreshing` -- so one
      // missing python3 froze routine polling for every account, permanently.
      // The stub could not express this until now, which is why the suite was
      // green through it.
      else if (s === 68) {
        console.log("a command that cannot be started must not freeze the fleet")
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" }
        ])
        harness.drain(harness.statusPayload({}))
        svc.pollNextAccount()
        var flight = harness.runningStatusServices()
        harness.check(flight.length === 1, "a poll is in flight")
        harness.stuck = flight[0]
        harness.check(harness.statusProcessFor(harness.stuck).failToStart(),
          "...and its executable fails to start, with no exit ever reported")
      }

      else if (s === 69) {
        var abandoned = svc.accounts[0].service === harness.stuck
          ? svc.accounts[0] : svc.accounts[1]
        harness.check(abandoned.refreshing === false,
          "the account releases the poll slot rather than latching on it")
        harness.check(abandoned.attempted === true,
          "...and counts as attempted, so it does not monopolise the ramp")
        harness.check(abandoned.lastError !== "",
          "...and says what went wrong instead of sitting blank")
        harness.check(svc.routinePollRunning() === false,
          "the coordinator sees the slot as free")
        svc.pollNextAccount()
        harness.check(harness.runningStatusServices().length === 1,
          "...so the fleet goes on polling")
        harness.drain(harness.statusPayload({}))
      }

      // A helper that starts but never exits -- a wedged python3, an os.walk over
      // a stalled mount -- held the same slot forever. Nothing bounded it.
      else if (s === 70) {
        console.log("a helper that never exits is abandoned rather than blocking everyone")
        svc.settings = ({ refreshIntervalSec: 10, recentFileLimit: 5,
                          notifications: true, statusTimeoutMs: 200 })
        harness.drain(harness.statusPayload({}))
        svc.pollNextAccount()
        var wedgedFlight = harness.runningStatusServices()
        harness.check(wedgedFlight.length === 1,
          "a poll is in flight and will never return")
        harness.stuck = wedgedFlight.length === 1 ? wedgedFlight[0] : ""
      }

      // ~240ms of nothing, against a 200ms timeout.
      else if (s >= 71 && s <= 74) { /* let the watchdog run */ }

      else if (s === 75) {
        var wedged = svc.accountForService(harness.stuck)
        harness.check(harness.statusProcessFor(harness.stuck) === null,
          "the watchdog gives up on the process")
        harness.check(wedged.refreshing === false,
          "...releasing the slot it was holding")
        harness.check(wedged.lastError.indexOf("timed out") !== -1,
          "...and the account reports a timeout rather than sitting blank: " + wedged.lastError)
        harness.check(wedged.attempted === true,
          "...and counts as attempted, so it does not monopolise the ramp")
        harness.drain(harness.statusPayload({}))
        svc.pollNextAccount()
        harness.check(harness.runningStatusServices().length === 1,
          "the fleet polls on")
        harness.drain(harness.statusPayload({}))
      }

      // ---------------------------------------------------------------------
      // The pause that unpaused itself. After `systemctl stop` succeeded the
      // settle loop asked five times for a confirming poll and then cleared the
      // optimistic state regardless. Those asks are dropped while another
      // account holds the slot, so with 2-3 accounts the bar reverted to
      // "Monitoring" about six seconds after the click -- while the unit really
      // was stopped.
      else if (s === 76) {
        console.log("a pause is not undone by a poll slot it never got")
        svc.settings = ({ refreshIntervalSec: 10, recentFileLimit: 5,
                          notifications: true, settleIntervalMs: 20,
                          statusTimeoutMs: 600000 })
        harness.drain(harness.statusPayload({}))
        svc.selectAccount("onedrive@b.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: true, activeState: "active" }))
        harness.check(svc.selectedAccount.active === true, "B is running")
        svc.pause()
        harness.drain("")
      }

      else if (s === 77) {
        harness.check(harness.liveWith("systemctl --user stop onedrive@b.service").length === 1,
          "the stop is issued")
        harness.drain("")
        // Now block the shared slot with the OTHER account, so every settle ask
        // is dropped -- the multi-account condition the revert needed.
        svc.accounts[0].refresh(false)
        harness.check(harness.runningStatusServices().length === 1,
          "the other account is holding the poll slot")
        harness.check(svc.accounts[1].settling === true,
          "B is waiting to learn what the stop did")
      }

      // 30 settle ticks at 20ms is 600ms; these ten ticks are ~600ms.
      else if (s >= 78 && s <= 87) {
        harness.check(svc.accounts[1].active === false,
          "B stays paused on screen while no poll can confirm it (tick " + (s - 77) + ")")
      }

      else if (s === 88) {
        harness.check(svc.accounts[1].active === false,
          "...and after the settle loop has given up asking, it is STILL paused")
        harness.check(svc.accounts[1].running === true,
          "...even though the last sample, taken before the stop, says running")
        // Release the slot; the confirming poll may now land and truth wins.
        harness.drain(harness.statusPayload({}))
        svc.accounts[1].refresh(false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: false, activeState: "inactive" }))
        harness.check(svc.accounts[1].active === false,
          "a poll agreeing with the pause leaves it paused")
      }

      else if (s === 89) {
        // ...and the other direction: a poll that DISAGREES is believed, so a
        // unit something else restarted is not shown as paused forever.
        svc.accounts[1].refresh(false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: true, activeState: "active" }))
        harness.check(svc.accounts[1].active === true,
          "a later poll showing it running is believed, not overridden forever")
        svc.settings = ({ refreshIntervalSec: 10, recentFileLimit: 5, notifications: true })
      }


      // ---------------------------------------------------------------------
      // The startup seed polls `onedrive.service` before discovery has told us
      // its config directory, so that poll uses the CLIENT's default. If the
      // unit's ExecStart names a different --confdir, the reply describes a
      // different account. The repoint guard only fired on non-empty -> non-empty,
      // so this reply was applied: the wrong sync directory, quota and token
      // state under this account's name, and Open folder on the wrong tree.
      else if (s === 90) {
        console.log("a seed poll started before discovery knew the confdir")
        svc.applyDiscovery([
          { service: "onedrive.service", instance: "", confdir: "", description: "" }
        ])
        harness.drain(harness.statusPayload({}))
        svc.accounts[0].forgetSample()
        svc.accounts[0].refresh(false)
        harness.check(harness.statusProcessFor("onedrive.service") !== null,
          "a poll is in flight against the client's default directory")
        harness.check(svc.accounts[0].confdir === "",
          "...started while the confdir was still unknown")
      }

      else if (s === 91) {
        svc.applyDiscovery([
          { service: "onedrive.service", instance: "",
            confdir: "/CUSTOM/onedrive", description: "" }
        ])
        harness.check(svc.accounts[0].confdir === "/CUSTOM/onedrive",
          "discovery supplies the unit's real config directory")
        harness.finishStatus("onedrive.service", harness.statusPayload({
          syncDir: "/DEFAULT/tree", statusText: "Monitoring the default account" }))
        harness.check(svc.accounts[0].syncDir !== "/DEFAULT/tree",
          "the seed reply is refused, not attached to the discovered directory")
        harness.check(svc.accounts[0].initialized === false,
          "...and does not count as this account having reported")
        harness.check(svc.accounts[0].statusText.indexOf("default account") === -1,
          "...so the panel shows nothing rather than another account's status")
      }

      else if (s === 92) {
        // ...and the ordinary case is untouched: a poll started AFTER discovery
        // still applies. Without this the fix would simply never show anything.
        svc.accounts[0].refresh(false)
        harness.finishStatus("onedrive.service", harness.statusPayload({
          syncDir: "/CUSTOM/tree" }))
        harness.check(svc.accounts[0].syncDir === "/CUSTOM/tree",
          "a poll started after discovery is applied normally")
        harness.check(svc.accounts[0].initialized === true, "...and does report")
      }

      // ---------------------------------------------------------------------
      // The cloud queue took one entry per release. An account removed by
      // discovery while queued therefore consumed the release and left every
      // entry behind it stranded.
      else if (s === 93) {
        console.log("a cloud check queued behind a removed account still runs")
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" },
          { service: "onedrive@c.service", instance: "c", confdir: "/c/c", description: "C" }
        ])
        harness.drain(harness.statusPayload({}))
      }

      else if (s === 94) {
        harness.drain(harness.statusPayload({}))
        svc.accounts[0].checkQuota()
        svc.accounts[1].checkQuota()
        svc.accounts[2].checkQuota()
        var inflight = harness.liveWith("--quota")
        harness.check(inflight.length === 1, "one cloud check runs, two are queued")
        harness.check(inflight[0].indexOf("/c/a") !== -1, "A's is the one in flight")
      }

      else if (s === 95) {
        // B disappears -- its unit was removed, or its confdir became unreadable
        // and the helper stopped reporting it.
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" },
          { service: "onedrive@c.service", instance: "c", confdir: "/c/c", description: "C" }
        ])
        harness.check(svc.accountCount === 2, "B is gone")
        harness.drain(harness.statusPayload({}))
      }

      else if (s === 96) {
        var next = harness.liveWith("--quota")
        harness.check(next.length === 1,
          "the queue skips the removed account and runs the one behind it")
        harness.check(next.length === 1 && next[0].indexOf("/c/c") !== -1,
          "...which is C, with C's own config directory")
        harness.drain(harness.statusPayload({}))
      }

      // ---------------------------------------------------------------------
      // The badge is worst-of-N; every control acts on the SELECTED account.
      // Those were unrelated, so the bar could show "reauthentication required"
      // for one account while the panel opened on a healthy other one -- and the
      // keyboard shortcuts then acted on the healthy one.
      else if (s === 97) {
        console.log("opening the panel lands on the account the badge blames")
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" }
        ])
        harness.drain(harness.statusPayload({}))
      }

      else if (s === 98 || s === 99) {
        svc.pollNextAccount()
        harness.finishStatus("onedrive@a.service", harness.statusPayload({
          syncDir: "/d/a", running: true, activeState: "active" }))
        harness.finishStatus("onedrive@b.service", harness.statusPayload({
          syncDir: "/d/b", reauthRequired: true, statusText: "Reauthentication required" }))
      }

      else if (s === 100) {
        svc.selectAccount("onedrive@a.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/a", running: true, activeState: "active" }))
        harness.check(svc.aggregate.kind === "reauth", "the bar is blaming an account")
        harness.check(svc.aggregate.worst.service === "onedrive@b.service",
          "...and it is B")
        harness.check(svc.selectedService === "onedrive@a.service",
          "...while the panel is still pointed at the healthy A")
        svc.selectBadgedAccount()
        harness.check(svc.selectedService === "onedrive@b.service",
          "opening the panel moves the selection to the account being blamed")
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", reauthRequired: true }))
      }

      else if (s === 101) {
        // The other half: a selection the user made deliberately is not stolen
        // when a second account also goes wrong. Make A fail too; B stays
        // selected because B is itself asking for attention.
        svc.accounts[0].refresh(false)
        harness.finishStatus("onedrive@a.service", harness.statusPayload({
          syncDir: "/d/a", serviceFailed: true, statusText: "Sync failed" }))
        harness.check(svc.selectedService === "onedrive@b.service", "B is selected")
        svc.selectBadgedAccount()
        harness.check(svc.selectedService === "onedrive@b.service",
          "a selection the user made for a reason is not stolen by a worse account")
        harness.drain(harness.statusPayload({}))
      }


      // ---------------------------------------------------------------------
      // Three fixes from an earlier round that could each be reverted wholesale
      // with the entire suite green. A reviewer applied all three and reported
      // "suite passed" for every one.
      else if (s === 102) {
        console.log("a stale cloud reply must release the shared slot")
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" }
        ])
        harness.drain(harness.statusPayload({}))
      }

      else if (s === 103) {
        harness.drain(harness.statusPayload({}))
        svc.accounts[0].checkQuota()
        svc.accounts[1].checkQuota()
        harness.check(harness.liveWith("--quota").length === 1,
          "A's cloud check is in flight and B's is queued behind it")
        // A is repointed at a different config directory while its check runs.
        // The reply that comes back describes the OLD directory and is discarded
        // -- but everything the normal path releases has to be released anyway,
        // or the coordinator goes on believing a cloud check is running and B's
        // never starts.
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a2", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" }
        ])
        harness.check(svc.accounts[0].confdir === "/c/a2", "A is repointed mid-check")
        harness.finishStatus("onedrive@a.service", harness.statusPayload({ usedBytes: 1 }))
      }

      else if (s === 104) {
        var released = harness.liveWith("--quota")
        harness.check(released.length === 1,
          "the discarded reply still frees the slot, so the queued check runs")
        harness.check(released.length === 1 && released[0].indexOf("/c/b") !== -1,
          "...and it is B's, with B's own config directory")
        harness.drain(harness.statusPayload({}))
      }

      // A repeat click while the same check is already running used to queue a
      // duplicate, which then ran the same 30-second query again the moment the
      // first finished.
      else if (s === 105) {
        console.log("a click repeated during the check it started is dropped")
        harness.drain(harness.statusPayload({}))
        svc.accounts[0].checkQuota()
        harness.check(harness.liveWith("--quota").length === 1, "one quota check is running")
        svc.accounts[0].checkQuota()
        svc.accounts[0].checkQuota()
        harness.check(harness.liveWith("--quota").length === 1,
          "...and the repeats start nothing more")
        harness.finishStatus("onedrive@a.service", harness.statusPayload({ usedBytes: 1 }))
      }

      else if (s === 106) {
        harness.check(harness.liveWith("--quota").length === 0,
          "...nor queue a duplicate that runs the moment the first one finishes")
        // A different mode for the same account is a real request, so the
        // de-duplication cannot simply be "ignore everything while busy".
        harness.drain(harness.statusPayload({}))
        svc.accounts[0].checkQuota()
        svc.accounts[0].checkFullStatus()
        harness.check(harness.liveWith("--quota").length === 1,
          "the quota check is running")
        harness.finishStatus("onedrive@a.service", harness.statusPayload({}))
      }

      else if (s === 107) {
        harness.check(harness.liveWith("--sync-status").length === 1,
          "...and the sync-status check queued behind it still runs")
        harness.drain(harness.statusPayload({}))
      }

      // Selecting an account from IPC must not inherit the panel's behaviour of
      // retrying a stale failed storage check: automation targeting an account
      // in order to pause it would silently contact Microsoft.
      else if (s === 108) {
        console.log("selecting an account from automation does not contact the cloud")
        harness.drain(harness.statusPayload({}))
        harness.stale = harness.statusPayload({
          syncDir: "/d/b", quotaError: "temporary failure", quotaCheckedTs: 1 })
        svc.selectAccount("onedrive@b.service", false)
        harness.drain(harness.stale)
      }

      else if (s === 109) {
        harness.check(svc.accounts[1].quotaError !== "",
          "B has a failed storage check old enough to be retried")
        harness.check(harness.liveWith("--quota").length === 0,
          "an automation selection starts no cloud check")
        // The discriminating half: the PANEL's selection does retry it, so this
        // cannot pass by the retry being broken outright.
        harness.drain(harness.statusPayload({}))
        svc.selectAccount("onedrive@a.service", false)
        harness.drain(harness.statusPayload({}))
        svc.selectAccount("onedrive@b.service", true)
        harness.drain(harness.stale)
      }

      else if (s === 110) {
        harness.check(harness.liveWith("--quota").length === 1,
          "...while opening the panel on it does retry the stale check")
        harness.check(harness.liveWith("/c/b").length === 1,
          "...for B, the account that was selected")
        harness.drain(harness.statusPayload({}))
      }


      // ---------------------------------------------------------------------
      // The compatibility guarantee. With no template instances -- and whenever
      // discovery fails outright -- the widget must still show exactly the one
      // account it showed before this branch existed.
      else if (s === 111) {
        console.log("a machine with no discovered accounts still has one")
        harness.drain(harness.statusPayload({}))
        svc.applyDiscovery([])
        harness.check(svc.accountCount === 1,
          "an empty discovery leaves exactly one account, not zero")
        harness.check(svc.accounts[0].service === "onedrive.service",
          "...the plain service, under its legacy unit name")
        harness.check(svc.accounts[0].instance === "",
          "...with no instance, so it keeps the legacy resume timer")
        harness.check(svc.accounts[0].confdir === "",
          "...and no config directory, so the client's own default is used")
        harness.check(svc.selectedService === "onedrive.service",
          "...and it is selected, so every control has a target")
        svc.accounts[0].refresh(false)
        var plain = harness.liveWith("onedrive-status.py")
        harness.check(plain.length === 1
          && plain[0].indexOf("--service") === -1
          && plain[0].indexOf("--confdir") === -1,
          "...so it sends exactly the command a single-account machine sent before: " +
          (plain.length === 1 ? plain[0] : "none"))
        harness.drain(harness.statusPayload({}))
      }

      // The panel's own stale-quota retry, which is a different entry point from
      // the selection one: Panel.open() calls the coordinator facade directly.
      else if (s === 112) {
        console.log("opening the panel retries a stale failed storage check")
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" }
        ])
        harness.drain(harness.statusPayload({}))
      }

      else if (s === 113) {
        harness.drain(harness.statusPayload({}))
        svc.selectAccount("onedrive@b.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", quotaError: "temporary failure", quotaCheckedTs: 1 }))
        harness.check(harness.liveWith("--quota").length === 0,
          "nothing is checking storage yet")
        svc.retryStaleQuotaOnOpen()
        svc.refreshSelected()
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", quotaError: "temporary failure", quotaCheckedTs: 1 }))
      }

      else if (s === 114) {
        var retried = harness.liveWith("--quota")
        harness.check(retried.length === 1,
          "the panel's open retries the failed check once")
        harness.check(retried.length === 1 && retried[0].indexOf("/c/b") !== -1,
          "...for the selected account")
        harness.drain(harness.statusPayload({}))
      }

      // requestRefresh is the shared-slot gate for every refresh the Account
      // starts on its own behalf. The existing test only asserted the NEGATIVE
      // half -- that it starts nothing while another account polls -- which an
      // empty body satisfies perfectly.
      else if (s === 115) {
        console.log("an internal refresh does reach the helper when the slot is free")
        harness.drain(harness.statusPayload({}))
        harness.check(svc.routinePollRunning() === false, "the slot is free")
        var beforeInternal = Quickshell.spawnCount
        svc.accounts[1].requestRefresh()
        harness.check(Quickshell.spawnCount === beforeInternal + 1,
          "a refresh routed through the coordinator starts exactly one poll")
        harness.check(harness.runningStatusServices().length === 1
          && harness.runningStatusServices()[0] === "onedrive@b.service",
          "...for the account that asked")
        harness.drain(harness.statusPayload({}))
      }

      // What happens when systemd-run refuses. The account is already stopped by
      // this point, so "do nothing" leaves it paused with nothing to resume it.
      else if (s === 116) {
        console.log("a resume timer that cannot be scheduled recovers the account")
        harness.drain(harness.statusPayload({}))
        svc.selectAccount("onedrive@b.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: true, activeState: "active" }))
        svc.pauseFor(60)
        harness.drain("")
      }

      else if (s === 117) {
        harness.check(harness.liveWith("systemctl --user stop onedrive@b.service").length === 1,
          "the account is stopped")
        harness.drain("")
      }

      else if (s === 118) {
        var run = harness.liveWith("systemd-run")
        harness.check(run.length === 1, "the resume timer is attempted")
        // ...and systemd refuses it.
        var live = Quickshell.running()
        for (var r = 0; r < live.length; r++) {
          if ((live[r].command || []).indexOf("systemd-run") !== -1) {
            live[r].finish(1, "")
          }
        }
      }

      else if (s === 119) {
        harness.check(harness.liveWith("systemctl --user start onedrive@b.service").length === 1,
          "a refused timer restarts the account rather than leaving it paused forever")
        harness.check(svc.accounts[1].actionStatus.indexOf("resum") !== -1,
          "...and says so: " + svc.accounts[1].actionStatus)
        harness.check(svc.accounts[1].lastError !== "",
          "...and reports why the timer could not be set")
        harness.drain("")
      }

      else if (s === 120) {
        // The success path is the other half: it must NOT restart the account.
        harness.drain(harness.statusPayload({}))
        svc.selectAccount("onedrive@a.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/a", running: true, activeState: "active" }))
        svc.pauseFor(30)
        harness.drain("")
      }

      else if (s === 121 || s === 122) { harness.drain("") }

      else if (s === 123) {
        harness.check(harness.liveWith("systemctl --user start onedrive@a.service").length === 0,
          "a timer that WAS scheduled does not restart the account it paused")
        harness.check(svc.accounts[0].actionStatus === "Timed pause scheduled",
          "...and reports the pause as scheduled: " + svc.accounts[0].actionStatus)
        harness.drain("")
      }


      // ---------------------------------------------------------------------
      // A deferred settle callback outlives the process that scheduled it. With
      // a shared boolean, finishing one poll and starting another in the same
      // turn let the FIRST poll's callback abandon the SECOND: refreshing
      // cleared, watchdog stopped, an error posted, and the live reply ignored.
      else if (s === 124) {
        console.log("a settled process must not settle its successor")
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" }
        ])
        harness.drain(harness.statusPayload({}))
      }

      else if (s === 125) {
        harness.drain(harness.statusPayload({}))
        svc.accounts[0].refresh(false)
        harness.check(harness.statusProcessFor("onedrive@a.service") !== null,
          "a poll is running")
        // Completing it schedules the deferred failure check for THIS run...
        harness.finishStatus("onedrive@a.service", harness.statusPayload({ syncDir: "/d/a" }))
        // ...and a second poll starts before that callback gets to run.
        svc.accounts[0].refresh(false)
        harness.check(harness.statusProcessFor("onedrive@a.service") !== null,
          "...and a second one starts in the same turn")
      }

      else if (s === 126) {
        harness.check(svc.accounts[0].refreshing === true,
          "the second poll is still running, not abandoned by the first's callback")
        harness.check(svc.accounts[0].lastError === "",
          "...and no failure was invented for it: " + svc.accounts[0].lastError)
        harness.finishStatus("onedrive@a.service", harness.statusPayload({ syncDir: "/d/a2" }))
        harness.check(svc.accounts[0].syncDir === "/d/a2",
          "...so its reply is applied rather than ignored")
      }

      // ---------------------------------------------------------------------
      // A poll STARTED before a control can complete after it. Counting
      // completed samples accepted such a poll as the confirmation, so a sample
      // taken before the stop -- still reporting the account as running -- undid
      // the pause. The confirmation has to have been started after the control.
      else if (s === 127) {
        console.log("a poll started before the control does not confirm it")
        harness.drain(harness.statusPayload({}))
        svc.selectAccount("onedrive@b.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: true, activeState: "active" }))
        harness.check(svc.selectedAccount.active === true, "B is running")
        svc.pause()
        harness.check(harness.liveWith("omaonedrive-resume@b").length === 1,
          "the resume-timer cancel is in flight")
        // The scheduler can hand B a slot here: a control is running, but B's
        // STATUS process is idle, which is all the poll gate looks at.
        svc.accounts[1].refresh(false)
        harness.check(harness.statusProcessFor("onedrive@b.service") !== null,
          "...and a poll starts while it is")
      }

      else if (s === 128) {
        // Let the cancel and then the stop complete, leaving the pre-stop poll
        // still in flight.
        var live = Quickshell.running()
        for (var i = 0; i < live.length; i++) {
          if ((live[i].command || []).join(" ").indexOf("onedrive-status.py") === -1) {
            live[i].finish(0, "")
          }
        }
      }

      else if (s === 129) {
        var live2 = Quickshell.running()
        for (var j = 0; j < live2.length; j++) {
          if ((live2[j].command || []).join(" ").indexOf("onedrive-status.py") === -1) {
            live2[j].finish(0, "")
          }
        }
        harness.check(harness.statusProcessFor("onedrive@b.service") !== null,
          "the pre-stop poll is still in flight when the stop completes")
      }

      else if (s === 130) {
        // ...and now it comes back, reporting what was true BEFORE the stop.
        harness.finishStatus("onedrive@b.service", harness.statusPayload({
          syncDir: "/d/b", running: true, activeState: "active" }))
        harness.check(svc.accounts[1].active === false,
          "a sample taken before the stop does not undo the pause")
        harness.check(svc.accounts[1].settling === true,
          "...and the account is still waiting for a real confirmation")
      }

      else if (s === 131) {
        // A poll started AFTER the stop is believed, in both directions.
        svc.accounts[1].refresh(false)
        harness.finishStatus("onedrive@b.service", harness.statusPayload({
          syncDir: "/d/b", running: false, activeState: "inactive" }))
        harness.check(svc.accounts[1].active === false, "a confirming poll leaves it paused")
        harness.check(svc.accounts[1].settling === false, "...and ends the wait")
      }

      // ---------------------------------------------------------------------
      // The other three failure-to-start paths. All three could be deleted
      // together with the whole suite green: only the status one was driven.
      else if (s === 132) {
        console.log("every control that cannot start is handled, not just the poll")
        harness.drain(harness.statusPayload({}))
        svc.selectAccount("onedrive@b.service", false)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: true, activeState: "active" }))
        svc.pause()
        var cancel = harness.liveWith("omaonedrive-resume@b")
        harness.check(cancel.length === 1, "the resume-timer cancel is in flight")
        // systemctl is not on PATH, or the fork fails.
        var procs = Quickshell.running()
        for (var c = 0; c < procs.length; c++) {
          if ((procs[c].command || []).join(" ").indexOf("omaonedrive-resume@b") !== -1) {
            procs[c].failToStart()
          }
        }
      }

      else if (s === 133) {
        harness.check(harness.liveWith("systemctl --user stop onedrive@b.service").length === 1,
          "a cancel that cannot start still lets the pause through")
        // ...and now the stop itself cannot start.
        var stops = Quickshell.running()
        for (var d = 0; d < stops.length; d++) {
          if ((stops[d].command || []).join(" ").indexOf("stop onedrive@b.service") !== -1) {
            stops[d].failToStart()
          }
        }
      }

      else if (s === 134) {
        harness.check(svc.accounts[1].active === true,
          "a control that cannot start does not leave the bar claiming a pause that never happened")
        harness.check(svc.accounts[1].lastError !== "",
          "...and says the command failed: " + svc.accounts[1].lastError)
        harness.drain(harness.statusPayload({
          syncDir: "/d/b", running: true, activeState: "active" }))
      }

      else if (s === 135) {
        svc.pauseFor(45)
        harness.drain("")
      }

      else if (s === 136) { harness.drain("") }

      else if (s === 137) {
        var run = harness.liveWith("systemd-run")
        harness.check(run.length === 1, "the resume timer is attempted")
        var timers = Quickshell.running()
        for (var t = 0; t < timers.length; t++) {
          if ((timers[t].command || []).indexOf("systemd-run") !== -1) timers[t].failToStart()
        }
      }

      else if (s === 138) {
        harness.check(harness.liveWith("systemctl --user start onedrive@b.service").length === 1,
          "a systemd-run that cannot START recovers the account, like one that fails")
        harness.drain("")
      }


      // ---------------------------------------------------------------------
      // The seed sample that had ALREADY been applied. Discarding the in-flight
      // reply was only half of it: at startup discovery and the first poll are
      // launched together, and the poll -- one helper call against the client's
      // default directory -- usually wins the race against a `list-units` plus a
      // `systemctl show` per unit. So the wrong sample is on screen by the time
      // the confdir arrives, and the old guard explicitly refused to clear it.
      else if (s === 139) {
        console.log("a seed sample already on screen when discovery lands")
        svc.applyDiscovery([
          { service: "onedrive.service", instance: "", confdir: "", description: "" }
        ])
        harness.drain(harness.statusPayload({}))
        svc.accounts[0].forgetSample()
        svc.accounts[0].refresh(false)
        // The helper stamps every reply with the directory it actually read.
        harness.finishStatus("onedrive.service", harness.statusPayload({
          confdir: "/home/u/.config/onedrive",
          syncDir: "/DEFAULT/tree", statusText: "Monitoring the default account" }))
        harness.check(svc.accounts[0].initialized === true,
          "the seed poll reports, and is shown -- there is nothing yet to say it is wrong")
        harness.check(svc.accounts[0].syncDir === "/DEFAULT/tree", "...with its sync directory")
      }

      else if (s === 140) {
        // Discovery now reads this unit's ExecStart and finds it overrides the
        // client default. Everything on screen belongs to another account.
        svc.applyDiscovery([
          { service: "onedrive.service", instance: "",
            confdir: "/CUSTOM/onedrive", description: "" }
        ])
        harness.check(svc.accounts[0].confdir === "/CUSTOM/onedrive", "the unit is repointed")
        harness.check(svc.accounts[0].syncDir !== "/DEFAULT/tree",
          "the default account's sync directory is dropped, not left for Open folder")
        harness.check(svc.accounts[0].initialized === false,
          "...and the account is back to having reported nothing")
        harness.check(svc.accounts[0].statusText.indexOf("default account") === -1,
          "...including its status line")
      }

      else if (s === 141) {
        // ...and the reply for the RIGHT directory is applied normally, so the
        // stamp cannot simply be refusing everything.
        svc.accounts[0].refresh(false)
        harness.finishStatus("onedrive.service", harness.statusPayload({
          confdir: "/CUSTOM/onedrive", syncDir: "/CUSTOM/tree" }))
        harness.check(svc.accounts[0].syncDir === "/CUSTOM/tree",
          "a reply stamped with the account's own directory is applied")
        harness.check(svc.accounts[0].initialized === true, "...and it reports")
      }

      else if (s === 142) {
        // A reply stamped with someone else's directory is refused outright,
        // whatever the generation says -- the in-flight case and this one are the
        // same rule now.
        svc.accounts[0].refresh(false)
        harness.finishStatus("onedrive.service", harness.statusPayload({
          confdir: "/SOMEONE/else", syncDir: "/SOMEONE/tree", statusText: "Not ours" }))
        harness.check(svc.accounts[0].syncDir === "/CUSTOM/tree",
          "a reply from another config directory is refused")
        harness.check(svc.accounts[0].statusText.indexOf("Not ours") === -1,
          "...and leaves nothing of itself behind")
      }


      // The queue was drained past an account removed while QUEUED, but not past
      // the one actually holding the slot: its destruction unregisters its
      // process without ever emitting pollFinished.
      else if (s === 143) {
        console.log("removing the account holding the cloud slot frees it")
        svc.applyDiscovery([
          { service: "onedrive@a.service", instance: "a", confdir: "/c/a", description: "A" },
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" }
        ])
        harness.drain(harness.statusPayload({}))
      }

      else if (s === 144) {
        harness.drain(harness.statusPayload({}))
        svc.accounts[0].checkQuota()
        svc.accounts[1].checkQuota()
        harness.check(harness.liveWith("--quota").length === 1,
          "A holds the cloud slot and B is queued behind it")
        harness.check(harness.liveWith("/c/a").length === 1, "...and it is A")
        // A's unit disappears mid-check.
        svc.applyDiscovery([
          { service: "onedrive@b.service", instance: "b", confdir: "/c/b", description: "B" }
        ])
        harness.check(svc.accountCount === 1, "A is gone")
      }

      else if (s === 145) {
        var freed = harness.liveWith("--quota")
        harness.check(freed.length === 1,
          "B's queued check starts rather than waiting for an unrelated poll")
        harness.check(freed.length === 1 && freed[0].indexOf("/c/b") !== -1,
          "...and it is B's, with B's own config directory")
        harness.drain(harness.statusPayload({}))
      }

      else if (s >= 146) {
        // The count is printed so tests/run can tell "every check passed" from
        // "no check ran": a qml that exits 0 without executing the harness, or a
        // step loop that stops early, both used to read as success.
        console.log("QML harness: " + harness.checks + " checks executed")
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
  property string stuck: ""
  property string stale: ""
}
