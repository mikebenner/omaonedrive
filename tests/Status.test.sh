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
confdir=""
previous=""
for argument in "$@"; do
  [[ $previous == --confdir ]] && confdir="$argument"
  previous="$argument"
done
sync_dir="${FAKE_SYNC_DIR:?}"
if [[ -n $confdir && -f "$confdir/fake_sync_dir" ]]; then
  sync_dir=$(cat "$confdir/fake_sync_dir")
fi
case " $* " in
  *" --display-config "*)
    printf "Application version                          = onedrive v2.5.11\n"
    printf "Config option 'sync_dir'                      = %s\n" "$sync_dir"
    printf "Config option 'upload_only'                   = %s\n" "${FAKE_UPLOAD_ONLY:-false}"
    printf "Config option 'download_only'                 = %s\n" "${FAKE_DOWNLOAD_ONLY:-true}"
    ;;
  *" --display-quota "*)
    if [[ ${FAKE_QUOTA_FAILURE:-0} == 1 ]]; then
      echo "OneDrive quota query failed" >&2
      exit 8
    fi
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
unit=""
for argument in "$@"; do
  case "$argument" in
    *.service) unit="$argument" ;;
  esac
done
case " $* " in
  *" list-timers "*)
    if [[ -n ${FAKE_RESUME_AT:-} ]]; then
      printf '[{"next":%s,"unit":"omaonedrive-resume.timer"}]\n' "$((FAKE_RESUME_AT * 1000000))"
    else
      echo '[]'
    fi
    ;;
  *" list-units "*)
    if [[ ${FAKE_NO_SYSTEMD:-0} == 1 ]]; then
      exit 1
    fi
    if [[ -n ${FAKE_UNITS:-} ]]; then
      printf '%s\n' "$FAKE_UNITS"
    fi
    exit 0
    ;;
  *"--property=ExecStart"*)
    if [[ ${FAKE_NO_SYSTEMD:-0} == 1 ]]; then
      exit 1
    fi
    case "$unit" in
      onedrive.service)
        echo 'LoadState=loaded'
        echo 'Description=OneDrive Client for Linux'
        echo 'ExecStart={ path=/usr/bin/onedrive ; argv[]=/usr/bin/onedrive --monitor ; ignore_errors=no ; start_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }'
        ;;
      onedrive@personal.service)
        # confdir deliberately unrelated to the instance name, written with the
        # "--confdir=<path>" spelling.
        echo 'LoadState=loaded'
        echo 'Description=OneDrive sync (personal account)'
        echo 'ExecStart={ path=/usr/bin/onedrive ; argv[]=/usr/bin/onedrive --monitor --confdir=/srv/onedrive/mailboxes/alpha ; ignore_errors=no ; start_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }'
        ;;
      onedrive@work.service)
        # Same, with the "--confdir <path>" spelling systemd also preserves.
        echo 'LoadState=loaded'
        echo 'Description=OneDrive sync (work account)'
        echo 'ExecStart={ path=/usr/bin/onedrive ; argv[]=/usr/bin/onedrive --monitor --confdir /srv/onedrive/mailboxes/beta ; ignore_errors=no ; start_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }'
        ;;
      onedrive@ghost.service)
        echo 'LoadState=not-found'
        echo 'Description=onedrive@ghost.service'
        echo 'ExecStart='
        ;;
      *) exit 1 ;;
    esac
    exit 0
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
OUT
if [[ ${FAKE_RECOVERED_NETWORK:-0} == 1 ]]; then
  echo '{"MESSAGE":"ERROR: Encountered a std.net.curl.CurlException:","__REALTIME_TIMESTAMP":"1786787995000000"}'
  echo '{"MESSAGE":"  Error Message: Failed sending data to the peer","__REALTIME_TIMESTAMP":"1786787995000000"}'
fi
cat <<'OUT'
{"MESSAGE":"Sync with Microsoft OneDrive is complete","__REALTIME_TIMESTAMP":"1786788000000000"}
OUT
if [[ ${FAKE_INCOMPLETE_SYNC:-0} == 1 ]]; then
  echo '{"MESSAGE":"Starting a sync with Microsoft OneDrive","__REALTIME_TIMESTAMP":"1786788010000000"}'
