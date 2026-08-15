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
    authenticated: false,
    syncing: false,
    statusText: "Unavailable",
    syncDir: "",
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
  if (Number(status.lastSyncTs || 0) > 0)
    parts.push("last sync " + relativeTime(status.lastSyncTs, nowMs))
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
    relativeTime: relativeTime,
    fileMeta: fileMeta,
    folderName: folderName,
    tooltip: tooltip,
    filePath: filePath
  }
}
