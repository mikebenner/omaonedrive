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
  // Personal is still syncing, so the main icon must not dim.
  assert.equal(summary.anyActive, true)
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
  // before the first poll is the failure this guards.
  const accounts = [
    account({ instance: "a" }),
    { initialized: false, instance: "b", installed: false, authenticated: false }
  ]
  const summary = Model.aggregateAccounts(accounts)
  assert.equal(summary.kind, "checking")
  assert.equal(summary.initialized, false)
  assert.notEqual(summary.kind, "missing")
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

test("a partially-initialized set says it is still checking", () => {
  const accounts = [account({ instance: "a" }), { initialized: false, instance: "b" }]
  assert.equal(Model.aggregateTooltip(accounts, Date.now()), "Checking 2 OneDrive accounts…")
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

test("a single account produces the same badge it does today", () => {
  // Today's bar computes: !installed -> missing, !authenticated -> login,
  // attention flags -> attention, syncing/starting -> syncing, !active -> paused.
  const cases = [
    [{ installed: false }, "missing"],
    [{ authenticated: false }, "login"],
    [{ serviceFailed: true }, "attention"],
    [{ resyncRequired: true }, "attention"],
    [{ reauthRequired: true }, "attention"],
    [{ syncing: true }, "syncing"],
    [{ activeState: "activating", running: false }, "syncing"],
    [{ running: false, activeState: "inactive" }, "paused"],
    [{}, ""]
  ]
  for (const [overrides, expected] of cases) {
    const summary = Model.aggregateAccounts([account(overrides)])
    assert.equal(Model.badgeKind(summary.kind), expected, JSON.stringify(overrides))
  }
})