fi
if [[ ${FAKE_TRANSFER:-0} == 1 ]]; then
  echo '{"MESSAGE":"Downloading changes from Microsoft OneDrive","__REALTIME_TIMESTAMP":"1786788011000000"}'
  echo '{"MESSAGE":"Uploading new file ./Docs/report.pdf ... done","__REALTIME_TIMESTAMP":"1786788015000000"}'
fi
if [[ ${FAKE_RECONCILIATION:-0} == 1 ]]; then
  echo '{"MESSAGE":"Performing a full scan of online data to ensure consistent local state","__REALTIME_TIMESTAMP":"1786788011000000"}'
  echo '{"MESSAGE":"Processing 71903 applicable JSON items received from Microsoft OneDrive","__REALTIME_TIMESTAMP":"1786788015000000"}'
fi
if [[ ${FAKE_REAUTH:-0} == 1 ]]; then
  echo '{"MESSAGE":"ERROR: You will need to issue a --reauth and re-authorise this client to obtain a fresh auth token.","__REALTIME_TIMESTAMP":"1786788020000000"}'
fi
if [[ ${FAKE_LIVE_UPLOAD:-0} == 1 ]]; then
  now_us=$(( $(date +%s) * 1000000 ))
  echo "{\"MESSAGE\":\"New items to upload to Microsoft OneDrive: 1\",\"__REALTIME_TIMESTAMP\":\"$(( now_us - 20000000 ))\"}"
  echo "{\"MESSAGE\":\"Uploading: Documents/all-hands recording.mp4 ... 66%  |  ETA    00:00:10\",\"__REALTIME_TIMESTAMP\":\"$(( now_us - 5000000 ))\"}"
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

FAKE_LIVE_UPLOAD=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/live-upload.json"
jq -e '
  .syncing == true
  and .statusText == "Uploading all-hands recording.mp4 · 66%"
' "$test_root/live-upload.json" >/dev/null

FAKE_RECOVERED_NETWORK=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/recovered-network.json"
jq -e '
  .lastError == ""
  and any(.activity[];
    .kind == "error"
    and .recovered == true
    and .title == "Connection interruption — recovered"
    and (.detail | contains("Failed sending data to the peer")))
' "$test_root/recovered-network.json" >/dev/null

remote_output="$test_root/remote.json"
python3 "$root/onedrive-status.py" --remote --limit 5 >"$remote_output"
jq -e '
  .quotaKnown == true
  and .usedBytes == 2000000000
  and .quotaBytes == 10000000000
  and .quotaCheckedTs > 0
  and .quotaError == ""
  and .remoteStatus == "Up to date"
  and .syncStatusCheckedTs > 0
  and .syncStatusError == ""
  and .remoteCheckedTs > 0
  and .remoteError == ""
  and .lastError == ""
' "$remote_output" >/dev/null
[[ $(grep -c -- '--display-quota' "$FAKE_ONEDRIVE_LOG") == 1 ]]
[[ $(grep -c -- '--display-sync-status' "$FAKE_ONEDRIVE_LOG") == 1 ]]

FAKE_PENDING_CHANGES=1 python3 "$root/onedrive-status.py" --sync-status --limit 5 >"$test_root/pending.json"
jq -e '
  .remoteStatus == "Pending changes"
  and .syncStatusError == ""
  and .quotaError == ""
' "$test_root/pending.json" >/dev/null

cached_output="$test_root/cached.json"
python3 "$root/onedrive-status.py" --limit 5 >"$cached_output"
jq -e '.quotaKnown == true and .remoteStatus == "Pending changes"' "$cached_output" >/dev/null
[[ $(grep -c -- '--display-quota' "$FAKE_ONEDRIVE_LOG") == 1 ]]
[[ $(grep -c -- '--display-sync-status' "$FAKE_ONEDRIVE_LOG") == 2 ]]
[[ $(stat -c '%a' "$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive") == 700 ]]
[[ $(stat -c '%a' "$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive/status-cache.json") == 600 ]]
[[ $(stat -c '%a' "$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive/status.lock") == 600 ]]

