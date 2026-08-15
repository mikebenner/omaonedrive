# Architecture

`manifest.json` declares one third-party Omarchy `bar-widget` with the stable id
`io.github.salemsayed.omaonedrive`. `BarWidget.qml` owns the bar icon and loads
`Panel.qml`, which follows Omarchy's native popup ownership, keyboard, theme,
and panel-switch contracts.

`Service.qml` is the asynchronous boundary between QML and the operating
system. Local polling, cloud checks, and systemd control each run in a
`Quickshell.Io.Process`; no command is constructed through a shell.

`onedrive-status.py` reads:

- the effective `sync_dir` from `onedrive --display-config`;
- presence (never contents) of the CLI's `refresh_token` file;
- `onedrive.service` load, enabled, and active states;
- bounded user-journal history for sync-in-progress, last-complete, and error
  state;
- recent regular files below the configured sync directory, without following
  symlinks.

Routine status calls do not contact Microsoft. `--remote` additionally invokes
the CLI's `--display-quota` and `--display-sync-status` display modes with
bounded timeouts. Results and recent-file rows are atomically cached under
`$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive`, or the standard
`~/.local/state` fallback. The directory is mode `0700`; the cache and lock are
mode `0600`. A file lock serializes multiple monitor/widget instances.

No refresh-token content, Microsoft response URL, access token, browser state,
or file content crosses the helper boundary.
