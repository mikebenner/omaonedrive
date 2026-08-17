#!/bin/bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fake_bin="$test_root/bin"
test_home="$test_root/home"
sync_dir="$test_home/My OneDrive"
mkdir -p "$fake_bin" "$test_home/.config/onedrive" "$sync_dir/Docs" "$sync_dir/Photos"
printf 'sync_dir = "%s"\n' "$sync_dir" >"$test_home/.config/onedrive/config"
touch "$test_home/.config/onedrive/refresh_token"
printf 'report' >"$sync_dir/Docs/report.pdf"
printf 'photo' >"$sync_dir/Photos/photo.jpg"
touch -d '2026-08-14 10:00:00 UTC' "$sync_dir/Docs/report.pdf"
touch -d '2026-08-15 10:00:00 UTC' "$sync_dir/Photos/photo.jpg"

cat >"$fake_bin/onedrive" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_ONEDRIVE_LOG:?}"
case " $* " in
  *" --display-config "*)
    printf "Application version                          = onedrive v2.5.11\n"
    printf "Config option 'sync_dir'                      = %s\n" "${FAKE_SYNC_DIR:?}"
    printf "Config option 'upload_only'                   = %s\n" "${FAKE_UPLOAD_ONLY:-false}"
    printf "Config option 'download_only'                 = %s\n" "${FAKE_DOWNLOAD_ONLY:-true}"
    ;;
  *" --display-quota "*)
    cat <<'OUT'
Remaining: 8.00 GB (8000000000 bytes)
State:     normal
Total:     10.00 GB (10000000000 bytes)
Used:      2.00 GB (2000000000 bytes)
OUT
    ;;
  *" --display-sync-status "*)
    if [[ ${FAKE_STATUS_FAILURE:-0} == 1 ]]; then
      echo "OneDrive status query failed" >&2
      exit 9
    elif [[ ${FAKE_PENDING_CHANGES:-0} == 1 ]]; then
      cat <<'OUT'
The configured local 'sync_dir' directory is out of sync with Microsoft OneDrive
Approximate data to download from Microsoft OneDrive: 1124 KB
OUT
    else
      echo "There are no pending changes from Microsoft OneDrive; your local directory matches the data online."
    fi
    ;;
  *) exit 2 ;;
esac
SH

cat >"$fake_bin/systemctl" <<'SH'
#!/bin/bash
case " $* " in
  *" list-timers "*)
    if [[ -n ${FAKE_RESUME_AT:-} ]]; then
      printf '[{"next":%s,"unit":"omaonedrive-resume.timer"}]\n' "$((FAKE_RESUME_AT * 1000000))"
    else
      echo '[]'
    fi
    ;;
  *" show "*)
    active=${FAKE_ACTIVE:-active}
    sub_state=dead
    [[ $active == active ]] && sub_state=running
    cat <<OUT
LoadState=loaded
ActiveState=$active
SubState=$sub_state
UnitFileState=${FAKE_ENABLED:-enabled}
Result=${FAKE_RESULT:-success}
ExecMainCode=exited
ExecMainStatus=${FAKE_EXIT_STATUS:-0}
OUT
    ;;
  *) exit 1 ;;
esac
SH

cat >"$fake_bin/journalctl" <<'SH'
#!/bin/bash
cat <<'OUT'
{"MESSAGE":"Starting a sync with Microsoft OneDrive","__REALTIME_TIMESTAMP":"1786787990000000"}
{"MESSAGE":"Sync with Microsoft OneDrive is complete","__REALTIME_TIMESTAMP":"1786788000000000"}
OUT
if [[ ${FAKE_INCOMPLETE_SYNC:-0} == 1 ]]; then
  echo '{"MESSAGE":"Starting a sync with Microsoft OneDrive","__REALTIME_TIMESTAMP":"1786788010000000"}'
fi
if [[ ${FAKE_REAUTH:-0} == 1 ]]; then
  echo '{"MESSAGE":"ERROR: You will need to issue a --reauth and re-authorise this client to obtain a fresh auth token.","__REALTIME_TIMESTAMP":"1786788020000000"}'
