# Architecture

`manifest.json` declares one third-party Omarchy `bar-widget` with the stable id
`io.github.salemsayed.omaonedrive`. `BarWidget.qml` owns the bar icon and loads
`Panel.qml`, which follows Omarchy's native popup ownership, keyboard, theme,
and panel-switch contracts.

`Service.qml` is the asynchronous boundary between QML and the operating
system. Local polling, cloud checks, and systemd control each run in a
`Quickshell.Io.Process`; no command is constructed through a shell.
Timed pauses stop `onedrive.service` and schedule the transient
`omaonedrive-resume.timer` through `systemd-run --user`. That is today's
single-account behaviour: the helper accepts a different resume unit per account
through `--resume-unit`, which the current QML does not yet pass, just as it does
not yet pass `--service`, `--confdir` or `--list-accounts`. Replacing a preset or
resuming immediately first cancels that timer. If scheduling fails after the
service was stopped, the service is started again so a failed timer cannot
leave sync paused unexpectedly.

`onedrive-status.py` reads:

- the account's `config` file, every `name = value` line of it, and the
  effective `sync_dir` from that file and from `onedrive --display-config`; when
  neither yields one, the default account falls back to `~/OneDrive` and every
  other account reports no sync directory at all rather than borrowing that;
- presence (never contents) of the CLI's `refresh_token` file;
- effective two-way, download-only, or upload-only mode from the same two
  sources;
- the client version, from `--display-config`, or from `onedrive --version`
  when the account's directory does not exist;
- the `--service` unit's (default `onedrive.service`) load, enabled, active,
  failure, result, and main-process exit states;
- the next activation of that account's transient timed-resume user timer, named
  by `--resume-unit`, when present; without that flag only `onedrive.service`
  has a well-known one and reads its legacy `omaonedrive-resume.timer`, while
  every other account reports no resume time rather than borrowing it;
- bounded user-journal history for sync-in-progress, live reconciliation phase,
  last-complete, and error state;
- recent regular files below the configured sync directory, without following
  symlinks;
- the names, `Description`, `LoadState` and `ExecStart` command line of the
  `onedrive` and `onedrive@<instance>` user units, from which each account's
  `--confdir` is read out of `argv[]` — never guessed from the instance name;
- systemd enablement symlinks, `*.wants/onedrive*.service` and
  `*.requires/onedrive*.service`, under the user (`$XDG_CONFIG_HOME/systemd/user`
  or `~/.config/systemd/user`, and `$XDG_RUNTIME_DIR/systemd/user` when that
  variable is set) and system (`/run/systemd/user`, `/etc/systemd/user`,
  `/usr/lib/systemd/user`) unit directories — or, when `OMAONEDRIVE_UNIT_ROOTS`
  is set to a non-empty value, the colon-separated directories it names *instead*
  of all of those — so an enabled-but-unloaded instance is still discovered;
- whether each candidate config directory exists, including every space-joined
  prefix of a `--confdir` read out of an `ExecStart` — systemd renders argv
  unquoted, so the longest prefix that is a real directory is taken as the
  intended one, and prefixes are tried even through tokens that look like flags
  because a directory may legitimately be named `My - Work`;
- this account's own cached presentation data from a previous run — quota,
  remote status and the recent-file rows — out of its `status-cache.json`.

`--confdir` selects which account's config directory is read, defaulting to
`$XDG_CONFIG_HOME/onedrive` or `~/.config/onedrive`; a value must be an absolute
path containing no C0 control character or DEL, and must not be an existing
non-directory. It reaches the CLI as a single argument. `--service` and
`--resume-unit` name that account's unit and the bare name of its transient
resume unit; neither may begin with `-`, because both are passed to `systemctl`
as positional arguments where such a value would be read as an option, and both
are capped at systemd's 255-byte unit-name limit counting the suffix. A
`--resume-unit` given with a trailing `.timer` is normalised rather than
refused, so a name whose instance legitimately ends that way still works. Given a
non-default `--service` with no `--confdir`, the helper reads that unit's own
config directory rather than describing the default account under another
account's name; a unit that cannot be resolved is reported as an unknown account
with no config directory, never as the default one. `--list-accounts` is a separate mode with its own output shape:
it prints a JSON array of the discovered accounts (`service`, `instance`,
`confdir`, `description`) and exits without building a status object or invoking
the OneDrive client at all, falling back to the single default account when
systemd is unavailable. The helper never creates a config directory it was only
asked to read.

Routine status calls do not contact Microsoft. `--quota` invokes the CLI's
fast `--display-quota` mode, while `--sync-status` invokes the potentially slow
full-drive `--display-sync-status` mode. The legacy `--remote` helper option
runs both with independent bounded timeouts. Quota and sync-status timestamps,
errors, and successful results remain independent. Presentation data and
recent-file rows are atomically cached under
`$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive`, or the standard
`~/.local/state` fallback. Each account gets its own directory there, keyed on
its service and canonical config directory, so accounts never read each other's
quota, recent files or remote status; the default account keeps the historical
top-level `status-cache.json` and `status.lock`. Every such directory is mode
`0700` and every cache and lock inside it is mode `0600`. Failed or timed-out
cloud queries retain the last successful result and are reported separately from
each other and from local service failures. Each account's own file lock
serializes multiple monitor/widget instances for that account, so one account's
cloud check cannot block another account's refresh.

No refresh-token content, Microsoft response URL, access token, browser state,
or synced-file content crosses the helper boundary; the only additional data
`--list-accounts` emits is each unit's name, the instance parsed out of that
name, its systemd description, and its config-directory path.
