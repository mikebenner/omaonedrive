var IMAGE_EXTENSIONS = {
  jpg: true, jpeg: true, png: true, gif: true, webp: true, avif: true, heic: true,
  svg: true, bmp: true, tif: true, tiff: true
}

var VIDEO_EXTENSIONS = {
  mp4: true, mov: true, mkv: true, webm: true, avi: true, m4v: true, mpg: true,
  mpeg: true, wmv: true
}

var DOCUMENT_EXTENSIONS = {
  pdf: true, txt: true, md: true, doc: true, docx: true, xls: true, xlsx: true,
  ppt: true, pptx: true, odt: true, ods: true, odp: true, rtf: true, csv: true,
  pages: true, numbers: true, key: true
}

function defaultStatus() {
  return {
    ok: true,
    installed: false,
    serviceAvailable: false,
    running: false,
    enabled: false,
    activeState: "",
    serviceFailed: false,
    resyncRequired: false,
    authenticated: false,
    reauthRequired: false,
    syncing: false,
    syncStage: "",
    statusText: "Unavailable",
    syncDir: "",
    syncMode: "Two-way",
    clientVersion: "",
    resumeAt: 0,
    lastSyncTs: 0,
    usedBytes: 0,
    quotaBytes: 0,
    quotaKnown: false,
    quotaCheckedTs: 0,
    quotaError: "",
    remoteStatus: "Not checked",
    syncStatusCheckedTs: 0,
    syncStatusError: "",
    remoteCheckedTs: 0,
    remoteError: "",
    files: [],
    lastError: ""
  }
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return defaultStatus()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return defaultStatus()
    parsed.files = Array.isArray(parsed.files) ? parsed.files : []
    return parsed
  } catch (error) {
    var failed = defaultStatus()
    failed.ok = false
    failed.lastError = "Failed to parse OneDrive status"
    return failed
  }
}

function fileExtension(name) {
  var value = String(name || "").toLowerCase()
  var index = value.lastIndexOf(".")
  return index >= 0 ? value.substring(index + 1) : ""
}

function fileKind(name) {
  var extension = fileExtension(name)
  if (IMAGE_EXTENSIONS[extension]) return "image"
  if (VIDEO_EXTENSIONS[extension]) return "video"
  if (DOCUMENT_EXTENSIONS[extension]) return "document"
  return "misc"
}

function fileGlyph(name) {
  var kind = fileKind(name)
  if (kind === "image") return "󰋩"
  if (kind === "video") return "󰈫"
  if (kind === "document") return "󰈙"
  return "󰈔"
}

