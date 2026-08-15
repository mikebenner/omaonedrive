# OmaOneDrive VM test report

Test date: 2026-08-15 (`Africa/Cairo`)

## Environment and isolation

- Omarchy package: `4.0.0rc2-1`.
- Guest kernel: `7.1.8-arch1-3`.
- Installed OneDrive Client for Linux: `onedrive v2.5.11`, built from the
  `onedrive-abraunegg` AUR package inside the guest.
- QEMU/KVM guest with 8 vCPUs, 6144 MiB RAM, OVMF, and a fresh QCOW2 overlay on
  the previously qualified Omarchy RC2 test image.
- No host block device or physical Omarchy partition was attached. SSH was
  forwarded only to `127.0.0.1:2222`.

The real OneDrive package and systemd user unit were installed in the guest.
Microsoft authentication and cloud data transfer were deliberately not run
with a personal account. Authentication used an empty token-presence fixture;
cloud quota/status output used the fake CLI already exercised by the automated
suite. Service control used a guest-only drop-in whose `ExecStart` was
`/usr/bin/sleep infinity`, allowing real `systemctl --user start/stop` testing
without starting an unauthenticated sync client.

## Results

### Source and installation

- Python compilation, JSON parsing, ShellCheck, JavaScript tests, helper tests,
  `qmllint`, and `omarchy plugin validate` completed successfully in the VM.
- The source installed through the real local-Git
  `omarchy plugin add file://... --enable --yes` path.
- Dirty-checkout protection was observed: `omarchy plugin update` refused a
  deliberately edited installed checkout. The supported remove/add rollback
  path restored a clean checkout, and the final update fast-forwarded cleanly.
- The final source and installed Git revisions matched, both worktrees were
  clean, the manifest appeared once in the bar layout, and the plugin was
  enabled as a third-party `bar-widget`.
- A final byte-for-byte hash over the ten runtime and test files matched
  between this repository and the installed guest checkout:
  `069983158b7b893c5b48ae74618a40ee507e366f29fd5d91e67474e859a40922`.

### Functional states and controls

- With the real CLI installed and no token fixture, IPC returned `Login
  required`; the panel rendered the terminal login action and configured sync
  directory.
- With token presence simulated and the service stopped, the panel rendered
  `Sync paused`, the off toggle, cached quota/status, and two recent local
  files.
- IPC `resume`, `pause`, and `resume` drove the actual systemd user unit through
  active → inactive → active. The final panel returned `Monitoring` and showed
  the on toggle.
- The opt-in cloud helper parsed `42 GB of 100 GB`, `Up to date`, and a check
  timestamp from the fake CLI. Routine local refreshes retained the cache
  without re-running cloud commands.
- IPC `folder` launched Nautilus in the live Wayland session. The client count
  changed from zero to one.
- State permissions were `0700` for the directory and `0600` for both cache and
  lock files.

### Presentation and shell health

- Login, paused, and running panels rendered at 1280×800 without clipping.
- A left-side vertical bar re-anchored the full panel inside the screen; the bar
  widget remained a compact icon.
- The panel rendered with the Aether light palette and Tokyo Night dark palette
  through native Omarchy theme tokens.
- A final clean `omarchy-restart-shell` produced no OmaOneDrive QML loader,
  syntax, type, reference, binding-assignment, or runtime errors in the user
  journal.
- The guest was powered off cleanly. `qemu-img check` then reported no errors
  in the disposable overlay.

Ignored local evidence files include:

- `.vm/omaonedrive-login-5.png`
- `.vm/omaonedrive-paused.png`
- `.vm/omaonedrive-running.png`
- `.vm/omaonedrive-vertical.png`
- `.vm/omaonedrive-tokyo-night-2.png`
- `.vm/omaonedrive-final.png`

## Qualification boundary

The VM run qualifies plugin installation, shell loading, status modeling,
local file discovery, cache safety, systemd controls, file-manager launch,
layout, and theme behavior. It does not qualify a real Microsoft OAuth login,
tenant consent policy, real quota values, pending-change responses from
Microsoft Graph, upload/download correctness, or long-running sync behavior.
Those require a disposable Microsoft test account or the user's authenticated
physical Omarchy session.
