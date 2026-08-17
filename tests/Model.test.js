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

test("storage presentation handles known and unknown quotas", () => {
  assert.equal(Model.freeText(42_000_000_000, 100_000_000_000, true), "58 GB free")
  assert.equal(Model.freeText(0, 0, false), "")
  assert.equal(Model.usageFraction(25, 100, true), 0.25)
  assert.equal(Model.usageFraction(125, 100, true), 1)
  assert.equal(Model.usageFraction(-25, 100, true), 0)
  assert.equal(Model.usageFraction(25, 100, false), 0)
  assert.equal(Model.usageShort(42_000_000_000, 100_000_000_000, true), "42 GB / 100 GB")
  assert.equal(Model.usageShort(0, 0, false), "Not checked")
})

test("relative timestamps and file metadata are readable", () => {
  assert.equal(Model.relativeTime(1000, 1000 * 1000 + 45 * 1000), "Just now")
  assert.equal(Model.relativeTime(1000, 1000 * 1000 + 3600 * 1000), "1h ago")
  assert.equal(Model.fileMeta({ modifiedTs: 1000, folder: "Docs" }, 1000 * 1000 + 3600 * 1000), "1h ago · Docs")
  assert.equal(Model.relativeTime(0), "Never")
  assert.equal(Model.checkedText(1000, 1000 * 1000 + 2 * 3600 * 1000), "checked 2h ago")
  assert.equal(Model.checkedText(0), "never checked")
})

test("activity rows use payload activity and fall back to files", () => {
  const activity = [{ kind: "sync", ts: 2000, title: "Sync complete", detail: "", path: "" }]
  assert.equal(Model.activityRows({ activity, files: [] }), activity)
  assert.deepEqual(Model.activityRows({
    activity: [],
    files: [{ modifiedTs: 1000, name: "report.pdf", folder: "Docs", path: "/OneDrive/Docs/report.pdf" }]
  }), [{
    kind: "file",
    ts: 1000,
    title: "report.pdf",
    detail: "changed in Docs",
    path: "/OneDrive/Docs/report.pdf"
  }])
  assert.deepEqual(Model.activityRows(null), [])
})

test("activity metadata and glyphs describe recent rows", () => {
  assert.equal(Model.activityMeta([], 1000 * 1000), "")
  assert.equal(Model.activityMeta([{ ts: 1000 }], 1000 * 1000 + 2 * 3600 * 1000), "last 24 h")
  assert.equal(Model.activityMeta([{ ts: 1000 }], 1000 * 1000 + 25 * 3600 * 1000), "1d ago")
  assert.equal(Model.activityGlyph({ kind: "file", title: "report.pdf" }), Model.fileGlyph("report.pdf"))
  assert.equal(Model.activityGlyph({ kind: "sync" }), "󰄬")
  assert.equal(Model.activityGlyph({ kind: "error" }), "󰀪")
})

test("folder, tooltip, and plugin paths handle spaces", () => {
  assert.equal(Model.folderName("/home/salem/My OneDrive/"), "My OneDrive")
  assert.equal(Model.folderName(""), "Not configured")
  assert.equal(Model.tooltip({ installed: false }), "OneDrive CLI is not installed")
  assert.equal(
    Model.tooltip({ installed: true, statusText: "Monitoring", syncMode: "", lastSyncTs: 1000 }, 1000 * 1000 + 60 * 1000),
    "Monitoring · last sync 1m ago"
  )
  assert.equal(
    Model.tooltip({
      installed: true,
      authenticated: true,
      statusText: "Monitoring",
      syncMode: "Download only",
      lastSyncTs: 0
    }),
    "Monitoring · Download only"
  )
  assert.equal(Model.heroMeta({
    authenticated: true,
    statusText: "Monitoring",
    syncMode: "Upload only"
  }), "Monitoring · Upload only")
  assert.equal(Model.filePath("file:///tmp/Oma%20OneDrive/status.py"), "/tmp/Oma OneDrive/status.py")
})
