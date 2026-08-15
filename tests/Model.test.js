const assert = require("node:assert/strict")
const test = require("node:test")
const Model = require("../Model.js")

test("status parser accepts valid data and fails closed", () => {
  const parsed = Model.parseStatus(JSON.stringify({
    ok: true,
    installed: true,
    running: true,
    files: [{ name: "report.pdf" }]
  }))
  assert.equal(parsed.installed, true)
  assert.equal(parsed.files.length, 1)
  assert.equal(Model.parseStatus("broken").ok, false)
  assert.deepEqual(Model.parseStatus("").files, [])
})

test("file kinds and glyphs cover common content", () => {
  assert.equal(Model.fileKind("photo.JPG"), "image")
  assert.equal(Model.fileKind("clip.webm"), "video")
  assert.equal(Model.fileKind("report.pdf"), "document")
  assert.equal(Model.fileKind("archive.zip"), "misc")
  assert.notEqual(Model.fileGlyph("report.pdf"), Model.fileGlyph("archive.zip"))
})

test("byte and quota formatting is deterministic", () => {
  assert.equal(Model.formatBytes(1530), "1.53 KB")
  assert.equal(Model.formatBytes(2_000_000_000), "2 GB")
  assert.equal(Model.usageText(1000, 2000, true), "1 KB of 2 KB")
  assert.equal(Model.usageText(0, 0, false), "Check cloud to load")
})

test("relative timestamps and file metadata are readable", () => {
  assert.equal(Model.relativeTime(1000, 1000 * 1000 + 45 * 1000), "Just now")
  assert.equal(Model.relativeTime(1000, 1000 * 1000 + 3600 * 1000), "1h ago")
  assert.equal(Model.fileMeta({ modifiedTs: 1000, folder: "Docs" }, 1000 * 1000 + 3600 * 1000), "1h ago · Docs")
  assert.equal(Model.relativeTime(0), "Never")
})

test("folder, tooltip, and plugin paths handle spaces", () => {
  assert.equal(Model.folderName("/home/salem/My OneDrive/"), "My OneDrive")
  assert.equal(Model.folderName(""), "Not configured")
  assert.equal(Model.tooltip({ installed: false }), "OneDrive CLI is not installed")
  assert.equal(
    Model.tooltip({ installed: true, statusText: "Monitoring", lastSyncTs: 1000 }, 1000 * 1000 + 60 * 1000),
    "Monitoring · last sync 1m ago"
  )
  assert.equal(Model.filePath("file:///tmp/Oma%20OneDrive/status.py"), "/tmp/Oma OneDrive/status.py")
})
