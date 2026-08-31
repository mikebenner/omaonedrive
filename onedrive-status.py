#!/usr/bin/python3

import argparse
import fcntl
import hashlib
import heapq
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


PLUGIN_ID = "io.github.salemsayed.omaonedrive"
DEFAULT_SERVICE = "onedrive.service"
RESUME_TIMER = "omaonedrive-resume.timer"
SCAN_CACHE_SECONDS = 120
MAX_SERVICE_EVENTS = 2
MAX_FILE_EVENTS = 5
ACTIVITY_LIMIT = 5
QUOTA_TIMEOUT_SECONDS = 30
SYNC_STATUS_TIMEOUT_SECONDS = 30


def command_output(command, timeout=4):
  try:
    completed = subprocess.run(
      command,
      check=False,
      capture_output=True,
      text=True,
      timeout=timeout,
    )
  except subprocess.TimeoutExpired as error:
    stdout = error.stdout.decode(errors="replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
    stderr = error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else (error.stderr or "")
    return 124, (stdout + stderr).strip()
  except OSError:
    return 1, ""
  return completed.returncode, (completed.stdout + completed.stderr).strip()


def default_confdir():
  config_home = os.environ.get("XDG_CONFIG_HOME")
  if config_home:
    return Path(config_home) / "onedrive"
  return Path.home() / ".config" / "onedrive"


MAX_CONFDIR_LENGTH = 4096


def valid_confdir(value):
  text = str(value)
  if not text.startswith("/") or len(text) > MAX_CONFDIR_LENGTH:
    return False
  if any(ord(character) < 0x20 or ord(character) == 0x7F for character in text):
    return False
  if any(part == ".." for part in text.split("/")):
    return False
  path = Path(text)
  return not path.exists() or path.is_dir()


def cache_name(confdir):
  # The default account keeps the historical file name; any other config
  # directory gets its own cache so accounts never read each other's quota.
  if Path(confdir) == default_confdir():
    return "status-cache.json"
  digest = hashlib.sha256(str(confdir).encode("utf-8")).hexdigest()[:16]
  return "status-cache-" + digest + ".json"


def state_dir():
  state_home = os.environ.get("XDG_STATE_HOME")
  base = Path(state_home) if state_home else Path.home() / ".local" / "state"
  return base / "omarchy" / PLUGIN_ID


def load_cache(path):
  try:
    with path.open("r", encoding="utf-8") as handle:
      value = json.load(handle)
      return value if isinstance(value, dict) else {}
  except (OSError, json.JSONDecodeError):
    return {}


def save_cache(path, value):
  path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
  os.chmod(path.parent, 0o700)
  descriptor, temporary = tempfile.mkstemp(prefix="cache-", suffix=".json", dir=path.parent)
  try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
      json.dump(value, handle, separators=(",", ":"))
      handle.write("\n")
      handle.flush()
      os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
  finally:
    try:
      os.unlink(temporary)
    except FileNotFoundError:
      pass


def parse_bool(value):
  return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def config_option(output, name):
  match = re.search(rf"^Config option '{re.escape(name)}'\s*=\s*(.*)$", output, re.MULTILINE)
  return match.group(1).strip().strip('"') if match else ""


def read_config_values(confdir):
  values = {}
  try:
    for line in (confdir / "config").read_text(encoding="utf-8").splitlines():
      match = re.match(r"\s*([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$", line)
      if not match:
        continue
      values[match.group(1)] = match.group(2).split("#", 1)[0].strip().strip('"')
  except OSError:
    pass
  return values


def client_config(confdir, onedrive_path):
  values = read_config_values(confdir)
  client_version = ""
  if onedrive_path:
    exit_code, output = command_output(
      [onedrive_path, "--confdir", str(confdir), "--display-config"],
      timeout=6,
    )
    if exit_code == 0:
      for name in ("sync_dir", "download_only", "upload_only"):
        value = config_option(output, name)
        if value != "":
          values[name] = value
      version_match = re.search(r"^Application version\s*=\s*(.+)$", output, re.MULTILINE)
      if version_match:
        client_version = version_match.group(1).strip()

  sync_dir_value = values.get("sync_dir", "")
  sync_dir = Path(os.path.expandvars(os.path.expanduser(sync_dir_value))) \
    if sync_dir_value else Path.home() / "OneDrive"
  download_only = parse_bool(values.get("download_only"))
  upload_only = parse_bool(values.get("upload_only"))
  if download_only and upload_only:
    sync_mode = "Invalid sync mode"
  elif download_only:
    sync_mode = "Download only"
  elif upload_only:
    sync_mode = "Upload only"
  else:
    sync_mode = "Two-way"
  return {
    "syncDir": sync_dir,
    "syncMode": sync_mode,
    "clientVersion": client_version,
  }


def systemctl_value(arguments):
  return command_output(["systemctl", "--user", *arguments], timeout=4)


def service_state(service):
  exit_code, output = systemctl_value([
    "show",
    service,
    "--property=LoadState,ActiveState,SubState,UnitFileState,Result,ExecMainCode,ExecMainStatus",
    "--no-pager",
  ])
  properties = {}
  if exit_code == 0:
    for line in output.splitlines():
      key, separator, value = line.partition("=")
      if separator:
        properties[key] = value.strip()
  load_state = properties.get("LoadState", "")
  active_state = properties.get("ActiveState", "")
  unit_file_state = properties.get("UnitFileState", "")
  result = properties.get("Result", "")
  try:
    exit_status = int(properties.get("ExecMainStatus", "0") or 0)
  except ValueError:
    exit_status = 0
  failed = active_state == "failed"
  return {
    "serviceAvailable": load_state == "loaded",
    "running": active_state == "active",
    "enabled": unit_file_state in ("enabled", "enabled-runtime"),
    "activeState": active_state,
    "subState": properties.get("SubState", ""),
    "serviceResult": result,
    "serviceExitStatus": exit_status,
    "serviceFailed": failed,
    "resyncRequired": failed and exit_status == 126,
  }


def resume_timer_state():
  exit_code, output = systemctl_value([
    "list-timers",
    RESUME_TIMER,
    "--all",
    "--output=json",
    "--no-pager",
  ])
  if exit_code != 0:
    return 0
  try:
    rows = json.loads(output)
  except json.JSONDecodeError:
    return 0
  if not isinstance(rows, list) or not rows:
    return 0
  try:
    next_usec = int(rows[0].get("next", 0) or 0)
  except (AttributeError, TypeError, ValueError):
    return 0
  return next_usec // 1_000_000 if next_usec > 0 else 0


TRANSFER_SKIP_PREFIXES = ("changes", "differences", "new items", "items", "advertised")

# Multi-line CLI error blocks: "ERROR: ..." then indented detail lines.
ERROR_DETAIL_RE = re.compile(r"^\s*Error (Message|Reason|Code):\s*(.+)$", re.IGNORECASE)

# The client handles these itself and keeps syncing (WebSocket near-real-time
# monitoring is unavailable for some account types; the client falls back to
# interval polling), so they are not worth an attention state or activity row.
BENIGN_ERROR_MARKERS = ("websocket", "notsupported", "unable to send notification")

# The client uploads inotify-detected local changes outside a full sync pass,
# without the "Starting a sync"/"complete" bracket. A progress line older than
# this is treated as an abandoned upload rather than one still running.
LIVE_TRANSFER_STALE_SEC = 600
TRANSFER_DONE_RE = re.compile(
  r"^\s*(?:Uploading|Downloading)\b.*?(?:\|\s*DONE\b|\.\.\.\s*done\b)", re.IGNORECASE
)


def parse_transfer(message):
  match = re.match(r"^\s*(Uploading|Downloading)\b\s*:?\s*(.+)$", message, re.IGNORECASE)
  if not match:
    return None
  direction = "Uploading" if match.group(1).lower() == "uploading" else "Downloading"
  rest = re.sub(r"^(?:new\s+|modified\s+|changed\s+)?file\b\s*:?\s*", "", match.group(2).strip(), flags=re.IGNORECASE)
  percent = -1
  percent_match = re.search(r"(\d{1,3})\s*%[^%]*$", rest)
  if percent_match:
    percent = min(100, int(percent_match.group(1)))
  rest = re.sub(r"\s*\.\.\..*$", "", rest).strip()
  lowered = rest.lower()
  if not rest or any(lowered.startswith(prefix) for prefix in TRANSFER_SKIP_PREFIXES):
    return None
  name = rest.rstrip("/").split("/")[-1].strip()
  if name in ("", ".", "..", "~"):
    return None
  return direction, name, percent


def parse_sync_stage(message):
  """Turn the client's reconciliation log messages into concise UI status."""
  text = re.sub(r"\s+", " ", str(message or "")).strip()
  lowered = text.lower()
  if "internet connectivity to microsoft onedrive service has been interrupted" in lowered \
      or "retrying the respective microsoft graph api call" in lowered:
    return "Connection interrupted · retrying…"
  if "performing a full scan of online data to ensure consistent local state" in lowered:
    return "Preparing full reconciliation…"
  if "fetching items from the onedrive api" in lowered \
      or "fetching /delta response from the onedrive api" in lowered \
      or "generating a /delta response from the onedrive api" in lowered:
    return "Fetching cloud items…"
  processing = re.search(
    r"processing\s+([\d,]+)\s+applicable\s+(?:json\s+items|changes\s+and\s+items)\s+received\s+from\s+microsoft\s+onedrive",
    text,
    re.IGNORECASE,
  )
  if processing:
    try:
      item_count = f"{int(processing.group(1).replace(',', '')):,}"
    except ValueError:
      item_count = processing.group(1)
    return f"Processing {item_count} cloud items…"
  if "performing a database consistency and integrity check on locally stored data" in lowered:
    return "Checking local sync database…"
  if "scanning the local file system" in lowered and "for new data to upload" in lowered:
    return "Scanning local files for uploads…"
  if "performing a last examination of the most recent online data" in lowered \
      or "performing a final true-up scan of online data" in lowered:
    return "Finalizing reconciliation…"
  if "syncing changes from microsoft onedrive" in lowered:
    return "Checking cloud changes…"
  return ""


def journal_state(service, now=None):
  now = int(time.time()) if now is None else now
  exit_code, output = command_output(
    ["journalctl", "--user", "--unit", service, "--lines", "120", "--no-pager", "--output", "json"],
    timeout=5,
  )
  result = {
    "syncing": False,
    "lastSyncTs": 0,
    "lastError": "",
    "reauthRequired": False,
    "events": [],
    "transferFile": "",
    "transferDirection": "",
    "transferPercent": -1,
    "syncStage": "",
  }
  if exit_code != 0:
    return result

  last_start = 0
  last_complete = 0
  last_error = 0
  last_reauth = 0
  last_transfer_ts = 0
  last_transfer = None
  last_stage_ts = 0
  last_stage = ""
  live_start = 0
  live_done = 0
  live_progress = 0
  error_events = []
  for line in output.splitlines():
    try:
      row = json.loads(line)
    except json.JSONDecodeError:
      continue
    message = str(row.get("MESSAGE", ""))
    try:
      timestamp = int(row.get("__REALTIME_TIMESTAMP", 0)) // 1_000_000
    except (TypeError, ValueError):
      timestamp = 0
    lowered = message.lower()
    detail = ERROR_DETAIL_RE.match(message)
    if detail and error_events and timestamp - error_events[-1]["ts"] <= 5:
      merged = error_events[-1]["text"].rstrip() + " " + re.sub(r"\s+", " ", detail.group(2)).strip()
      error_events[-1]["text"] = merged[:180]
      continue
    transfer = parse_transfer(message)
    if transfer and timestamp >= last_transfer_ts:
      last_transfer_ts = timestamp
      last_transfer = transfer
    if TRANSFER_DONE_RE.match(message):
      live_done = max(live_done, timestamp)
    elif transfer:
      live_progress = max(live_progress, timestamp)
    if "new items to upload to microsoft onedrive" in lowered:
      live_start = max(live_start, timestamp)
    stage = parse_sync_stage(message)
    if stage and timestamp >= last_stage_ts:
      last_stage_ts = timestamp
      last_stage = stage
    if "starting a sync with microsoft onedrive" in lowered or "syncing changes from microsoft onedrive" in lowered:
      last_start = max(last_start, timestamp)
    if "sync with microsoft onedrive is complete" in lowered:
      last_complete = max(last_complete, timestamp)
      if timestamp > 0:
        result["events"].append({"kind": "sync", "ts": timestamp, "text": "Sync complete"})
    if any(marker in lowered for marker in ("error:", "fatal:", "sync aborted", "requires a --resync", "integrity failure")):
      cleaned_message = re.sub(r"\s+", " ", message).strip()[:180]
      if timestamp > 0:
        error_events.append({"kind": "error", "ts": timestamp, "text": cleaned_message})
    if any(marker in lowered for marker in (
      "issue a --reauth",
      "fresh auth token is needed",
      "reauthenticate this client",
    )):
      last_reauth = max(last_reauth, timestamp)

  kept_errors = [
    event for event in error_events
    if not any(marker in event["text"].lower() for marker in BENIGN_ERROR_MARKERS)
  ]
  for event in kept_errors:
    event["recovered"] = last_complete >= event["ts"]
  result["events"].extend(kept_errors)
  if kept_errors:
    newest = max(kept_errors, key=lambda event: event["ts"])
    last_error = newest["ts"]
    result["lastError"] = newest["text"]

  result["events"] = sorted(result["events"], key=lambda event: event["ts"], reverse=True)[:MAX_SERVICE_EVENTS]
  pass_syncing = last_start > last_complete
  live_evidence = max(live_start, live_progress)
  live_syncing = (
    not pass_syncing
    and live_evidence > max(live_done, last_complete)
    and now - live_evidence <= LIVE_TRANSFER_STALE_SEC
  )
  result["lastSyncTs"] = last_complete if pass_syncing else max(last_complete, live_done)
  result["syncing"] = pass_syncing or live_syncing
  result["reauthRequired"] = last_reauth > last_complete
  if last_transfer and (
    (pass_syncing and last_transfer_ts >= last_start)
    or (live_syncing and last_transfer_ts >= live_evidence)
  ):
    result["transferDirection"], result["transferFile"], result["transferPercent"] = last_transfer
  if (pass_syncing and last_stage_ts >= last_start) or (live_syncing and last_stage_ts >= live_evidence):
    result["syncStage"] = last_stage
  if last_complete >= last_error:
    result["lastError"] = ""
  return result


def scan_recent(path, limit):
  counter = 0
  recent = []
  if not path.is_dir():
    return []
  try:
    for root, directories, files in os.walk(path):
      directories[:] = [name for name in directories if not os.path.islink(os.path.join(root, name))]
      for name in files:
        file_path = os.path.join(root, name)
        if os.path.islink(file_path):
          continue
        try:
          stat = os.stat(file_path)
        except OSError:
          continue
        relative = os.path.relpath(file_path, path)
        folder = os.path.dirname(relative)
        row = {
          "name": name,
          "path": file_path,
          "folder": "/" if folder in ("", ".") else folder,
          "modifiedTs": int(stat.st_mtime),
          "sizeBytes": stat.st_size,
        }
        counter += 1
        entry = (row["modifiedTs"], counter, row)
        if len(recent) < limit:
          heapq.heappush(recent, entry)
        else:
          heapq.heappushpop(recent, entry)
  except OSError:
    return []
  return [entry[2] for entry in sorted(recent, reverse=True)]


def parse_quota(output):
  used_match = re.search(r"^Used:\s+.*?\((\d+) bytes\)\s*$", output, re.MULTILINE)
  total_match = re.search(r"^Total:\s+.*?\((\d+) bytes\)\s*$", output, re.MULTILINE)
  if not used_match or not total_match:
    return None
  return int(used_match.group(1)), int(total_match.group(1))


def parse_remote_status(output):
  lowered = output.lower()
  if "there are no pending changes" in lowered and "matches the data online" in lowered:
    return "Up to date"
  if "pending changes" in lowered or "is out of sync with microsoft onedrive" in lowered:
    return "Pending changes"
  lines = [re.sub(r"\s+", " ", line).strip() for line in output.splitlines() if line.strip()]
  return lines[-1][:120] if lines else "Could not determine"


def migrate_cloud_cache(cache):
  legacy_error = str(cache.get("remoteError", ""))
  if "quotaError" not in cache:
    cache["quotaError"] = "; ".join(
      part.strip() for part in legacy_error.split(";") if "quota" in part.lower()
    )
  if "syncStatusError" not in cache:
    cache["syncStatusError"] = "; ".join(
      part.strip() for part in legacy_error.split(";") if "quota" not in part.lower()
    )

  checked_at = int(cache.get("remoteCheckedTs", 0) or 0)
  if "quotaCheckedTs" not in cache and cache.get("quotaKnown") is True:
    cache["quotaCheckedTs"] = checked_at
  if "syncStatusCheckedTs" not in cache and (
    cache.get("remoteStatus", "Not checked") != "Not checked" or cache.get("syncStatusError")
  ):
    cache["syncStatusCheckedTs"] = checked_at


def update_cloud_compatibility(cache):
  cache["remoteCheckedTs"] = max(
    int(cache.get("quotaCheckedTs", 0) or 0),
    int(cache.get("syncStatusCheckedTs", 0) or 0),
  )
  cache["remoteError"] = "; ".join(
    error for error in (
      str(cache.get("quotaError", "")),
      str(cache.get("syncStatusError", "")),
    ) if error
  )


def apply_quota_result(cache, exit_code, output, checked_at):
  quota = parse_quota(output) if exit_code == 0 else None
  if quota:
    cache["usedBytes"], cache["quotaBytes"] = quota
    cache["quotaKnown"] = True
    cache["quotaError"] = ""
  else:
    cache["quotaError"] = "Cloud quota check timed out" \
      if exit_code == 124 else "Cloud quota check failed"
  cache["quotaCheckedTs"] = checked_at


def apply_sync_status_result(cache, exit_code, output, checked_at):
  if exit_code == 0:
    cache["remoteStatus"] = parse_remote_status(output)
    cache["syncStatusError"] = ""
  else:
    cache["syncStatusError"] = "Microsoft Graph check timed out" \
      if exit_code == 124 else "Cloud sync check failed"
  cache["syncStatusCheckedTs"] = checked_at


def cloud_check(onedrive_path, confdir, cache, check_quota, check_sync_status):
  quota_command = [onedrive_path, "--confdir", str(confdir), "--display-quota"]
  status_command = [onedrive_path, "--confdir", str(confdir), "--display-sync-status"]
  checked_at = int(time.time())
  if check_quota and check_sync_status:
    with ThreadPoolExecutor(max_workers=2) as executor:
      quota_future = executor.submit(command_output, quota_command, QUOTA_TIMEOUT_SECONDS)
      status_future = executor.submit(command_output, status_command, SYNC_STATUS_TIMEOUT_SECONDS)
      quota_result = quota_future.result()
      status_result = status_future.result()
    apply_quota_result(cache, *quota_result, checked_at)
    apply_sync_status_result(cache, *status_result, checked_at)
  elif check_quota:
    apply_quota_result(cache, *command_output(quota_command, timeout=QUOTA_TIMEOUT_SECONDS), checked_at)
  elif check_sync_status:
    apply_sync_status_result(
      cache,
      *command_output(status_command, timeout=SYNC_STATUS_TIMEOUT_SECONDS),
      checked_at,
    )
  update_cloud_compatibility(cache)


def resume_time_text(resume_at, now=None):
  current = int(time.time()) if now is None else int(now)
  seconds = max(0, int(resume_at or 0) - current)
  if seconds < 60:
    return "<1m"
  minutes = (seconds + 59) // 60
  if minutes < 60:
    return f"{minutes}m"
  hours, remaining = divmod(minutes, 60)
  return f"{hours}h" if remaining == 0 else f"{hours}h {remaining}m"


def status_text(installed, authenticated, service, journal, resume_at=0):
  if not installed:
    return "Not installed"
  if not authenticated:
    return "Login required"
  if journal["reauthRequired"]:
    return "Reauthentication required"
  if not service["serviceAvailable"]:
    return "Service unavailable"
  if service["resyncRequired"]:
    return "Resync required"
  if service["serviceFailed"] or journal["lastError"]:
    return "Attention needed"
  if service["activeState"] == "activating":
    return "Starting…"
  if not service["running"] and resume_at > int(time.time()):
    return "Paused · resumes in " + resume_time_text(resume_at)
  if not service["running"] and not service["enabled"]:
    return "Auto-start disabled"
  if not service["running"]:
    return "Sync paused"
  if journal["syncing"]:
    if journal.get("syncStage") == "Connection interrupted · retrying…":
      return journal["syncStage"]
    transfer_file = journal.get("transferFile", "")
    if transfer_file:
      text = journal.get("transferDirection", "Syncing") + " " + transfer_file
      percent = int(journal.get("transferPercent", -1) or -1)
      if 0 <= percent <= 100:
        text += " · " + str(percent) + "%"
      return text
    if journal.get("syncStage"):
      return journal["syncStage"]
    return "Syncing…"
  return "Monitoring"


def build_status(args):
  onedrive_path = shutil.which("onedrive")
  requested_confdir = getattr(args, "confdir", None)
  confdir = Path(requested_confdir) if requested_confdir else default_confdir()
  config = client_config(confdir, onedrive_path)
  sync_dir = config["syncDir"]
  authenticated = (confdir / "refresh_token").is_file()
  service = service_state(args.service)
  resume_at = resume_timer_state()
  journal = journal_state(args.service) if service["serviceAvailable"] else {
    "syncing": False,
    "lastSyncTs": 0,
    "lastError": "",
    "reauthRequired": False,
    "events": [],
    "transferFile": "",
    "transferDirection": "",
    "transferPercent": -1,
    "syncStage": "",
  }

  directory = state_dir()
  directory.mkdir(parents=True, exist_ok=True, mode=0o700)
  os.chmod(directory, 0o700)
  lock_path = directory / "status.lock"
  cache_path = directory / cache_name(confdir)
  with lock_path.open("a+", encoding="utf-8") as lock:
    os.chmod(lock_path, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX)
    cache = load_cache(cache_path)
    if cache.get("remoteStatus") == "Check failed":
      cache["remoteStatus"] = "Not checked"
    migrate_cloud_cache(cache)
    now = int(time.time())
    cached_sync_dir = str(cache.get("scanSyncDir", ""))
    cached_limit = int(cache.get("scanLimit", 0) or 0)
    scan_at = int(cache.get("scanAt", 0) or 0)
    if cached_sync_dir != str(sync_dir) or cached_limit != args.limit or now - scan_at >= SCAN_CACHE_SECONDS:
      cache["files"] = scan_recent(sync_dir, args.limit)
      cache["scanAt"] = now
      cache["scanSyncDir"] = str(sync_dir)
      cache["scanLimit"] = args.limit

    check_quota = args.remote or args.quota
    check_sync_status = args.remote or args.sync_status
    if (check_quota or check_sync_status) and onedrive_path and authenticated:
      cloud_check(onedrive_path, confdir, cache, check_quota, check_sync_status)

    save_cache(cache_path, cache)

  local_error = journal["lastError"]
  if service["resyncRequired"] and not local_error:
    local_error = "OneDrive stopped because a manual --resync is required"
  elif service["serviceFailed"] and not local_error:
    local_error = "OneDrive service failed"
  files = cache.get("files", [])
  activity = []
  for event in journal["events"]:
    if event["ts"] <= 0:
      continue
    recovered = event["kind"] == "error" and event.get("recovered") is True
    title = event["text"]
    detail = ""
    if recovered:
      lowered = title.lower()
      if "curl" in lowered or "failed sending data to the peer" in lowered:
        title = "Connection interruption — recovered"
      elif "integrity failure" in lowered:
        title = "Upload integrity failure — recovered"
      else:
        title = "Sync error — recovered"
      detail = re.sub(r"^(?:ERROR|WARNING):\s*", "", event["text"], flags=re.IGNORECASE)
    activity.append({
      "kind": event["kind"],
      "recovered": recovered,
      "ts": event["ts"],
      "title": title,
      "detail": detail,
      "path": "",
    })
  recent_files = []
  for row in files:
    modified_ts = row.get("modifiedTs", 0)
    if type(modified_ts) is not int or modified_ts <= 0:
      continue
    recent_files.append((modified_ts, row))
  recent_files = sorted(recent_files, key=lambda entry: entry[0], reverse=True)[:MAX_FILE_EVENTS]
  for modified_ts, row in recent_files:
    folder = str(row.get("folder", "/") or "/")
    activity.append({
      "kind": "file",
      "ts": modified_ts,
      "title": str(row.get("name", "") or ""),
      "detail": "changed in OneDrive" if folder == "/" else "changed in " + folder,
      "path": str(row.get("path", "") or ""),
    })
  activity = sorted(activity, key=lambda row: row["ts"], reverse=True)[:ACTIVITY_LIMIT]
  result = {
    "ok": True,
    "installed": onedrive_path is not None,
    **service,
    "authenticated": authenticated,
    "reauthRequired": journal["reauthRequired"],
    "syncing": service["running"] and journal["syncing"],
    "syncStage": journal["syncStage"] if service["running"] else "",
    "statusText": status_text(onedrive_path is not None, authenticated, service, journal, resume_at),
    "resumeAt": resume_at,
    "syncDir": str(sync_dir),
    "syncMode": config["syncMode"],
    "clientVersion": config["clientVersion"],
    "lastSyncTs": journal["lastSyncTs"],
    "usedBytes": int(cache.get("usedBytes", 0) or 0),
    "quotaBytes": int(cache.get("quotaBytes", 0) or 0),
    "quotaKnown": cache.get("quotaKnown") is True,
    "quotaCheckedTs": int(cache.get("quotaCheckedTs", 0) or 0),
    "quotaError": str(cache.get("quotaError", "")),
    "remoteStatus": str(cache.get("remoteStatus", "Not checked")),
    "syncStatusCheckedTs": int(cache.get("syncStatusCheckedTs", 0) or 0),
    "syncStatusError": str(cache.get("syncStatusError", "")),
    "remoteCheckedTs": int(cache.get("remoteCheckedTs", 0) or 0),
    "remoteError": str(cache.get("remoteError", "")),
    "files": files,
    "activity": activity,
    "lastError": local_error,
  }
  return result


def main():
  parser = argparse.ArgumentParser(description="Read OneDrive CLI state for OmaOneDrive")
  parser.add_argument("--quota", action="store_true", help="query Microsoft for cloud quota only")
  parser.add_argument("--sync-status", action="store_true", help="query Microsoft for full-drive sync status only")
  parser.add_argument("--remote", action="store_true", help="query both quota and full-drive sync status")
  parser.add_argument("--limit", type=int, default=20, help="number of recent local files")
  parser.add_argument("--service", default=DEFAULT_SERVICE, help="systemd user service name")
  parser.add_argument("--confdir", default=None, help="OneDrive config directory for this account")
  args = parser.parse_args()
  args.limit = max(5, min(50, args.limit))
  if not re.fullmatch(r"[A-Za-z0-9_.@-]+\.service", args.service):
    parser.error("invalid service name")
  if args.confdir is not None and not valid_confdir(args.confdir):
    parser.error("invalid confdir")
  print(json.dumps(build_status(args), separators=(",", ":")))


if __name__ == "__main__":
  main()
