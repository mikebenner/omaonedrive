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
  assert.equal(Model.usageText(0, 0, false), "Refresh storage to load")
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
  assert.equal(Model.usageSevere(90, 100, true), true)
  assert.equal(Model.usageSevere(89, 100, true), false)
  assert.equal(Model.usageSevere(95, 100, false), false)
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
  const syncRow = { kind: "sync", ts: 2000, title: "Sync complete", detail: "", path: "" }
  const fileRow = { kind: "file", ts: 1500, title: "a.md", detail: "changed in Docs", path: "/OneDrive/Docs/a.md" }
  const errorRow = { kind: "error", ts: 1200, title: "Sync aborted", detail: "", path: "" }
  assert.deepEqual(
    Model.activityRows({ activity: [syncRow, fileRow, errorRow], files: [] }),
    [fileRow, errorRow]
  )
  assert.deepEqual(Model.activityRows({ activity: [syncRow], files: [] }), [])
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
  assert.equal(Model.activityGlyph({ kind: "error", recovered: true }), "󰄬")
  assert.equal(Model.syncMeta(1000, 1000 * 1000 + 3 * 60 * 1000), "synced 3m ago")
  assert.equal(Model.syncMeta(1000, 1000 * 1000 + 45 * 1000), "synced Just now")
  assert.equal(Model.syncMeta(0), "")
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
  const markupStatus = {
    installed: true,
    authenticated: true,
    statusText: "Uploading <b>quarterly report</b>.pdf",
    syncMode: "Two-way",
    lastSyncTs: 0
  }
  assert.equal(
    Model.tooltip(markupStatus),
    "Uploading ‹b›quarterly report‹/b›.pdf · Two-way"
  )
  assert.equal(
    Model.heroMeta(markupStatus),
    "Uploading ‹b›quarterly report‹/b›.pdf · Two-way"
  )
  assert.doesNotMatch(Model.tooltip(markupStatus), /[<>]/)
  assert.equal(Model.filePath("file:///tmp/Oma%20OneDrive/status.py"), "/tmp/Oma OneDrive/status.py")
})

test("notification click actions follow Omarchy 4.0.1's safe argv contract", () => {
  assert.deepEqual(
    Model.notificationActionArgv("open"),
    ["omarchy-shell", "io.github.salemsayed.omaonedrive", "open"]
  )
  assert.deepEqual(
    Model.notificationActionArgv("repair"),
    ["omarchy-shell", "io.github.salemsayed.omaonedrive", "resync"]
  )
  assert.deepEqual(Model.notificationActionArgv("arbitrary user input"), [])

  assert.deepEqual(
    Model.notificationCommand("critical", "OneDrive failed", "Open the panel.", "open"),
    [
      "omarchy-notification-send", "--app-name", "OmaOneDrive", "--urgency", "critical",
      "OneDrive failed", "Open the panel.", "--exec",
      "omarchy-shell", "io.github.salemsayed.omaonedrive", "open"
    ]
  )
  assert.deepEqual(
    Model.notificationCommand("normal", "OneDrive recovered", "Sync is healthy.", ""),
    [
      "omarchy-notification-send", "--app-name", "OmaOneDrive", "--urgency", "normal",
      "OneDrive recovered", "Sync is healthy."
    ]
  )
})
