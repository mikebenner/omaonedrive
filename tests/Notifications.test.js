const assert = require("node:assert")
const test = require("node:test")

const Model = require("../Model.js")

function event(kind, name, overrides) {
  const summaries = {
    resync: "OneDrive needs a resync",
    failed: "OneDrive sync failed",
    reauth: "OneDrive needs reauthentication",
    storage: "OneDrive storage almost full",
    recovered: "OneDrive recovered"
  }
  const shorts = {
    resync: "Resync required",
    failed: "Sync failed",
    reauth: "Reauthentication required",
    storage: "Almost full",
    recovered: "Recovered"
  }
  return Object.assign({
    service: "onedrive@" + name.toLowerCase() + ".service",
    name: name,
    kind: kind,
    summary: summaries[kind],
    short: shorts[kind],
    body: "detail for " + name,
    action: kind === "resync" ? "repair" : (kind === "recovered" || kind === "storage" ? "" : "open"),
    actionLabel: kind === "resync" ? "Run resync repair" : "Open OneDrive panel"
  }, overrides || {})
}

test("nothing to say produces no notification", () => {
  assert.equal(Model.composeNotification([], true), null)
  assert.equal(Model.composeNotification(null, true), null)
  assert.equal(Model.composeNotification([null, undefined], true), null)
})

test("a single account keeps today's unattributed summary", () => {
  const one = Model.composeNotification([event("reauth", "OneDrive")], false)
  assert.equal(one.summary, "OneDrive needs reauthentication")
  assert.ok(!one.summary.includes("—"))
})

test("with several accounts a lone event names its account", () => {
  const one = Model.composeNotification([event("reauth", "Dragones")], true)
  assert.equal(one.summary, "OneDrive needs reauthentication — Dragones")
  assert.equal(one.urgency, "critical")
})

test("a lone resync keeps its actionable repair button", () => {
  // The one case where the click can act directly rather than just opening.
  const one = Model.composeNotification([event("resync", "Dragones")], true)
  assert.equal(one.action, "repair")
  assert.equal(one.actionLabel, "Run resync repair")
  assert.equal(one.service, "onedrive@dragones.service")
})

test("three accounts failing at once produce ONE grouped popup", () => {
  const grouped = Model.composeNotification([
    event("reauth", "Dragones"), event("failed", "Personal"), event("resync", "Tandera")
  ], true)
  assert.equal(grouped.summary, "OneDrive needs attention in 3 accounts")
  assert.equal(grouped.body.split("\n").length, 3)
  assert.ok(grouped.body.includes("Dragones:"))
  assert.ok(grouped.body.includes("Personal:"))
  assert.ok(grouped.body.includes("Tandera:"))
})

test("a grouped popup opens the WORST account, not the first", () => {
  // resync outranks failed outranks reauth, and the click must land on the one
  // that most needs a human.
  const grouped = Model.composeNotification([
    event("reauth", "Dragones"), event("resync", "Tandera")
  ], true)
  assert.equal(grouped.service, "onedrive@tandera.service")
  assert.equal(grouped.action, "open")
  // A grouped popup must NOT carry a direct repair action: it cannot know which
  // account the reader means.
  assert.notEqual(grouped.action, "repair")
})

test("several recoveries collapse into one", () => {
  const recovered = Model.composeNotification([
    event("recovered", "Dragones"), event("recovered", "Personal")
  ], true)
  assert.equal(recovered.summary, "2 OneDrive accounts recovered")
  assert.equal(recovered.urgency, "normal")
  assert.equal(recovered.action, "")
})

test("attention outranks recovery in the same burst", () => {
  const mixed = Model.composeNotification([
    event("recovered", "Personal"), event("reauth", "Dragones")
  ], true)
  assert.equal(mixed.urgency, "critical")
  assert.ok(mixed.summary.includes("reauthentication"))
  // The recovery is still reported, in the body.
  assert.ok(mixed.body.includes("Personal"))
})

test("storage alone stays a normal-urgency notification", () => {
  const one = Model.composeNotification([event("storage", "Dragones")], true)
  assert.equal(one.urgency, "normal")
  assert.equal(one.summary, "OneDrive storage almost full — Dragones")
  const many = Model.composeNotification([
    event("storage", "Dragones"), event("storage", "Personal")
  ], true)
  assert.equal(many.summary, "2 OneDrive accounts are almost full")
})

test("a burst never yields more than one notification", () => {
  // The property that matters: whatever arrives in one polling burst, exactly
  // one popup comes out.
  const bursts = [
    [event("reauth", "A")],
    [event("reauth", "A"), event("failed", "B")],
    [event("recovered", "A"), event("recovered", "B"), event("recovered", "C")],
    [event("storage", "A"), event("reauth", "B"), event("recovered", "C")],
    [event("resync", "A"), event("resync", "B"), event("failed", "C"), event("storage", "D")]
  ]
  for (const burst of bursts) {
    const result = Model.composeNotification(burst, true)
    assert.ok(result && typeof result.summary === "string")
    assert.equal(typeof result.body, "string")
  }
})

test("a startup round of pre-existing problems is one baseline popup", () => {
  // Three accounts that were already unhealthy when the widget started must not
  // fire three notifications.
  const baseline = Model.composeNotification([
    event("reauth", "Dragones"), event("reauth", "Personal"), event("failed", "Tandera")
  ], true)
  assert.equal(baseline.summary, "OneDrive needs attention in 3 accounts")
})
