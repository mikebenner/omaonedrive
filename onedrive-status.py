#!/usr/bin/python3

import argparse
import fcntl
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


def journal_state(service):
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
  }
  if exit_code != 0:
    return result

  last_start = 0
  last_complete = 0
  last_error = 0
  last_reauth = 0
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
    if "starting a sync with microsoft onedrive" in lowered or "syncing changes from microsoft onedrive" in lowered:
      last_start = max(last_start, timestamp)
    if "sync with microsoft onedrive is complete" in lowered:
      last_complete = max(last_complete, timestamp)
      if timestamp > 0:
        result["events"].append({"kind": "sync", "ts": timestamp, "text": "Sync complete"})
    if any(marker in lowered for marker in ("error:", "fatal:", "sync aborted", "requires a --resync")):
      cleaned_message = re.sub(r"\s+", " ", message).strip()[:180]
      if timestamp > 0:
        result["events"].append({"kind": "error", "ts": timestamp, "text": cleaned_message})
      if timestamp >= last_error:
        last_error = timestamp
        result["lastError"] = cleaned_message
    if any(marker in lowered for marker in (
      "issue a --reauth",
      "fresh auth token is needed",
      "reauthenticate this client",
    )):
      last_reauth = max(last_reauth, timestamp)

  result["events"] = sorted(result["events"], key=lambda event: event["ts"], reverse=True)[:MAX_SERVICE_EVENTS]
  result["lastSyncTs"] = last_complete
  result["syncing"] = last_start > last_complete
  result["reauthRequired"] = last_reauth > last_complete
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


def remote_check(onedrive_path, confdir, cache):
  errors = []
  quota_command = [onedrive_path, "--confdir", str(confdir), "--display-quota"]
  status_command = [onedrive_path, "--confdir", str(confdir), "--display-sync-status"]
  with ThreadPoolExecutor(max_workers=2) as executor:
    quota_future = executor.submit(command_output, quota_command, 20)
    status_future = executor.submit(command_output, status_command, 30)
    quota_exit, quota_output = quota_future.result()
    status_exit, status_output = status_future.result()

  quota = parse_quota(quota_output) if quota_exit == 0 else None
  if quota:
    cache["usedBytes"], cache["quotaBytes"] = quota
    cache["quotaKnown"] = True
  else:
    errors.append("Cloud quota check timed out" if quota_exit == 124 else "Cloud quota check failed")

  if status_exit == 0:
    cache["remoteStatus"] = parse_remote_status(status_output)
  else:
    errors.append("Microsoft Graph check timed out" if status_exit == 124 else "Cloud sync check failed")

  cache["remoteCheckedTs"] = int(time.time())
  cache["remoteError"] = "; ".join(errors)


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
    return "Syncing…"
  return "Monitoring"


def build_status(args):
  onedrive_path = shutil.which("onedrive")
  confdir = default_confdir()
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
  }

  directory = state_dir()
  directory.mkdir(parents=True, exist_ok=True, mode=0o700)
  os.chmod(directory, 0o700)
  lock_path = directory / "status.lock"
  cache_path = directory / "status-cache.json"
  with lock_path.open("a+", encoding="utf-8") as lock:
    os.chmod(lock_path, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX)
    cache = load_cache(cache_path)
    if cache.get("remoteStatus") == "Check failed":
      cache["remoteStatus"] = "Not checked"
    now = int(time.time())
    cached_sync_dir = str(cache.get("scanSyncDir", ""))
    cached_limit = int(cache.get("scanLimit", 0) or 0)
    scan_at = int(cache.get("scanAt", 0) or 0)
    if cached_sync_dir != str(sync_dir) or cached_limit != args.limit or now - scan_at >= SCAN_CACHE_SECONDS:
      cache["files"] = scan_recent(sync_dir, args.limit)
      cache["scanAt"] = now
      cache["scanSyncDir"] = str(sync_dir)
      cache["scanLimit"] = args.limit

    if args.remote and onedrive_path and authenticated:
      remote_check(onedrive_path, confdir, cache)

    save_cache(cache_path, cache)

  local_error = journal["lastError"]
  if service["resyncRequired"] and not local_error:
    local_error = "OneDrive stopped because a manual --resync is required"
  elif service["serviceFailed"] and not local_error:
    local_error = "OneDrive service failed"
  files = cache.get("files", [])
  activity = [
    {
      "kind": event["kind"],
      "ts": event["ts"],
      "title": event["text"],
      "detail": "",
      "path": "",
    }
    for event in journal["events"]
    if event["ts"] > 0
  ]
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
    "statusText": status_text(onedrive_path is not None, authenticated, service, journal, resume_at),
    "resumeAt": resume_at,
    "syncDir": str(sync_dir),
    "syncMode": config["syncMode"],
    "clientVersion": config["clientVersion"],
    "lastSyncTs": journal["lastSyncTs"],
    "usedBytes": int(cache.get("usedBytes", 0) or 0),
    "quotaBytes": int(cache.get("quotaBytes", 0) or 0),
    "quotaKnown": cache.get("quotaKnown") is True,
    "remoteStatus": str(cache.get("remoteStatus", "Not checked")),
    "remoteCheckedTs": int(cache.get("remoteCheckedTs", 0) or 0),
    "remoteError": str(cache.get("remoteError", "")),
    "files": files,
    "activity": activity,
    "lastError": local_error,
  }
  return result


def main():
  parser = argparse.ArgumentParser(description="Read OneDrive CLI state for OmaOneDrive")
  parser.add_argument("--remote", action="store_true", help="also query Microsoft for quota and pending changes")
  parser.add_argument("--limit", type=int, default=20, help="number of recent local files")
  parser.add_argument("--service", default=DEFAULT_SERVICE, help="systemd user service name")
  args = parser.parse_args()
  args.limit = max(5, min(50, args.limit))
  if not re.fullmatch(r"[A-Za-z0-9_.@-]+\.service", args.service):
    parser.error("invalid service name")
  print(json.dumps(build_status(args), separators=(",", ":")))


if __name__ == "__main__":
  main()
