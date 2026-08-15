# Verification guide

The completed disposable-VM results are recorded in
[the VM test report](docs/VM-TEST-REPORT.md).

## Automated checks

```bash
python3 -m py_compile onedrive-status.py
python3 -m json.tool manifest.json >/dev/null
shellcheck tests/run tests/Status.test.sh
tests/run
omarchy plugin validate .
/usr/lib/qt6/bin/qmllint -I ~/.cache/omarchy-shell-ref *.qml
```

`tests/run` covers JavaScript presentation helpers plus a fake OneDrive CLI,
systemd user service, journal, authentication state, local files, remote quota,
remote sync status, cache reuse, and private state permissions. The fake test
also proves that a routine refresh does not run either cloud query.

## Disposable VM acceptance

Use an Omarchy Quattro VM with no host block device attached. Install the real
plugin checkout, then verify:

```bash
omarchy plugin validate .
omarchy plugin add file://$HOME/Coding/omarchy-onedrive --enable --yes
omarchy bar move io.github.salemsayed.omaonedrive --section right --index 0
omarchy plugin list --json | jq
omarchy-shell io.github.salemsayed.omaonedrive status
journalctl --user -u omarchy-shell -n 200 --no-pager
```

The functional matrix is:

1. CLI missing: dim bar icon and explicit installation message.
2. CLI present but token missing: login action opens a terminal.
3. Authenticated service stopped: paused state and resume control.
4. Authenticated service running: monitoring/syncing state and pause control.
5. Explicit cloud check: quota, pending-change result, and cached check time.
6. Sync folder and file rows open through the desktop session.
7. Clean shell restart: no QML syntax, type, loader, or reference errors.
8. Horizontal and vertical bar positions plus a light and dark Omarchy theme.

Real Microsoft authentication should use a disposable test account. Mocked VM
coverage qualifies the UI and command boundary, but not Microsoft account
policy, tenant consent, long-running API availability, or data transfer.
