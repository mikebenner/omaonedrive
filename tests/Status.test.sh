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
    printf "Config option 'sync_dir'                      = %s\n" "${FAKE_SYNC_DIR:?}"
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
  *" show "*) echo loaded ;;
  *" is-active "*) echo "${FAKE_ACTIVE:-active}" ;;
  *" is-enabled "*) echo enabled ;;
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
SH

chmod +x "$fake_bin/onedrive" "$fake_bin/systemctl" "$fake_bin/journalctl"
export FAKE_ONEDRIVE_LOG="$test_root/onedrive.log"
export FAKE_SYNC_DIR="$sync_dir"
export HOME="$test_home"
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

if python3 "$root/onedrive-status.py" --service '../bad.service' >/dev/null 2>&1; then
  echo "invalid service name unexpectedly passed" >&2
  exit 1
fi

grep -Fq '["systemctl", "--user", "stop", "onedrive.service"]' "$root/Service.qml"
grep -Fq '["systemctl", "--user", "start", "onedrive.service"]' "$root/Service.qml"
grep -Fq '["omarchy-launch-terminal", "onedrive"]' "$root/Service.qml"
if grep -Eq 'bash.*-c|--resync|--logout|--sync([^a-z-]|$)' "$root/Service.qml"; then
  echo "service boundary includes an unsafe OneDrive mutation" >&2
  exit 1
fi

echo "Status tests passed (local state, remote opt-in, cache, permissions, login and control boundaries)"
