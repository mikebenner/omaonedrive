const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const path = require("node:path")
const test = require("node:test")

const source = readFileSync(path.join(__dirname, "..", "BarWidget.qml"), "utf8")
const modelSource = readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const serviceSource = readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8")
const presentationSource = ["Panel.qml", "StatusBadge.qml"]
  .map(name => readFileSync(path.join(__dirname, "..", name), "utf8"))
  .join("\n")
const manifest = JSON.parse(readFileSync(path.join(__dirname, "..", "manifest.json"), "utf8"))
const changelog = readFileSync(path.join(__dirname, "..", "CHANGELOG.md"), "utf8")

test("IPC registration waits for a relocated bar slot to retire", () => {
  assert.match(source, /property bool ipcRegistrationReady: false/)
  assert.match(source, /id: ipcRegistrationTimer\s+interval: 100/)
  assert.match(source, /IpcHandler \{\s+enabled: root\.ipcRegistrationReady\s+target: root\.moduleName/)
})

test("notification actions use Omarchy's durable exec hint with argv", () => {
  assert.match(serviceSource, /Model\.notificationCommand\(urgency, summary, body, behavior\)/)
  assert.doesNotMatch(serviceSource, /notificationActionCommand/)
  assert.doesNotMatch(serviceSource, /"--exec", actionCommand/)
  assert.doesNotMatch(serviceSource, /"notify-send"/)
  assert.doesNotMatch(serviceSource, /--action=default=/)
})

test("every text surface renders helper and file data as literal plain text", () => {
  const textItems = presentationSource.match(/\bText\s*\{/g) || []
  const plainTextItems = presentationSource.match(
    /\bText\s*\{\s*textFormat:\s*Text\.PlainText\b/g
  ) || []
  const sectionHeaders = presentationSource.match(/\bPanelSectionHeader\s*\{/g) || []
  const plainSectionHeaders = presentationSource.match(
    /\bPanelSectionHeader\s*\{\s*textFormat:\s*Text\.PlainText\b/g
  ) || []
  assert.equal(textItems.length, 22)
  assert.equal(plainTextItems.length, textItems.length)
  assert.equal(sectionHeaders.length, 3)
  assert.equal(plainSectionHeaders.length, sectionHeaders.length)
  assert.match(modelSource, /function inheritedPlainText\(value\)/)
  assert.match(modelSource, /return inheritedPlainText\(parts\.join\(" · "\)\)/)
})

test("release metadata stays synchronized", () => {
  assert.match(manifest.version, /^\d+\.\d+\.\d+$/)
  assert.match(changelog, new RegExp(`^## ${manifest.version.replaceAll(".", "\\.")} - \\d{4}-\\d{2}-\\d{2}$`, "m"))
})