fi
SH

chmod +x "$fake_bin/onedrive" "$fake_bin/systemctl" "$fake_bin/journalctl"
export FAKE_ONEDRIVE_LOG="$test_root/onedrive.log"
export FAKE_SYNC_DIR="$sync_dir"
export HOME="$test_home"
export XDG_CONFIG_HOME="$test_home/.config"
export XDG_STATE_HOME="$test_root/state"
export PATH="$fake_bin:$PATH"

local_output="$test_root/local.json"
python3 "$root/onedrive-status.py" --limit 5 >"$local_output"
jq -e --arg sync_dir "$sync_dir" '
  .ok == true
  and .installed == true
  and .serviceAvailable == true
  and .running == true
  and .enabled == true
  and .authenticated == true
  and .syncing == false
  and .statusText == "Monitoring"
  and .syncDir == $sync_dir
  and .syncMode == "Download only"
  and .clientVersion == "onedrive v2.5.11"
  and .serviceFailed == false
  and .resyncRequired == false
  and .reauthRequired == false
  and .lastSyncTs == 1786788000
  and .quotaKnown == false
  and .remoteStatus == "Not checked"
  and (.files | length) == 2
  and .files[0].name == "photo.jpg"
  and (.activity | type) == "array"
  and ((.activity | length) > 0)
  and any(.activity[]; .kind == "sync" and .title == "Sync complete")
  and ([.activity[].ts] == ([.activity[].ts] | sort | reverse))
  and all(.activity[] | select(.kind == "file"); .detail | startswith("changed in"))
  and all(.activity[]; ((.title + " " + .detail) | ascii_downcase | test("uploaded|downloaded") | not))
' "$local_output" >/dev/null
[[ $(grep -c -- '--display-config' "$FAKE_ONEDRIVE_LOG") == 1 ]]
if grep -q -- '--display-quota\|--display-sync-status' "$FAKE_ONEDRIVE_LOG"; then
  echo "local refresh unexpectedly contacted OneDrive" >&2
  exit 1
fi

remote_output="$test_root/remote.json"
python3 "$root/onedrive-status.py" --remote --limit 5 >"$remote_output"
jq -e '
  .quotaKnown == true
  and .usedBytes == 2000000000
  and .quotaBytes == 10000000000
  and .remoteStatus == "Up to date"
  and .remoteCheckedTs > 0
' "$remote_output" >/dev/null
[[ $(grep -c -- '--display-quota' "$FAKE_ONEDRIVE_LOG") == 1 ]]
[[ $(grep -c -- '--display-sync-status' "$FAKE_ONEDRIVE_LOG") == 1 ]]

FAKE_PENDING_CHANGES=1 python3 "$root/onedrive-status.py" --remote --limit 5 >"$test_root/pending.json"
jq -e '.remoteStatus == "Pending changes"' "$test_root/pending.json" >/dev/null

cached_output="$test_root/cached.json"
python3 "$root/onedrive-status.py" --limit 5 >"$cached_output"
jq -e '.quotaKnown == true and .remoteStatus == "Pending changes"' "$cached_output" >/dev/null
[[ $(grep -c -- '--display-quota' "$FAKE_ONEDRIVE_LOG") == 2 ]]
[[ $(grep -c -- '--display-sync-status' "$FAKE_ONEDRIVE_LOG") == 2 ]]
[[ $(stat -c '%a' "$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive") == 700 ]]
[[ $(stat -c '%a' "$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive/status-cache.json") == 600 ]]
[[ $(stat -c '%a' "$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive/status.lock") == 600 ]]

FAKE_STATUS_FAILURE=1 python3 "$root/onedrive-status.py" --remote --limit 5 >"$test_root/remote-failure.json"
jq -e '
  .remoteStatus == "Check failed"
  and .lastError == "Cloud sync check failed"
  and .quotaKnown == true
' "$test_root/remote-failure.json" >/dev/null

rm "$test_home/.config/onedrive/refresh_token"
FAKE_ACTIVE=inactive python3 "$root/onedrive-status.py" --limit 5 >"$test_root/login.json"
jq -e '.authenticated == false and .running == false and .statusText == "Login required"' "$test_root/login.json" >/dev/null

