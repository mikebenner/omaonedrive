#!/usr/bin/python3
"""Journal-parsing tests pinned to real onedrive CLI message wording.

The fixture files under tests/fixtures/ hold journalctl JSON lines using the
exact message formats emitted by the CLI version named in the file. When a new
CLI version changes its wording, add a fixture for it rather than editing the
existing ones.
"""

import importlib.util
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("omaonedrive_status", root / "onedrive-status.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

BASE = 1786788000
SERVICE = {
  "serviceAvailable": True,
  "running": True,
  "enabled": True,
  "activeState": "active",
  "serviceFailed": False,
  "resyncRequired": False,
}


def journal_from_fixture(name, now=None):
  text = (root / "tests" / "fixtures" / name).read_text()
  module.command_output = lambda command, timeout=4: (0, text)
  return module.journal_state("onedrive.service", now=now)


def test_transfer_parsing():
  assert module.parse_transfer("Uploading new file ./a/b.txt ... done") == ("Uploading", "b.txt", -1)
  assert module.parse_transfer("Downloading file: ./Media/holiday video.mp4 ... 45%") == \
    ("Downloading", "holiday video.mp4", 45)
  assert module.parse_transfer("Uploading modified file ./x.md") == ("Uploading", "x.md", -1)
  assert module.parse_transfer("Downloading changes from Microsoft OneDrive") is None
  assert module.parse_transfer("Uploading differences of .") is None
  assert module.parse_transfer("Fetching items from the OneDrive API for Drive ID: abc ..") is None


def test_reconciliation_stage_parsing():
  assert module.parse_sync_stage(
    "Performing a full scan of online data to ensure consistent local state"
  ) == "Preparing full reconciliation…"
  assert module.parse_sync_stage(
    "Fetching items from the OneDrive API for Drive ID: abc .."
  ) == "Fetching cloud items…"
  assert module.parse_sync_stage(
    "Processing 71903 applicable JSON items received from Microsoft OneDrive ............"
  ) == "Processing 71,903 cloud items…"
  assert module.parse_sync_stage(
    "Processing 42 applicable changes and items received from Microsoft OneDrive"
  ) == "Processing 42 cloud items…"
  assert module.parse_sync_stage(
    "Performing a database consistency and integrity check on locally stored data ......"
  ) == "Checking local sync database…"
  assert module.parse_sync_stage(
    "Scanning the local file system '/home/user/OneDrive' for new data to upload ......"
  ) == "Scanning local files for uploads…"
  assert module.parse_sync_stage(
    "Performing a last examination of the most recent online data within Microsoft OneDrive to complete the reconciliation process"
  ) == "Finalizing reconciliation…"
  assert module.parse_sync_stage(
    "Fetching items from the OneDrive API for Drive ID: abc ...Internet connectivity to Microsoft OneDrive service has been interrupted .. re-trying in the background"
  ) == "Connection interrupted · retrying…"
  assert module.parse_sync_stage(
    "Retrying the respective Microsoft Graph API call for Internal Thread ID: abc"
  ) == "Connection interrupted · retrying…"
  assert module.parse_sync_stage("unrelated message") == ""


def test_live_reconciliation_status():
  journal = journal_from_fixture("journal-v2.5.11-reconciliation.jsonl")
  assert journal["syncing"] is True
  assert journal["syncStage"] == "Processing 71,903 cloud items…"
  assert journal["transferFile"] == ""
  assert module.status_text(True, True, SERVICE, journal) == "Processing 71,903 cloud items…"


def test_healthy_journal_with_benign_errors():
  journal = journal_from_fixture("journal-v2.5.11-healthy.jsonl")
  assert journal["syncing"] is True
  assert journal["lastSyncTs"] == BASE + 10
  assert journal["transferDirection"] == "Downloading"
  assert journal["transferFile"] == "holiday video.mp4"
  assert journal["transferPercent"] == 45
  assert journal["lastError"] == ""
  assert journal["reauthRequired"] is False
  kinds = [event["kind"] for event in journal["events"]]
  assert "error" not in kinds, "benign WebSocket/notSupported errors must not become activity rows"
  assert "sync" in kinds
  assert module.status_text(True, True, SERVICE, journal) == "Downloading holiday video.mp4 · 45%"


def test_reauth_journal_with_merged_error_details():
  journal = journal_from_fixture("journal-v2.5.11-reauth.jsonl")
  assert journal["syncing"] is True
  assert journal["reauthRequired"] is True
  assert "--reauth" in journal["lastError"]
  errors = [event for event in journal["events"] if event["kind"] == "error"]
  assert len(errors) == 2
  merged = min(errors, key=lambda event: event["ts"])
  assert "401 (Unauthorized)" in merged["text"], "detail lines must merge into the error event"
  assert module.status_text(True, True, SERVICE, journal) == "Reauthentication required"


def test_network_error_recovered_by_later_sync():
  journal = journal_from_fixture("journal-v2.5.11-network-recovery.jsonl")
  assert journal["syncing"] is True
  assert journal["syncStage"] == "Connection interrupted · retrying…"
  assert journal["lastError"] == ""
  errors = [event for event in journal["events"] if event["kind"] == "error"]
  assert len(errors) == 1
  assert errors[0]["recovered"] is True
  assert "Failed sending data to the peer" in errors[0]["text"]


def test_live_inotify_upload_shows_transfer():
  journal = journal_from_fixture("journal-v2.5.11-inotify-upload-live.jsonl", now=1787159315)
  assert journal["syncing"] is True
  assert journal["transferDirection"] == "Uploading"
  assert journal["transferFile"] == "all-hands recording.mp4"
  assert journal["transferPercent"] == 66
  assert journal["syncStage"] == "", "a finished pass's stage must not linger over a live upload"
  assert module.status_text(True, True, SERVICE, journal) == "Uploading all-hands recording.mp4 · 66%"


def test_live_inotify_upload_completion_settles():
  journal = journal_from_fixture("journal-v2.5.11-inotify-upload-done.jsonl", now=1787159330)
  assert journal["syncing"] is False
  assert journal["lastSyncTs"] == 1787159319, "a finished live upload must refresh the synced-ago meta"
  assert module.status_text(True, True, SERVICE, journal) == "Monitoring"


def test_stale_live_upload_is_not_syncing():
  journal = journal_from_fixture("journal-v2.5.11-inotify-upload-live.jsonl", now=1787159311 + 3600)
  assert journal["syncing"] is False, "an hour-old abandoned progress line must not pin the syncing state"


def test_integrity_failure_recovered_and_dbus_noise_hidden():
  journal = journal_from_fixture("journal-v2.5.11-integrity-recovery.jsonl", now=1787160180)
  assert journal["syncing"] is False
  assert journal["lastError"] == ""
  errors = [event for event in journal["events"] if event["kind"] == "error"]
  assert len(errors) == 1, "the newest kept error must be the integrity failure"
  assert errors[0]["recovered"] is True
  assert "integrity failure" in errors[0]["text"].lower()
  assert not any("d-bus" in event["text"].lower() for event in journal["events"]), \
    "the client's notification-daemon complaint is environment noise, not a sync error"
  assert module.status_text(True, True, SERVICE, journal) == "Monitoring"


def test_interruption_stage_outranks_frozen_transfer():
  journal = {
    "syncing": True,
    "syncStage": "Connection interrupted · retrying…",
    "transferFile": "board-review recording.mp4",
    "transferDirection": "Uploading",
    "transferPercent": 50,
    "reauthRequired": False,
    "lastError": "",
  }
  assert module.status_text(True, True, SERVICE, journal) == "Connection interrupted · retrying…", \
    "a live interruption must not hide behind a stale progress percentage"


def main():
  tests = [
    test_transfer_parsing,
    test_reconciliation_stage_parsing,
    test_live_reconciliation_status,
    test_healthy_journal_with_benign_errors,
    test_reauth_journal_with_merged_error_details,
    test_network_error_recovered_by_later_sync,
    test_live_inotify_upload_shows_transfer,
    test_live_inotify_upload_completion_settles,
    test_stale_live_upload_is_not_syncing,
    test_integrity_failure_recovered_and_dbus_noise_hidden,
    test_interruption_stage_outranks_frozen_transfer,
  ]
  for test in tests:
    test()
    print(f"ok - {test.__name__}")
  print("Journal tests passed (transfer and reconciliation parsing, benign-error demotion, detail merging)")


if __name__ == "__main__":
  sys.exit(main())
