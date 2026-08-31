const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const path = require("node:path")
const test = require("node:test")

const source = readFileSync(path.join(__dirname, "..", "BarWidget.qml"), "utf8")
const serviceSource = readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8")
const manifest = JSON.parse(readFileSync(path.join(__dirname, "..", "manifest.json"), "utf8"))
const changelog = readFileSync(path.join(__dirname, "..", "CHANGELOG.md"), "utf8")

test("IPC registration waits for a relocated bar slot to retire", () => {
  assert.match(source, /property bool ipcRegistrationReady: false/)
  assert.match(source, /id: ipcRegistrationTimer\s+interval: 100/)
  assert.match(source, /IpcHandler \{\s+enabled: root\.ipcRegistrationReady\s+target: root\.moduleName/)
})

test("notification actions use Omarchy's durable exec hint with argv", () => {
  assert.match(serviceSource, /"omarchy-notification-send", "--app-name", "OmaOneDrive", "--urgency", urgency/)
  assert.match(serviceSource, /"--exec", actionCommand, summary, body/)
  assert.match(serviceSource, /Model\.notificationActionCommand\(behavior\)/)
  assert.doesNotMatch(serviceSource, /"notify-send"/)
  assert.doesNotMatch(serviceSource, /--action=default=/)
})

test("release metadata stays synchronized", () => {
  assert.match(manifest.version, /^\d+\.\d+\.\d+$/)
  assert.match(changelog, new RegExp(`^## ${manifest.version.replaceAll(".", "\\.")} - \\d{4}-\\d{2}-\\d{2}$`, "m"))
})
