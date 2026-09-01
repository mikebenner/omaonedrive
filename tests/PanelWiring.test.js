const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const path = require("node:path")
const test = require("node:test")

// BarWidget.qml and Panel.qml derive from the bar's own types, so neither can be
// instantiated headless and neither is reachable by the QML harness. A reviewer
// showed what that costs: the broken "one missing account dims a healthy bar"
// expression could be restored in BarWidget.qml with the entire suite green.
//
// The answer is to keep no decision in those files -- Model.js holds the logic,
// tested directly -- and to pin the wiring here so the delegation cannot be cut.

const root = path.join(__dirname, "..")
const barWidget = readFileSync(path.join(root, "BarWidget.qml"), "utf8")
const panel = readFileSync(path.join(root, "Panel.qml"), "utf8")

test("the panel opens on the account the badge is blaming", () => {
  // Without this call the bar could show "reauthentication required" for Work
  // while the panel opened on a healthy Personal -- and P, right-click Storage
  // and every IPC control then acted on Personal.
  const open = panel.slice(panel.indexOf("function open()"))
  const body = open.slice(0, open.indexOf("\n  }"))
  assert.match(body, /oneDrive\.selectBadgedAccount\(\)/)
  // ...and before anything reads the selection, or the first paint and the
  // refresh both use the old one.
  assert.ok(body.indexOf("selectBadgedAccount") < body.indexOf("refreshSelected"),
    "the selection must move before the panel refreshes it")
})

test("the bar's derived state comes from Model, not from an expression here", () => {
  for (const property of ["active", "syncing", "installed"]) {
    const line = barWidget.split("\n").find(row => row.includes(`property bool ${property}:`))
    assert.ok(line, `${property} is missing from BarWidget.qml`)
    assert.match(line, /barState\./,
      `${property} must read Model.barState, or it is untestable: ${line}`)
  }
  assert.match(barWidget, /readonly property var barState: Model\.barState\(aggregate\)/)
})