FAKE_STATUS_FAILURE=1 python3 "$root/onedrive-status.py" --sync-status --limit 5 >"$test_root/remote-failure.json"
jq -e '
  .remoteStatus == "Pending changes"
  and .syncStatusError == "Cloud sync check failed"
  and .quotaError == ""
  and .remoteError == "Cloud sync check failed"
  and .lastError == ""
  and .quotaKnown == true
' "$test_root/remote-failure.json" >/dev/null

python3 "$root/onedrive-status.py" --limit 5 >"$test_root/cached-failure.json"
jq -e '
  .remoteStatus == "Pending changes"
  and .syncStatusError == "Cloud sync check failed"
  and .quotaError == ""
  and .remoteError == "Cloud sync check failed"
  and .lastError == ""
' "$test_root/cached-failure.json" >/dev/null

python3 "$root/onedrive-status.py" --quota --limit 5 >"$test_root/quota-retry.json"
jq -e '
  .quotaError == ""
  and .syncStatusError == "Cloud sync check failed"
  and .remoteError == "Cloud sync check failed"
' "$test_root/quota-retry.json" >/dev/null

python3 "$root/onedrive-status.py" --sync-status --limit 5 >"$test_root/remote-recovered.json"
jq -e '
  .remoteStatus == "Up to date"
  and .quotaError == ""
  and .syncStatusError == ""
  and .remoteError == ""
  and .lastError == ""
' "$test_root/remote-recovered.json" >/dev/null

FAKE_QUOTA_FAILURE=1 python3 "$root/onedrive-status.py" --quota --limit 5 >"$test_root/quota-failure.json"
jq -e '
  .quotaKnown == true
  and .usedBytes == 2000000000
  and .quotaBytes == 10000000000
  and .quotaError == "Cloud quota check failed"
  and .syncStatusError == ""
  and .lastError == ""
' "$test_root/quota-failure.json" >/dev/null

python3 "$root/onedrive-status.py" --quota --limit 5 >"$test_root/quota-recovered.json"
jq -e '.quotaError == "" and .syncStatusError == "" and .remoteError == ""' \
  "$test_root/quota-recovered.json" >/dev/null

python3 - "$root/onedrive-status.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("omaonedrive_status", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
exit_code, output = module.command_output(
  [sys.executable, "-c", "import time; print('partial', flush=True); time.sleep(1)"],
  timeout=0.05,
)
assert exit_code == 124
assert output == "partial"
PY

rm "$test_home/.config/onedrive/refresh_token"
FAKE_ACTIVE=inactive python3 "$root/onedrive-status.py" --limit 5 >"$test_root/login.json"
jq -e '.authenticated == false and .running == false and .statusText == "Login required"' "$test_root/login.json" >/dev/null

touch "$test_home/.config/onedrive/refresh_token"
FAKE_ACTIVE=inactive FAKE_INCOMPLETE_SYNC=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/paused.json"
jq -e '.authenticated == true and .running == false and .syncing == false and .statusText == "Sync paused"' "$test_root/paused.json" >/dev/null

FAKE_INCOMPLETE_SYNC=1 FAKE_TRANSFER=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/transfer.json"
jq -e '.syncing == true and .statusText == "Uploading report.pdf"' "$test_root/transfer.json" >/dev/null

FAKE_INCOMPLETE_SYNC=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/syncing.json"
jq -e '.syncing == true and .statusText == "Syncing…"' "$test_root/syncing.json" >/dev/null

FAKE_INCOMPLETE_SYNC=1 FAKE_RECONCILIATION=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/reconciliation.json"
jq -e '
  .syncing == true
  and .syncStage == "Processing 71,903 cloud items…"
  and .statusText == "Processing 71,903 cloud items…"
' "$test_root/reconciliation.json" >/dev/null

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

# --- multi-account discovery -------------------------------------------------

# A loaded template ("onedrive@.service") is not an account, and a unit whose
# LoadState is not-found is a stale enablement symlink, not an account.
units=$'onedrive.service loaded active running OneDrive Client for Linux
onedrive@.service loaded active running OneDrive sync template
onedrive@ghost.service not-found inactive dead onedrive@ghost.service
onedrive@work.service loaded inactive dead OneDrive sync (work account)
onedrive@personal.service loaded active running OneDrive sync (personal account)'