touch "$test_home/.config/onedrive/refresh_token"
FAKE_ACTIVE=inactive FAKE_INCOMPLETE_SYNC=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/paused.json"
jq -e '.authenticated == true and .running == false and .syncing == false and .statusText == "Sync paused"' "$test_root/paused.json" >/dev/null

resume_at=$(($(date +%s) + 3600))
FAKE_ACTIVE=inactive FAKE_RESUME_AT="$resume_at" python3 "$root/onedrive-status.py" --limit 5 >"$test_root/timed-pause.json"
jq -e --argjson resume_at "$resume_at" '
  .running == false
  and .resumeAt == $resume_at
  and (.statusText | startswith("Paused · resumes in "))
' "$test_root/timed-pause.json" >/dev/null

FAKE_ACTIVE=inactive FAKE_ENABLED=disabled python3 "$root/onedrive-status.py" --limit 5 >"$test_root/disabled.json"
jq -e '.enabled == false and .serviceFailed == false and .statusText == "Auto-start disabled"' "$test_root/disabled.json" >/dev/null

FAKE_ACTIVE=activating python3 "$root/onedrive-status.py" --limit 5 >"$test_root/starting.json"
jq -e '.activeState == "activating" and .running == false and .statusText == "Starting…"' "$test_root/starting.json" >/dev/null

FAKE_ACTIVE=failed FAKE_RESULT=exit-code FAKE_EXIT_STATUS=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/failed.json"
jq -e '.serviceFailed == true and .resyncRequired == false and .statusText == "Attention needed"' "$test_root/failed.json" >/dev/null

FAKE_ACTIVE=failed FAKE_RESULT=exit-code FAKE_EXIT_STATUS=126 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/resync.json"
jq -e '
  .serviceFailed == true
  and .resyncRequired == true
  and .serviceExitStatus == 126
  and .statusText == "Resync required"
  and (.lastError | contains("manual --resync"))
' "$test_root/resync.json" >/dev/null

FAKE_REAUTH=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/reauth.json"
jq -e '
  .authenticated == true
  and .reauthRequired == true
  and .statusText == "Reauthentication required"
' "$test_root/reauth.json" >/dev/null

FAKE_DOWNLOAD_ONLY=false FAKE_UPLOAD_ONLY=true python3 "$root/onedrive-status.py" --limit 5 >"$test_root/upload-only.json"
jq -e '.syncMode == "Upload only"' "$test_root/upload-only.json" >/dev/null

FAKE_DOWNLOAD_ONLY=false FAKE_UPLOAD_ONLY=false python3 "$root/onedrive-status.py" --limit 5 >"$test_root/two-way.json"
jq -e '.syncMode == "Two-way"' "$test_root/two-way.json" >/dev/null

if python3 "$root/onedrive-status.py" --service '../bad.service' >/dev/null 2>&1; then
  echo "invalid service name unexpectedly passed" >&2
  exit 1
fi

grep -Fq '["systemctl", "--user", "stop", "onedrive.service"]' "$root/Service.qml"
grep -Fq '["systemctl", "--user", "start", "onedrive.service"]' "$root/Service.qml"
grep -Fq '["omarchy-launch-terminal", "onedrive"]' "$root/Service.qml"
grep -Fq '["omarchy-launch-terminal", "onedrive", "--reauth"]' "$root/Service.qml"
grep -Fq '"--unit=" + resumeUnit' "$root/Service.qml"
grep -Fq '"--on-active=" + String(minutes) + "m"' "$root/Service.qml"
grep -Fq '"/usr/bin/systemctl", "--user", "start", "onedrive.service"' "$root/Service.qml"
if grep -Eq 'bash.*-c|--resync|--logout|--sync([^a-z-]|$)' "$root/Service.qml"; then
  echo "service boundary includes an unsafe OneDrive mutation" >&2
  exit 1
fi

echo "Status tests passed (local state, timed pause, remote opt-in, cache, permissions, login and control boundaries)"
