const assert = require("node:assert")
const test = require("node:test")

const Model = require("../Model.js")

// A healthy, initialized account. Each case below overrides only what it means
// to test, so a case cannot pass by accident of an unrelated default.
function account(overrides) {
  return Object.assign({
    initialized: true,
    service: "onedrive@x.service",
    instance: "x",
    description: "OneDrive sync (x account)",
    installed: true,
    authenticated: true,
    serviceAvailable: true,
    running: true,
    activeState: "active",
    serviceFailed: false,
    resyncRequired: false,
    reauthRequired: false,
    syncing: false,
    syncMode: "Two-way",
    statusText: "Monitoring",
    lastSyncTs: 0
  }, overrides || {})
}

test("every state in the total order is reachable and ranked worst-first", () => {
  const cases = [
    ["resync", { resyncRequired: true, serviceFailed: true }, 1],
    ["reauth", { reauthRequired: true }, 2],
    ["failed", { serviceFailed: true }, 3],
    ["missing", { installed: false }, 4],
    ["login", { authenticated: false }, 5],
    ["unavailable", { serviceAvailable: false }, 6],
    ["paused", { running: false, activeState: "inactive" }, 7],
    ["starting", { activeState: "activating", running: false }, 8],
    ["syncing", { syncing: true }, 9],
    ["healthy", {}, 10]
  ]
  for (const [kind, overrides, rank] of cases) {
    const state = Model.accountState(account(overrides))
    assert.equal(state.kind, kind, `expected ${kind}, got ${state.kind}`)
    assert.equal(state.rank, rank)
  }
  // Ranks are unique and dense, so "worst" is always well defined.
  const ranks = cases.map(([, , rank]) => rank)
  assert.deepEqual(ranks, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
})

test("the order holds when several conditions are true at once", () => {
  // The table above uses one condition per case, which cannot detect a swapped
  // pair. These fixtures set BOTH conditions of each adjacent pair, so the
  // winner is decided by precedence alone.
  const pairs = [
    [{ resyncRequired: true, reauthRequired: true }, "resync"],
    [{ reauthRequired: true, serviceFailed: true }, "reauth"],
    [{ serviceFailed: true, installed: false }, "failed"],
    [{ installed: false, authenticated: false }, "missing"],
    [{ authenticated: false, serviceAvailable: false }, "login"],
    [{ serviceAvailable: false, running: false, activeState: "inactive" }, "unavailable"],
    [{ running: false, activeState: "inactive", syncing: true }, "paused"],
    [{ activeState: "activating", running: false, syncing: true }, "starting"]
  ]
  for (const [overrides, expected] of pairs) {
    assert.equal(Model.accountStateKind(account(overrides)), expected, JSON.stringify(overrides))
  }
})

test("a just-pressed pause beats a stale syncing flag", () => {
  // `active` folds in the optimistic desired state. Without it the badge lagged
  // a poll in both directions, and a syncing flag left over from before the
  // pause outranked the pause itself.
  assert.equal(Model.accountStateKind(account({ running: true, active: false })), "paused")
  assert.equal(Model.accountStateKind(account({ running: true, active: false, syncing: true })), "paused")
  // ...and resuming is equally immediate.
  assert.equal(Model.accountStateKind(account({ running: false, active: true, activeState: "inactive" })), "healthy")
})

test("a required resync outranks the failure it also sets", () => {
  // Exit 126 sets both; "Resync required" is the actionable half.
  assert.equal(Model.accountStateKind(account({ resyncRequired: true, serviceFailed: true })), "resync")
})

test("the worst account wins, and the cloud stays lit while any account is active", () => {
  // The design's concrete disagreement: Dragones reauth, Personal syncing,
  // Tandera paused.
  const accounts = [
    account({ instance: "dragones", reauthRequired: true, statusText: "Reauthentication required" }),
    account({ instance: "personal", syncing: true, statusText: "Syncing" }),
    account({ instance: "tandera", running: false, activeState: "inactive", statusText: "Sync paused" })
  ]
  const summary = Model.aggregateAccounts(accounts)
  assert.equal(summary.kind, "reauth")
  assert.equal(summary.count, 3)
  assert.equal(summary.worst.instance, "dragones")
  assert.equal(summary.anyActive, true)
})

test("only a genuinely working account lights the icon", () => {
  // Discriminating: nothing here is running, so the ONLY thing that can light
  // the icon is the syncing account. Drop the syncing clause from
  // aggregateAccounts and this fails.
  const stopped = { running: false, active: false, activeState: "inactive" }
  const syncingOnly = [
    account(Object.assign({ instance: "a", reauthRequired: true }, stopped)),
    account(Object.assign({ instance: "b", syncing: true }, stopped))
  ]
  assert.equal(Model.aggregateAccounts(syncingOnly).anyActive, true)

  const noneWorking = [
    account(Object.assign({ instance: "a", reauthRequired: true }, stopped)),
    account(Object.assign({ instance: "b" }, stopped))
  ]
  assert.equal(Model.aggregateAccounts(noneWorking).anyActive, false)

  // An account that is running but was just paused reports active:false, and
  // the icon must dim immediately rather than waiting for the next poll.
  const justPaused = [account({ instance: "a", running: true, active: false })]
  assert.equal(Model.aggregateAccounts(justPaused).anyActive, false)
})

test("all accounts idle means the icon dims", () => {
  const accounts = [
    account({ instance: "a", running: false, activeState: "inactive" }),
    account({ instance: "b", running: false, activeState: "inactive" })
  ]
  assert.equal(Model.aggregateAccounts(accounts).anyActive, false)
})

test("equal ranks resolve by discovery order, not by name", () => {
  const accounts = [
    account({ instance: "zebra", reauthRequired: true }),
    account({ instance: "alpha", reauthRequired: true })
  ]
  assert.equal(Model.aggregateAccounts(accounts).worst.instance, "zebra")
})

test("an uninitialized account never contributes a state", () => {
  // Default property values would classify as "missing"; flashing that badge
  // before the first poll is the failure this guards. But an account that has
  // not reported must be EXCLUDED, not allowed to gate the whole aggregate --
  // see the freeze test below.
  const accounts = [
    account({ instance: "a", reauthRequired: true }),
    { initialized: false, instance: "b", installed: false, authenticated: false }
  ]
  const summary = Model.aggregateAccounts(accounts)
  assert.notEqual(summary.kind, "missing")
  // The account that HAS reported still drives the badge.
  assert.equal(summary.kind, "reauth")
  assert.equal(summary.worst.instance, "a")
})

test("one account that can never initialize does not freeze the bar", () => {
  // A unit whose confdir is unreadable makes the helper exit non-zero on every
  // poll, so that account's `initialized` is never set. Gating the aggregate on
  // ALL accounts meant the bar sat at "checking" forever -- no badge, undimmed
  // icon -- while another account was resync-required and invisible.
  const accounts = [
    { initialized: false, instance: "broken" },
    account({ instance: "ok", resyncRequired: true })
  ]
  const summary = Model.aggregateAccounts(accounts)
  assert.equal(summary.kind, "resync")
  assert.equal(summary.initialized, true)
  // ...and only when NOTHING has reported is it still checking.
  assert.equal(Model.aggregateAccounts([{ initialized: false }]).kind, "checking")
})

test("an empty account list is checking, not missing", () => {
  const summary = Model.aggregateAccounts([])
  assert.equal(summary.kind, "checking")
  assert.equal(summary.count, 0)
})

test("one account keeps exactly today's single-line tooltip", () => {
  const only = account({ instance: "", statusText: "Monitoring", lastSyncTs: 0 })
  assert.equal(Model.aggregateTooltip([only], Date.now()), Model.tooltip(only, Date.now()))
  assert.ok(!Model.aggregateTooltip([only], Date.now()).includes("\n"))
})

test("many accounts get an attributed, worst-first tooltip", () => {
  const now = Date.now()
  const accounts = [
    account({ instance: "dragones", reauthRequired: true, statusText: "Reauthentication required" }),
    account({ instance: "personal", syncing: true, statusText: "Syncing" }),
    account({ instance: "tandera", running: false, activeState: "inactive", statusText: "Sync paused" })
  ]
  const lines = Model.aggregateTooltip(accounts, now).split("\n")
  assert.equal(lines[0], "OneDrive · 3 accounts")
  // Worst first: reauth (2) then paused (7) then syncing (9). NOTE: the design
  // doc's illustrative example lists Personal before Tandera, which is discovery
  // order, not the worst-first rule the same section states. The rule wins --
  // an account needing attention must not sort below one that is merely idle.
  assert.ok(lines[1].startsWith("Dragones: Reauthentication required"))
  assert.ok(lines[2].startsWith("Tandera: Sync paused"))
  assert.ok(lines[3].startsWith("Personal: Syncing"))
  assert.equal(lines.length, 4)
})

test("a large installation cannot grow an unbounded tooltip", () => {
  const accounts = []
  for (let index = 0; index < 9; index++) accounts.push(account({ instance: "acct" + index }))
  const lines = Model.aggregateTooltip(accounts, Date.now()).split("\n")
  assert.equal(lines.length, 1 + 5 + 1)
  assert.equal(lines[lines.length - 1], "+4 more")
})

test("the cap keeps the accounts that need a human, not an arbitrary five", () => {
  // Nine healthy accounts plus one that needs reauth, with the unhealthy one
  // LAST in discovery order. A cap that simply took the first five in discovery
  // order -- or the last five -- would hide it behind "+N more".
  const accounts = []
  for (let index = 0; index < 9; index++) accounts.push(account({ instance: "ok" + index }))
  accounts.push(account({ instance: "broken", reauthRequired: true,
    statusText: "Reauthentication required" }))
  const lines = Model.aggregateTooltip(accounts, Date.now()).split("\n")
  assert.ok(lines[1].startsWith("Broken: Reauthentication required"), lines.join(" | "))
  assert.equal(lines.length, 1 + 5 + 1)
})

test("the tooltip is checking only while nothing has reported", () => {
  const nothing = [{ initialized: false, instance: "a" }, { initialized: false, instance: "b" }]
  assert.equal(Model.aggregateTooltip(nothing, Date.now()), "Checking 2 OneDrive accounts…")

  // Once any account has reported, the tooltip says what it knows rather than
  // hiding it behind a permanent "checking".
  const partial = [account({ instance: "a", statusText: "Monitoring" }),
                   { initialized: false, instance: "b" }]
  const text = Model.aggregateTooltip(partial, Date.now())
  assert.ok(text.startsWith("OneDrive · 2 accounts"), text)
  assert.ok(text.includes("A: Monitoring"), text)
  // The un-polled account must NOT be listed. Its default values classify as
  // "missing", which would sort it to the TOP of a worst-first list -- so the
  // tooltip would lead with "OneDrive CLI is not installed" while the badge,
  // which excludes it, showed nothing at all.
  assert.ok(!text.includes("B:"), text)
  assert.ok(!text.includes("not installed"), text)
  assert.ok(text.includes("Checking 1 more"), text)
})

test("every state maps onto the existing badge vocabulary", () => {
  // The badge set is deliberately smaller than the state set: at eight pixels a
  // badge carries a category, and the tooltip carries the detail.
  assert.equal(Model.badgeKind("resync"), "attention")
  assert.equal(Model.badgeKind("reauth"), "attention")
  assert.equal(Model.badgeKind("failed"), "attention")
  assert.equal(Model.badgeKind("missing"), "missing")
  assert.equal(Model.badgeKind("unavailable"), "missing")
  assert.equal(Model.badgeKind("login"), "login")
  assert.equal(Model.badgeKind("paused"), "paused")
  assert.equal(Model.badgeKind("starting"), "syncing")
  assert.equal(Model.badgeKind("syncing"), "syncing")
  // Healthy shows no badge, and neither does the pre-first-poll state -- that
  // is the whole point of having a checking state.
  assert.equal(Model.badgeKind("healthy"), "")
  assert.equal(Model.badgeKind("checking"), "")
})

test("no state is left without a badge decision", () => {
  const states = ["resync", "reauth", "failed", "missing", "login", "unavailable",
    "paused", "starting", "syncing", "healthy", "checking"]
  for (const kind of states) {
    assert.equal(typeof Model.badgeKind(kind), "string", kind)
  }
})

// origin/main:BarWidget.qml's flat ternary, transcribed. The single-account
// badge is compared against THIS over the whole flag space rather than against a
// hand-picked list -- a list can only ever be a partial oracle, and the earlier
// one omitted every combination where the two actually diverge.
function legacyBadgeKind(a) {
  const active = a.active !== undefined ? a.active : (a.running || a.activeState === "activating")
  const attention = a.serviceFailed || a.resyncRequired || a.reauthRequired
  if (!a.installed) return "missing"
  if (!a.authenticated) return "login"
  if (attention) return "attention"
  if (a.syncing || a.activeState === "activating") return "syncing"
  if (!active) return "paused"
  return ""
}

test("the single-account badge is compared against the old ternary exhaustively", () => {
  const flags = ["installed", "authenticated", "serviceAvailable", "running",
    "serviceFailed", "resyncRequired", "reauthRequired", "syncing"]
  const divergences = []
  for (let mask = 0; mask < (1 << flags.length); mask++) {
    for (const activeState of ["active", "activating", "inactive"]) {
      const overrides = { activeState: activeState }
      flags.forEach((flag, bit) => { overrides[flag] = Boolean(mask & (1 << bit)) })
      overrides.active = overrides.running || activeState === "activating"
      const mine = Model.badgeKind(Model.aggregateAccounts([account(overrides)]).kind)
      const old = legacyBadgeKind(overrides)
      if (mine !== old) divergences.push({ overrides, mine, old })
    }
  }

  // Every divergence must be one of the deliberate ones, named here with its
  // reason. An unlisted divergence fails, which is the point.
  const allowed = [
    // The old ternary could not express "installed and signed in but the unit is
    // not loaded"; it called that paused. `unavailable` is a distinct state and
    // maps to the missing glyph, with the tooltip distinguishing them.
    d => d.overrides.installed && d.overrides.authenticated && !d.overrides.serviceAvailable,
    // The old ternary checked !authenticated before the attention flags, so a
    // failing service on a signed-out account showed a login key. Attention
    // outranks it now: a failure is the more actionable of the two.
    d => !d.overrides.authenticated && (d.overrides.serviceFailed || d.overrides.resyncRequired
      || d.overrides.reauthRequired),
    // Likewise for a missing client with a failing unit.
    d => !d.overrides.installed && (d.overrides.serviceFailed || d.overrides.resyncRequired
      || d.overrides.reauthRequired),
    // The old ternary let a stale `syncing` flag outrank a stopped service, so a
    // just-pressed Pause kept a pulsing sync badge until the next poll. Pause
    // wins now, which is what makes the button feel immediate.
    d => d.overrides.syncing && !d.overrides.active && d.mine === "paused" && d.old === "syncing"
  ]
  const unexplained = divergences.filter(d => !allowed.some(rule => rule(d)))
  assert.deepEqual(unexplained, [],
    "undeclared badge divergence from origin/main: " + JSON.stringify(unexplained.slice(0, 3), null, 1))
})