function formatBytes(bytes) {
  var value = Number(bytes || 0)
  if (!isFinite(value) || value <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (value >= 1000 && index < units.length - 1) {
    value = value / 1000
    index++
  }
  var decimals = value >= 100 || index === 0 ? 0 : (value >= 10 ? 1 : 2)
  return value.toFixed(decimals).replace(/\.0+$/, "").replace(/(\.\d)0$/, "$1") + " " + units[index]
}

function usageText(usedBytes, quotaBytes, quotaKnown) {
  if (quotaKnown && Number(quotaBytes || 0) > 0)
    return formatBytes(usedBytes) + " of " + formatBytes(quotaBytes)
  return "Refresh storage to load"
}

function freeText(usedBytes, quotaBytes, quotaKnown) {
  var quota = Number(quotaBytes || 0)
  if (!quotaKnown || !isFinite(quota) || quota <= 0) return ""
  var used = Number(usedBytes || 0)
  if (!isFinite(used)) used = 0
  return formatBytes(Math.max(0, quota - used)) + " free"
}

function usageFraction(usedBytes, quotaBytes, quotaKnown) {
  var quota = Number(quotaBytes || 0)
  if (!quotaKnown || !isFinite(quota) || quota <= 0) return 0
  var used = Number(usedBytes || 0)
  if (!isFinite(used)) used = 0
  return Math.max(0, Math.min(1, used / quota))
}

var QUOTA_WARNING_FRACTION = 0.9

function usageSevere(usedBytes, quotaBytes, quotaKnown) {
  return usageFraction(usedBytes, quotaBytes, quotaKnown) >= QUOTA_WARNING_FRACTION
}

function usageShort(usedBytes, quotaBytes, quotaKnown) {
  var quota = Number(quotaBytes || 0)
  if (!quotaKnown || !isFinite(quota) || quota <= 0) return "Not checked"
  return formatBytes(usedBytes) + " / " + formatBytes(quota)
}

function relativeTime(timestampSec, nowMs) {
  var timestamp = Number(timestampSec || 0)
  if (!isFinite(timestamp) || timestamp <= 0) return "Never"
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var difference = Math.max(0, Math.floor((now - timestamp * 1000) / 1000))
  if (difference < 60) return "Just now"
  var minutes = Math.floor(difference / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 30) return days + "d ago"
  var months = Math.floor(days / 30)
  if (months < 12) return months + "mo ago"
  return Math.floor(days / 365) + "y ago"
}

function checkedText(remoteCheckedTs, nowMs) {
  var timestamp = Number(remoteCheckedTs || 0)
  if (!isFinite(timestamp) || timestamp <= 0) return "never checked"
  return "checked " + relativeTime(timestamp, nowMs)
}

function activityRows(status) {
  if (!status || typeof status !== "object") return []
  if (Array.isArray(status.activity) && status.activity.length > 0)
    return status.activity.filter(function(row) { return !row || row.kind !== "sync" })
  if (!Array.isArray(status.files)) return []

  var rows = []
  for (var index = 0; index < status.files.length; index++) {
    var file = status.files[index]
    if (!file || typeof file !== "object") file = {}
    var timestamp = Number(file.modifiedTs || 0)
    if (!isFinite(timestamp)) timestamp = 0
    var folder = String(file.folder || "/")
    rows.push({
      kind: "file",
      ts: timestamp,
      title: String(file.name || ""),
      detail: folder === "/" ? "changed in OneDrive" : "changed in " + folder,
      path: String(file.path || "")
    })
  }
  return rows.sort(function(left, right) { return right.ts - left.ts }).slice(0, 8)
}

function activityMeta(rows, nowMs) {
  if (!Array.isArray(rows) || rows.length === 0) return ""
  var newest = 0
  for (var index = 0; index < rows.length; index++) {
    var row = rows[index]
    var timestamp = Number(row && row.ts || 0)
    if (isFinite(timestamp) && timestamp > newest) newest = timestamp
  }
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  if (!isFinite(now)) now = Date.now()
  if (newest > 0 && now - newest * 1000 <= 24 * 60 * 60 * 1000) return "last 24 h"
  return relativeTime(newest, now)
}

function syncMeta(lastSyncTs, nowMs) {
  var timestamp = Number(lastSyncTs || 0)
  if (!isFinite(timestamp) || timestamp <= 0) return ""
  return "synced " + relativeTime(timestamp, nowMs)
}

function activityGlyph(row) {
  if (!row || typeof row !== "object") return ""
  if (row.kind === "file") return fileGlyph(row.title)
  if (row.kind === "sync") return "󰄬"
  if (row.kind === "error" && row.recovered === true) return "󰄬"
  if (row.kind === "error") return "󰀪"
  return ""
}

function fileMeta(file, nowMs) {
  if (!file) return ""
  var parts = [relativeTime(file.modifiedTs, nowMs)]
  var folder = String(file.folder || "")
  if (folder !== "") parts.push(folder)
  return parts.join(" · ")
}

function folderName(path) {
  var value = String(path || "").replace(/\/+$/, "")
  if (value === "") return "Not configured"
  var parts = value.split("/")
  return parts[parts.length - 1] || value
}

function tooltip(status, nowMs) {
  if (!status || status.installed !== true) return "OneDrive CLI is not installed"
  var parts = [String(status.statusText || "OneDrive")]
  if (status.authenticated === true && String(status.syncMode || "") !== "")
    parts.push(String(status.syncMode))
  if (Number(status.lastSyncTs || 0) > 0)
    parts.push("last sync " + relativeTime(status.lastSyncTs, nowMs))
  return parts.join(" · ")
}

function heroMeta(status) {
  if (!status || typeof status !== "object") return "Checking…"
  var parts = [String(status.statusText || "OneDrive")]
  if (status.authenticated === true && String(status.syncMode || "") !== "")
    parts.push(String(status.syncMode))
  return parts.join(" · ")
}

// --- multi-account aggregation ------------------------------------------------

// "personal" -> "Personal", "work-mail" -> "Work Mail". The plain service has no
// instance and is simply "OneDrive", which is also the hero title, so a
// single-account install reads exactly as it does today. The description is
// accepted for callers that want it but is not used: systemd descriptions are
// sentences ("OneDrive sync (personal account)"), not labels for a tab.
function accountName(instance, description) {
  var value = String(instance || "").trim()
  if (value === "") return "OneDrive"
  var words = value.replace(/[_-]+/g, " ").split(" ")
  var named = []
  for (var index = 0; index < words.length; index++) {
    var word = words[index]
    if (word === "") continue
    named.push(word.charAt(0).toUpperCase() + word.slice(1))
  }
  return named.length ? named.join(" ") : value
}

// One total order, worst first. Ranked rather than named-compared so the bar can
// pick a winner without knowing what any particular state means.
//
// resync is deliberately checked before failed: a required resync exits 126,
// which sets serviceFailed too, and "Resync required" is the actionable half.
var ACCOUNT_STATES = [
  { kind: "resync", rank: 1 },
  { kind: "reauth", rank: 2 },
  { kind: "failed", rank: 3 },
  { kind: "missing", rank: 4 },
  { kind: "login", rank: 5 },
  { kind: "unavailable", rank: 6 },
  { kind: "paused", rank: 7 },
  { kind: "starting", rank: 8 },
  { kind: "syncing", rank: 9 },
  { kind: "healthy", rank: 10 }
]

function accountStateKind(account) {
  if (!account || typeof account !== "object") return "missing"
  if (account.resyncRequired === true) return "resync"
  if (account.reauthRequired === true) return "reauth"
  if (account.serviceFailed === true) return "failed"
  if (account.installed !== true) return "missing"
  if (account.authenticated !== true) return "login"
  if (account.serviceAvailable !== true) return "unavailable"
  if (String(account.activeState || "") === "activating") return "starting"
  if (account.running !== true) return "paused"
  if (account.syncing === true) return "syncing"
  return "healthy"
}

function accountState(account) {
  var kind = accountStateKind(account)
  for (var index = 0; index < ACCOUNT_STATES.length; index++) {
    if (ACCOUNT_STATES[index].kind === kind) return ACCOUNT_STATES[index]
  }
  return ACCOUNT_STATES[ACCOUNT_STATES.length - 1]
}

// Worst of N. Until every discovered account has produced a first sample the
// aggregate is "checking" with no badge, so default property values cannot flash
// a missing-client badge before the first poll lands.
function aggregateAccounts(accounts) {
  var list = Array.isArray(accounts) ? accounts : []
  if (list.length === 0) {
    return { kind: "checking", rank: 0, count: 0, worst: null, anyActive: false, initialized: false }
  }
  var initialized = true
  var worst = null
  var worstRank = Number.MAX_VALUE
  var anyActive = false
  for (var index = 0; index < list.length; index++) {
    var account = list[index]
    if (!account || account.initialized !== true) {
      initialized = false
      continue
    }
    var state = accountState(account)
    // Strictly less-than, so equal ranks keep discovery order.
    if (state.rank < worstRank) {
      worstRank = state.rank
      worst = account
    }
    if (account.running === true || String(account.activeState || "") === "activating"
        || account.syncing === true) {
      anyActive = true
    }
  }
  if (!initialized || worst === null) {
    return { kind: "checking", rank: 0, count: list.length, worst: null, anyActive: anyActive, initialized: false }
  }
  return {
    kind: accountStateKind(worst),
    rank: worstRank,
    count: list.length,
    worst: worst,
    anyActive: anyActive,
    initialized: true
  }
}

// N=1 keeps exactly today's one-line tooltip. N>1 is attributed and ordered
// worst first, then discovery order, capped so a large installation cannot grow
// an unbounded tooltip.
function aggregateTooltip(accounts, nowMs, maxLines) {
  var list = Array.isArray(accounts) ? accounts : []
  if (list.length === 0) return "Checking OneDrive…"
  if (list.length === 1) {
    return list[0] && list[0].initialized === true
      ? tooltip(list[0], nowMs) : "Checking OneDrive…"
  }
  var summary = aggregateAccounts(list)
  if (!summary.initialized) return "Checking " + list.length + " OneDrive accounts…"

  var ordered = list.slice().map(function (account, index) {
    return { account: account, index: index, rank: accountState(account).rank }
  })
  ordered.sort(function (left, right) {
    return left.rank === right.rank ? left.index - right.index : left.rank - right.rank
  })

  var cap = maxLines === undefined ? 5 : maxLines
  var lines = ["OneDrive · " + list.length + " accounts"]
  for (var index = 0; index < ordered.length && index < cap; index++) {
    var account = ordered[index].account
    lines.push(accountName(account.instance, account.description) + ": " + tooltip(account, nowMs))
  }
  if (ordered.length > cap) lines.push("+" + (ordered.length - cap) + " more")
  return lines.join("\n")
}

function filePath(url) {
  return decodeURIComponent(String(url || "").replace(/^file:\/\//, ""))
}

if (typeof module !== "undefined") {
  module.exports = {
    defaultStatus: defaultStatus,
    parseStatus: parseStatus,
    fileExtension: fileExtension,
    fileKind: fileKind,
    fileGlyph: fileGlyph,
    formatBytes: formatBytes,
    usageText: usageText,
    freeText: freeText,
    usageFraction: usageFraction,
    usageSevere: usageSevere,
    usageShort: usageShort,
    relativeTime: relativeTime,
    checkedText: checkedText,
    activityRows: activityRows,
    activityMeta: activityMeta,
    syncMeta: syncMeta,
    activityGlyph: activityGlyph,
    fileMeta: fileMeta,
    folderName: folderName,
    tooltip: tooltip,
    heroMeta: heroMeta,
    accountName: accountName,
    accountStateKind: accountStateKind,
    accountState: accountState,
    aggregateAccounts: aggregateAccounts,
    aggregateTooltip: aggregateTooltip,
    filePath: filePath
  }
}
