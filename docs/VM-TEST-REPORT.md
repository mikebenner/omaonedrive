# OmaOneDrive VM test report

## Omarchy 4.0.1 compatibility rerun

Test date: 2026-08-31 (`Africa/Cairo`)

OmaOneDrive 1.5.6 was retested in its own disposable QEMU/KVM overlay after
installing the official `omarchy 4.0.1-1` and `omarchy-settings 4.0.1-1`
packages. The installed `omarchy-notification-send` checksum matched the
script at Omarchy tag `v4.0.1` (`13f18b2cb7286fb54f87daf571a031aa6af3d8f0`).

- The complete JavaScript, Python, and shell suite passed in the guest.
- The exact 4.0.1 plugin validator accepted the source and installed trees.
- `qmllint` returned success against `/usr/share/omarchy/shell`.
- All 22 direct `Text` surfaces and three inherited section headers explicitly
  used `Text.PlainText`; the static regression and live shell load both passed
  with markup-shaped filenames and helper output treated as literal text.
- Helper status strings are also neutralized before entering Omarchy 4.0.1's
  inherited `BarIconButton` tooltip and `PanelHero` metadata renderers; a
  markup-shaped synthetic filename remained literal in both model paths.
- A local Git source installed and enabled through `omarchy plugin add`; its
  status and open IPC methods responded after discovery and after a shell
  restart, with no OmaOneDrive runtime errors in the shell log.
- The exact 4.0.1 notification helper accepted the model's corrected layout:
  title and body first, then `--exec` and separate `omarchy-shell` arguments.
  The shell persisted that exact argv vector, retained it across a restart,
  and the plugin's target accepted the matching open call.
- No user-interface pixels changed in 1.5.6, so this compatibility-only run did
  not replace the already-sanitized visuals. The new presentation-boundary
  guards only change how markup-shaped untrusted strings are interpreted.

The rerun qualifies the 4.0.1 plugin, IPC, and notification contracts. The
real-account and transfer qualification below remains the broader data-path
run; it was not repeated for this command-order correction.

Test date: 2026-08-15 (`Africa/Cairo`)

This report covers two runs against the same disposable guest on 2026-08-15.
The presentation and shell-integration matrix, with evidence under
`.vm/shots-redesign-2026-08-15/`, came from a deterministic fixture harness: a
fake CLI, an empty token-presence fixture, and a `sleep infinity` service
drop-in. The live-account sections below, with evidence under
`.vm/shots-live-2026-08-15/`, ran with no fixture active, in the environment
described next.

## Environment and isolation

- Omarchy package: `4.0.0rc2-1`.
- Guest kernel: `7.1.8-arch1-3`.
- OneDrive Client for Linux: `onedrive v2.5.11` from the
  `onedrive-abraunegg` AUR package.
- QEMU/KVM guest with 8 vCPUs, 6144 MiB RAM, OVMF, and a disposable QCOW2
  overlay. No host block device or physical Omarchy partition was attached.
- SSH and the OAuth callback tunnel were bound to host loopback only. Microsoft
  authentication used a new disposable personal account. The host's OneDrive
  CLI configuration, token, service, sync directory, and personal Microsoft
  account were not read or changed.

The installed plugin checkout was updated to the exact working-tree source
under test. The real `/usr/bin/onedrive`, its packaged user service, Microsoft
OAuth, Microsoft Graph, and a guest-only `~/OneDrive` directory were used. No
fake CLI, token fixture, or service drop-in was active during the live-account
run.

## Standards checked

- The plugin structure, manifest, settings, bar placement, IPC calls, and
  restart checks follow Omarchy's shell-plugin documentation and validator.
- Authentication, quota, sync-status, dry-run, single-file download, remote
  link lookup, remote removal, monitor mode, and user-service setup use the
  documented OneDrive Client for Linux interfaces.
- No `--resync`, logout, token deletion, or client configuration mutation was
  used. The destructive cloud test was confined to the uniquely named
  `OmaOneDrive-E2E-20260815-1320` directory created by this run.

## Automated and integration gates

- Eight JavaScript model/presentation tests passed.
- The shell helper suite passed, including missing client, missing token,
  stopped and active services, stale journal state, local activity, quota,
  current and pending remote status, remote-command failure, cache reuse, and
  private state permissions.
- `python3 -m py_compile`, manifest JSON parsing, ShellCheck, and
  `git diff --check` passed.
- `omarchy plugin validate` passed against the installed checkout.
- `/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell` returned success with
  zero errors. Its remaining warnings are unresolved standalone `qs.Commons`
  and `qs.Ui` import metadata; the Omarchy validator and live runtime resolve
  those modules.
