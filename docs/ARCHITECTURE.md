# Architecture

`manifest.json` declares one third-party Omarchy `bar-widget` with the stable id
`io.github.salemsayed.omaonedrive`. `BarWidget.qml` owns the bar icon and loads
`Panel.qml`, which follows Omarchy's native popup ownership, keyboard, theme,
and panel-switch contracts.

`Service.qml` is the asynchronous boundary between QML and the operating
system. Local polling, cloud checks, and systemd control each run in a
`Quickshell.Io.Process`; no command is constructed through a shell.
Timed pauses stop `onedrive.service` and schedule a fixed-name transient
`omaonedrive-resume.timer` through `systemd-run --user`. Replacing a preset or
resuming immediately first cancels that timer. If scheduling fails after the
service was stopped, the service is started again so a failed timer cannot
leave sync paused unexpectedly.

`onedrive-status.py` reads:

- the effective `sync_dir` from `onedrive --display-config`;
- presence (never contents) of the CLI's `refresh_token` file;
- effective two-way, download-only, or upload-only mode from the CLI's
  read-only `--display-config` output;
- `onedrive.service` load, enabled, active, failure, result, and main-process
  exit states;
- the next activation of the transient timed-resume user timer, when present;
- bounded user-journal history for sync-in-progress, last-complete, and error
  state;
- recent regular files below the configured sync directory, without following
  symlinks.

Routine status calls do not contact Microsoft. `--remote` additionally invokes
the CLI's `--display-quota` and `--display-sync-status` display modes with
independent bounded timeouts, concurrently so one slow request does not delay
the other. Successful results and recent-file rows are atomically cached under
`$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive`, or the standard
`~/.local/state` fallback. The directory is mode `0700`; the cache and lock are
mode `0600`. Failed or timed-out cloud queries retain the last successful
result and are reported separately from local service failures. A file lock
serializes multiple monitor/widget instances.

No refresh-token content, Microsoft response URL, access token, browser state,
or file content crosses the helper boundary.
