const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const path = require("node:path")
const test = require("node:test")

// BarWidget.qml and Panel.qml derive from the bar's own types, so neither can be
// instantiated headless and neither is reachable by the QML harness. A reviewer
// showed what regex assertions cost there: with `assert.match` alone, the broken
// "one missing account dims a healthy bar" expression could be restored, the IPC
// handlers given early returns, and Panel.open()'s selection call wrapped in
// `if (false)` -- all with the entire suite green, because a regex only proves
// the text appears SOMEWHERE.
//
// So these compare the whole decision, exactly. Every rule is tested for real in
// Model.js; what is pinned here is that these two files do nothing but delegate
// to it. That makes them brittle by design: if you change the wiring, change the
// expectation below, and the diff will say what the bar's behaviour now is.

const root = path.join(__dirname, "..")
const barWidget = readFileSync(path.join(root, "BarWidget.qml"), "utf8")
const panel = readFileSync(path.join(root, "Panel.qml"), "utf8")

// Comments are stripped so wording changes do not break the test; everything
// else -- including an added `if (false)` or an early return -- does.
function code(source, from, to) {
  const start = source.indexOf(from)
  assert.notEqual(start, -1, "could not find: " + from)
  const end = source.indexOf(to, start + from.length)
  assert.notEqual(end, -1, "could not find: " + to)
  return source
    .slice(start, end)
    .split("\n")
    .map(line => line.replace(/(^|\s)\/\/.*$/, ""))
    .join(" ")
    .replace(/\s+/g, " ")
    .trim()
}

test("the bar's state is Model's answer, unmodified", () => {
  // Nothing may be recomputed, overridden or short-circuited on the way to the
  // icon. Every one of these rules is table-tested in Aggregate.test.js.
  assert.equal(
    code(barWidget, "readonly property var barState:", "readonly property color iconColor:"),
    'readonly property var barState: Model.barState(aggregate) ' +
    'readonly property bool active: barState.active ' +
    'readonly property bool syncing: barState.syncing ' +
    'readonly property bool installed: barState.installed')
})

test("the badge follows the badge kind, not the worst account's kind", () => {
  // aggregate.badge and aggregate.kind differ exactly when an account is paused
  // while another transfers. Reading `kind` here put a pause glyph on a bar that
  // was syncing, and stopped it spinning.
  assert.equal(
    code(barWidget, "readonly property string badgeKind:", "readonly property color badgeColor:"),
    'readonly property string badgeKind: Model.badgeKind(aggregate.badge) ' +
    'readonly property string badgeGlyph: Model.badgeGlyph(badgeKind)')
})

test("the aggregate comes from the service, with a checking placeholder", () => {
  assert.equal(
    code(barWidget, "readonly property var aggregate:", "readonly property int accountCount:"),
    'readonly property var aggregate: service ? service.aggregate ' +
    ': ({ kind: "checking", badge: "checking", count: 0, anyActive: false, initialized: false })')
})

test("the IPC account handlers delegate and do nothing else", () => {
  assert.equal(
    code(barWidget, "function accounts(): string", "function selectAccount(target: string)"),
    'function accounts(): string { if (!root.service) return "[]" ' +
    'return JSON.stringify(Model.accountRows(root.service.accounts, root.service.selectedService)) }')
  assert.equal(
    code(barWidget, "function selectAccount(target: string)", "\n  }\n\n  BarIconButton"),
    'function selectAccount(target: string): string { if (!root.service) return "no accounts" ' +
    'var found = Model.resolveAccountTarget(root.service.accounts, target) ' +
    'if (found === "") return "unknown account: " + target ' +
    // false: automation must not inherit the panel's stale-quota retry, which
    // contacts Microsoft.
    'root.service.selectAccount(found, false) return "ok" }')
})

test("opening the panel selects the badged account first, then refreshes", () => {
  // Order matters: the panel's bindings and its refresh both read the selection.
  assert.equal(
    code(panel, "function open() {", "Qt.callLater"),
    'function open() { root.controller.show() oneDrive.selectBadgedAccount() ' +
    'oneDrive.refreshSelected() oneDrive.retryStaleQuotaOnOpen()')
})
