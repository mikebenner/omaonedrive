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
from pathlib import Path


PLUGIN_ID = "io.github.salemsayed.omaonedrive"
DEFAULT_SERVICE = "onedrive.service"
SCAN_CACHE_SECONDS = 120


def command_output(command, timeout=4):
  try:
    completed = subprocess.run(
      command,
      check=False,
      capture_output=True,
      text=True,
      timeout=timeout,
    )
  except (OSError, subprocess.TimeoutExpired):
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


def config_sync_dir(confdir, onedrive_path):
  if onedrive_path:
    exit_code, output = command_output(
      [onedrive_path, "--confdir", str(confdir), "--display-config"],
      timeout=6,
    )
    if exit_code == 0:
      match = re.search(r"Config option 'sync_dir'\s*=\s*(.+)$", output, re.MULTILINE)
      if match:
        return Path(os.path.expandvars(os.path.expanduser(match.group(1).strip().strip('"'))))

  config_path = confdir / "config"
  try:
    for line in config_path.read_text(encoding="utf-8").splitlines():
      match = re.match(r"\s*sync_dir\s*=\s*(.+?)\s*$", line)
      if not match:
        continue
      value = match.group(1).split("#", 1)[0].strip().strip('"')
      if value:
        return Path(os.path.expandvars(os.path.expanduser(value)))
  except OSError:
    pass
  return Path.home() / "OneDrive"


def systemctl_value(arguments):
  return command_output(["systemctl", "--user", *arguments], timeout=4)


def service_state(service):
  _, load_state = systemctl_value(["show", service, "--property=LoadState", "--value"])
  _, active_state = systemctl_value(["is-active", service])
  _, enabled_state = systemctl_value(["is-enabled", service])
  return {
    "serviceAvailable": load_state.strip() == "loaded",
    "running": active_state.strip() == "active",
    "enabled": enabled_state.strip() == "enabled",
  }


def journal_state(service):
  exit_code, output = command_output(
    ["journalctl", "--user", "--unit", service, "--lines", "120", "--no-pager", "--output", "json"],
    timeout=5,
  )
  result = {"syncing": False, "lastSyncTs": 0, "lastError": ""}
  if exit_code != 0:
    return result

  last_start = 0
  last_complete = 0
  last_error = 0
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
    if any(marker in lowered for marker in ("error:", "fatal:", "sync aborted", "requires a --resync")):
      if timestamp >= last_error:
        last_error = timestamp
        result["lastError"] = re.sub(r"\s+", " ", message).strip()[:180]

  result["lastSyncTs"] = last_complete
  result["syncing"] = last_start > last_complete
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
  if "pending changes" in lowered:
    return "Pending changes"
  lines = [re.sub(r"\s+", " ", line).strip() for line in output.splitlines() if line.strip()]
  return lines[-1][:120] if lines else "Could not determine"


def remote_check(onedrive_path, confdir, cache):
  errors = []
  quota_exit, quota_output = command_output(
    [onedrive_path, "--confdir", str(confdir), "--display-quota"],
    timeout=20,
  )
  quota = parse_quota(quota_output) if quota_exit == 0 else None
  if quota:
    cache["usedBytes"], cache["quotaBytes"] = quota
    cache["quotaKnown"] = True
  else:
    errors.append("Cloud quota check failed")

  status_exit, status_output = command_output(
    [onedrive_path, "--confdir", str(confdir), "--display-sync-status"],
    timeout=30,
  )
  if status_exit == 0:
    cache["remoteStatus"] = parse_remote_status(status_output)
  else:
    errors.append("Cloud sync check failed")

  cache["remoteCheckedTs"] = int(time.time())
  cache["remoteError"] = "; ".join(errors)


def status_text(installed, authenticated, running, journal):
  if not installed:
    return "Not installed"
  if not authenticated:
    return "Login required"
  if not running:
    return "Sync paused"
  if journal["lastError"]:
    return "Attention needed"
  if journal["syncing"]:
    return "Syncing…"
  return "Monitoring"


def build_status(args):
  onedrive_path = shutil.which("onedrive")
  confdir = default_confdir()
  sync_dir = config_sync_dir(confdir, onedrive_path)
  authenticated = (confdir / "refresh_token").is_file()
  service = service_state(args.service)
  journal = journal_state(args.service) if service["serviceAvailable"] else {
    "syncing": False,
    "lastSyncTs": 0,
    "lastError": "",
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

  remote_error = str(cache.get("remoteError", ""))
  local_error = journal["lastError"]
  result = {
    "ok": True,
    "installed": onedrive_path is not None,
    **service,
    "authenticated": authenticated,
    "syncing": journal["syncing"],
    "statusText": status_text(onedrive_path is not None, authenticated, service["running"], journal),
    "syncDir": str(sync_dir),
    "lastSyncTs": journal["lastSyncTs"],
    "usedBytes": int(cache.get("usedBytes", 0) or 0),
    "quotaBytes": int(cache.get("quotaBytes", 0) or 0),
    "quotaKnown": cache.get("quotaKnown") is True,
    "remoteStatus": str(cache.get("remoteStatus", "Not checked")),
    "remoteCheckedTs": int(cache.get("remoteCheckedTs", 0) or 0),
    "files": cache.get("files", []),
    "lastError": local_error or remote_error,
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