- A clean shell restart changed the Quickshell PID and produced zero
  OmaOneDrive loader, syntax, type, reference, binding, or runtime errors.

## Real Microsoft account and data transfer

- The panel's login action opened the installed CLI. Interactive OAuth and
  consent completed, and the resulting guest refresh token was mode `0600`.
- Before initial sync, the client reported `5 GiB` total, zero used, and the
  guest out of sync with approximately 1124 KiB to download. OmaOneDrive mapped
  the current v2.5.11 wording to `Pending changes`.
- The documented dry run completed, followed by a real initial sync. The guest
  downloaded `Getting started with OneDrive.pdf` (1,151,898 bytes) and created
  the account's empty `Documents` and `Pictures` directories.
- A 4,863-byte upload probe was uploaded from the guest. Remote link lookup
  found it, an independent `--download-file` copy succeeded, and the upload and
  download SHA-256 digests matched exactly.
- With monitor mode active, a second 4,863-byte file was created locally and
  appeared remotely. A subsequent cloud check reported `Up to date`.
- The uniquely named remote test directory was removed with the official CLI.
  Reconciliation removed only its two guest files. A protected backup remains
  inside the disposable VM at
  `~/.local/state/omaonedrive-live-backup-20260815-1330/test-folder-before-delete`.
  Remote lookup then confirmed the probe was absent and the next cloud check
  returned `Up to date`.

## Service, IPC, and recovery behavior

- The packaged `onedrive.service` was enabled. Plugin IPC `status`, `refresh`,
  `check`, `pause`, and `resume` all completed against the live account.
- Pause produced the real `Sync paused` state and stopped the unit. Resume
  passed through activation/sync settling and returned to `Monitoring`.
- The personal account rejected the client's optional near-real-time Graph
  WebSocket request with `notSupported`. The CLI remained active and continued
  with its 300-second polling monitor, as designed. After the subsequent sync
  completion, OmaOneDrive correctly displayed `Monitoring` rather than an
  active failure state while retaining the historical CLI error in activity.
- Immediately after remote deletion, v2.5.11's
  `--display-sync-status` raised a `std.json.JSONException` while processing the
  tombstone. OmaOneDrive displayed `Check failed` instead of retaining stale
  `Up to date`. A normal sync reconciled the tombstone and the same command then
  returned `Up to date`; no `--resync` was needed.
- A full guest reboot was performed with the service active. After startup,
  the token remained `0600`, the service returned `enabled` and `active`, the
  new shell loaded the plugin without errors, and live status returned
  `Monitoring`, `Up to date`, and no current error.
- The guest was then powered off cleanly. Offline `qemu-img check` reported no
  errors in the disposable overlay, and the temporary SSH callback, noVNC, and
  tailnet forwarding processes were stopped.

## Presentation matrix

The live-account panel was visually inspected at 1280x800 in all of these
states and placements:

- Full and Compact layouts.
- Top, bottom, left, and right bar positions.
- Aether, Matte Black, and Catppuccin Latte themes, covering light and dark
  palettes.
- Real login-required, paused, monitoring, storage, recent-file, sync-complete,
  and cloud-check states.

Text, controls, storage bars, activity rows, panel anchoring, and the bar badge
remained legible and unclipped. The persistent Omarchy `Learn Keybindings`
notification visible behind one panel is shell-owned and not plugin content.

Ignored visual evidence is under `.vm/shots-live-2026-08-15/`, including the
post-reboot panel and each layout, placement, theme, login, and paused state.
The earlier deterministic fixture matrix under
`.vm/shots-redesign-2026-08-15/` additionally covers missing-client,
attention, and animated syncing badges without altering the installed package
or forcing a live failure.

## Defects found and fixed

1. The helper did not recognize v2.5.11's official `is out of sync with
   Microsoft OneDrive` response as pending changes. The parser and regression
   fixture now cover it.
2. An incomplete historical sync marker could expose `syncing=true` while the
   service was stopped. Syncing is now gated on the unit actually running.
3. A failed explicit cloud-status command retained a stale successful status.
   It now reports `Check failed`, while preserving any successfully refreshed
   quota and surfacing the incomplete cloud check.

All automated and guest validation gates passed again after these fixes.

## Qualification boundary

This run qualifies real disposable-account OAuth, quota/status access, initial
download, hash-verified upload/download, monitor upload, scoped cloud deletion,
local reconciliation, service controls, reboot persistence, shell integration,
and the listed UI matrix. Missing-client and forced active-error visuals remain
deterministic fixture coverage because uninstalling the guest package or
manufacturing a live account failure would add risk without improving the
command-boundary evidence. Long-duration throttling, enterprise tenant policy,
shared libraries, and multi-day monitor reliability remain outside this
single-session test.