log_lines_before=$(wc -l <"$FAKE_ONEDRIVE_LOG")
FAKE_UNITS="$units" python3 "$root/onedrive-status.py" --list-accounts >"$test_root/accounts.json"
jq -e --arg default_confdir "$test_home/.config/onedrive" '
  length == 3
  and .[0].service == "onedrive.service"
  and .[0].instance == ""
  and .[0].confdir == $default_confdir
  and .[0].description == "OneDrive Client for Linux"
  and .[1].service == "onedrive@personal.service"
  and .[1].instance == "personal"
  and .[1].confdir == "/srv/onedrive/mailboxes/alpha"
  and .[1].description == "OneDrive sync (personal account)"
  and .[2].service == "onedrive@work.service"
  and .[2].instance == "work"
  and .[2].confdir == "/srv/onedrive/mailboxes/beta"
  and .[2].description == "OneDrive sync (work account)"
' "$test_root/accounts.json" >/dev/null
# Discovery is pure enumeration: it must not shell out to the OneDrive client.
[[ $(wc -l <"$FAKE_ONEDRIVE_LOG") == "$log_lines_before" ]]

FAKE_NO_SYSTEMD=1 python3 "$root/onedrive-status.py" --list-accounts >"$test_root/accounts-no-systemd.json"
jq -e --arg default_confdir "$test_home/.config/onedrive" '
  length == 1
  and .[0].service == "onedrive.service"
  and .[0].instance == ""
  and .[0].confdir == $default_confdir
  and .[0].description == "OneDrive"
' "$test_root/accounts-no-systemd.json" >/dev/null

python3 "$root/onedrive-status.py" --list-accounts >"$test_root/accounts-empty.json"
jq -e --arg default_confdir "$test_home/.config/onedrive" '
  length == 1 and .[0].service == "onedrive.service" and .[0].confdir == $default_confdir
' "$test_root/accounts-empty.json" >/dev/null

# An instance that is enabled but not currently loaded never appears in
# "list-units", and "list-unit-files" never expands template instances, so
# discovery also reads the enablement symlinks.
mkdir -p "$test_home/.config/systemd/user/default.target.wants"
ln -sf "$test_home/.config/systemd/user/onedrive@.service" \
  "$test_home/.config/systemd/user/default.target.wants/onedrive@work.service"
python3 "$root/onedrive-status.py" --list-accounts >"$test_root/accounts-unloaded.json"
jq -e '
  length == 1
  and .[0].service == "onedrive@work.service"
  and .[0].instance == "work"
  and .[0].confdir == "/srv/onedrive/mailboxes/beta"
' "$test_root/accounts-unloaded.json" >/dev/null

python3 - "$root/onedrive-status.py" <<'ACCOUNTS_PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("omaonedrive_status", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

assert module.confdir_from_argv("/usr/bin/onedrive --monitor --confdir=/a/b") == "/a/b"
assert module.confdir_from_argv("/usr/bin/onedrive --monitor --confdir /a/b") == "/a/b"
assert module.confdir_from_argv("/usr/bin/onedrive --monitor") == ""
# The confdir comes out of argv[], never out of path=.
decoy = (
  "{ path=/opt/onedrive--confdir=/decoy ; "
  "argv[]=/usr/bin/onedrive --monitor --confdir=/real/mailbox ; ignore_errors=no ; }"
)
assert module.confdir_from_exec_start(decoy) == "/real/mailbox"
assert module.confdir_from_exec_start(
  "{ path=/usr/bin/onedrive ; argv[]=/usr/bin/onedrive --monitor ; ignore_errors=no ; }"
) == ""

assert module.valid_confdir("/home/user/.config/onedrive")
assert not module.valid_confdir("relative/onedrive")
assert not module.valid_confdir("/etc/../etc/onedrive")
assert not module.valid_confdir("/tmp/onedrive\n--resync")
ACCOUNTS_PY

# --- --confdir selects the account -------------------------------------------

alt_confdir="$test_home/.config/onedrive-accounts/work"
alt_sync_dir="$test_home/Work OneDrive"
mkdir -p "$alt_confdir" "$alt_sync_dir"
printf 'sync_dir = "%s"\n' "$alt_sync_dir" >"$alt_confdir/config"
printf '%s' "$alt_sync_dir" >"$alt_confdir/fake_sync_dir"

