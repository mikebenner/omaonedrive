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


def journal_from_fixture(name):
  text = (root / "tests" / "fixtures" / name).read_text()
  module.command_output = lambda command, timeout=4: (0, text)
  return module.journal_state("onedrive.service")


def test_transfer_parsing():
  assert module.parse_transfer("Uploading new file ./a/b.txt ... done") == ("Uploading", "b.txt", -1)
  assert module.parse_transfer("Downloading file: ./Media/holiday video.mp4 ... 45%") == \
    ("Downloading", "holiday video.mp4", 45)
  assert module.parse_transfer("Uploading modified file ./x.md") == ("Uploading", "x.md", -1)
  assert module.parse_transfer("Downloading changes from Microsoft OneDrive") is None
  assert module.parse_transfer("Uploading differences of .") is None
  assert module.parse_transfer("Fetching items from the OneDrive API for Drive ID: abc ..") is None


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


def main():
  tests = [
    test_transfer_parsing,
    test_healthy_journal_with_benign_errors,
    test_reauth_journal_with_merged_error_details,
  ]
  for test in tests:
    test()
    print(f"ok - {test.__name__}")
  print("Journal tests passed (transfer parsing, benign-error demotion, detail merging)")


if __name__ == "__main__":
  sys.exit(main())
