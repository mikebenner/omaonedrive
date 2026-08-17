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
    statusText: "Unavailable",
    syncDir: "",
    syncMode: "Two-way",
    clientVersion: "",
    resumeAt: 0,
    lastSyncTs: 0,
    usedBytes: 0,
    quotaBytes: 0,
    quotaKnown: false,
    remoteStatus: "Not checked",
    remoteCheckedTs: 0,
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
  return "Check cloud to load"
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
  if (Array.isArray(status.activity) && status.activity.length > 0) return status.activity
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

function activityGlyph(row) {
  if (!row || typeof row !== "object") return ""
  if (row.kind === "file") return fileGlyph(row.title)
  if (row.kind === "sync") return "󰄬"
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
    usageShort: usageShort,
    relativeTime: relativeTime,
    checkedText: checkedText,
    activityRows: activityRows,
    activityMeta: activityMeta,
    activityGlyph: activityGlyph,
    fileMeta: fileMeta,
    folderName: folderName,
    tooltip: tooltip,
    heroMeta: heroMeta,
    filePath: filePath
  }
}