python3 "$root/onedrive-status.py" --confdir "$alt_confdir" --service onedrive@work.service --limit 5 \
  >"$test_root/alt-confdir.json"
jq -e --arg sync_dir "$alt_sync_dir" '
  .ok == true
  and .syncDir == $sync_dir
  and .authenticated == false
  and .statusText == "Login required"
' "$test_root/alt-confdir.json" >/dev/null
grep -Fq -- "--confdir $alt_confdir --display-config" "$FAKE_ONEDRIVE_LOG"
# Accounts must not share the status cache, or one account's quota leaks into
# another's panel.
state_root="$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive"
[[ -f "$state_root/status-cache.json" ]]
[[ $(find "$state_root" -maxdepth 1 -name 'status-cache-*.json' | wc -l) == 1 ]]

# The default account still reads the default directory.
python3 "$root/onedrive-status.py" --limit 5 >"$test_root/default-confdir.json"
jq -e --arg sync_dir "$sync_dir" '.syncDir == $sync_dir and .authenticated == true' \
  "$test_root/default-confdir.json" >/dev/null

for bad_confdir in 'relative/onedrive' '/etc/../etc/onedrive' "$test_home/.config/onedrive/config"; do
  if python3 "$root/onedrive-status.py" --confdir "$bad_confdir" >/dev/null 2>&1; then
    echo "invalid confdir unexpectedly passed: $bad_confdir" >&2
    exit 1
  fi
done

# Today's no-flag invocation keeps exactly the fields the QML layer reads.
python3 "$root/onedrive-status.py" --limit 5 >"$test_root/shape.json"
jq -e '
  ([keys_unsorted[]] | sort) == ([
    "ok","installed","serviceAvailable","running","enabled","activeState","subState",
    "serviceResult","serviceExitStatus","serviceFailed","resyncRequired","authenticated",
    "reauthRequired","syncing","syncStage","statusText","resumeAt","syncDir","syncMode",
    "clientVersion","lastSyncTs","usedBytes","quotaBytes","quotaKnown","quotaCheckedTs",
    "quotaError","remoteStatus","syncStatusCheckedTs","syncStatusError","remoteCheckedTs",
    "remoteError","files","activity","lastError"
  ] | sort)
' "$test_root/shape.json" >/dev/null

grep -Fq '["systemctl", "--user", "stop", "onedrive.service"]' "$root/Service.qml"
grep -Fq '["systemctl", "--user", "start", "onedrive.service"]' "$root/Service.qml"
grep -Fq '["omarchy-launch-terminal", "onedrive"]' "$root/Service.qml"
grep -Fq '["omarchy-launch-terminal", "onedrive", "--reauth"]' "$root/Service.qml"
grep -Fq '["omarchy-launch-terminal", "onedrive", "--sync", "--resync"]' "$root/Service.qml"
grep -Fq '"notify-send"' "$root/Service.qml"
grep -Fq 'retryStaleQuotaOnOpen' "$root/Panel.qml"
grep -Fq '(oneDrive.syncing ? "Syncing" : (oneDrive.active ? "Monitoring" : "Paused"))' "$root/Panel.qml"
grep -Fq 'command.push("--quota")' "$root/Service.qml"
grep -Fq 'command.push("--sync-status")' "$root/Service.qml"
grep -Fq '"--unit=" + resumeUnit' "$root/Service.qml"
grep -Fq '"--on-active=" + String(minutes) + "m"' "$root/Service.qml"
grep -Fq '"/usr/bin/systemctl", "--user", "start", "onedrive.service"' "$root/Service.qml"
# Resync may only ever run interactively through omarchy-launch-terminal (the
# CLI prompts for confirmation there); every direct or scripted mutation stays
# forbidden.
if grep -v 'omarchy-launch-terminal' "$root/Service.qml" \
  | grep -Eq 'bash.*-c|--resync|--logout|--sync([^a-z-]|$)'; then
  echo "service boundary includes an unsafe OneDrive mutation" >&2
  exit 1
fi

echo "Status tests passed (local state, timed pause, remote opt-in, cache, permissions, login, multi-account discovery, --confdir and control boundaries)"
