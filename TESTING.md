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

1. CLI missing: missing-client badge and explicit installation message.
2. CLI present but token missing: login badge and action opens a terminal.
3. Authenticated service stopped: paused badge and resume control.
4. Authenticated service running: quiet monitoring dot or pulsing syncing badge
   plus the pause control.
5. Explicit cloud check: storage meter, pending-change result, and cached check
   time; unknown quota remains a clearly actionable state.
6. Full layout: storage, bounded activity timeline, cloud/folder chips, and
   clickable local-file activity rows.
7. Compact layout: storage plus cloud and folder actions without the activity
   timeline.
8. Sync folder and activity file rows open through the desktop session.
9. Clean shell restart: no QML syntax, type, loader, or reference errors.
10. Horizontal and vertical bar positions plus a light and dark Omarchy theme.
11. Bar icon states: missing, login, paused, syncing, and monitoring each render
    distinctly.
12. `panelStyle` Full and Compact both render without clipping.

Real Microsoft authentication should use a disposable test account. The
2026-08-15 VM run additionally qualified interactive OAuth, real quota and
pending-status responses, initial download, hash-verified upload/download,
monitor upload, scoped remote deletion and reconciliation, pause/resume, and
enabled-service recovery after reboot. See
[the VM test report](docs/VM-TEST-REPORT.md) for its isolation and remaining
qualification boundaries.
