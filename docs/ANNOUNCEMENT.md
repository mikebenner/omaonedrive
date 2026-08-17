# Announcement copy

Image to attach: `docs/images/announcement-discord-v1.5.png` (1785×881, wide
landscape for Discord; `preview.png` in the repo root is the same composite at
1200×750 for the plugin listing).

## Discord

Hey Omarchy folks 👋

**OmaOneDrive 1.5** is out — the OneDrive widget for the Omarchy bar can now
tell you when something is wrong and hand you the fix.

It connects to the excellent [OneDrive Client for Linux](https://github.com/abraunegg/onedrive)
by abraunegg. It doesn’t bundle another sync client; it displays and controls
your existing `onedrive` CLI and `onedrive.service`.

New since 1.3:

- Desktop notifications when OneDrive fails, needs a resync or
  reauthentication, recovers, or cloud storage crosses 90% full — clicking one
  jumps straight to the fix (optional, on by default)
- Guided resync repair: opens the CLI’s own interactive `--resync` flow, which
  asks for confirmation before touching anything
- Live transfer status: the panel names the file currently uploading or
  downloading, with a percentage when the client reports one
- The storage meter turns urgent as your drive fills up
- Open OneDrive on the web straight from the panel
- Clearer cloud checks — **Refresh storage** vs **Verify sync** — with honest
  timing hints and error lines that show how old they are
- A calmer activity feed: known-benign client fallbacks (like WebSocket
  monitoring being unavailable) no longer masquerade as errors

Longstanding features:

- Sync, service, login, and failure status with distinct bar badges
- Cloud storage and recent activity
- Full and Compact layouts, keyboard navigation
- Timed pauses for 15 minutes, 1 hour, or 4 hours with automatic resume

Routine refreshes stay local. Microsoft is only contacted when you explicitly
select **Refresh storage** or **Verify sync**, and the plugin never reads or
stores your refresh token.

Install the OneDrive client:

```bash
omarchy-pkg-add onedrive-abraunegg
onedrive
systemctl --user enable --now onedrive.service
```

Install OmaOneDrive:

```bash
omarchy plugin add https://github.com/salemsayed/omaonedrive.git --enable
```

https://github.com/salemsayed/omaonedrive

Feedback and bug reports are very welcome 🙌

## Main tweet

> OmaOneDrive 1.5 — OneDrive status in the Omarchy bar.
>
> Now it notifies you when sync breaks, hands you the guided repair, names the
> file being transferred, and warns before your storage runs out.
>
> It still only talks to Microsoft when you ask it to.
>
> github.com/salemsayed/omaonedrive

## Shorter variant

> OmaOneDrive — OneDrive status in the Omarchy bar.
>
> Sync state, storage, recent activity, pause and resume. Routine refreshes stay
> local; only an explicit check queries the cloud.
>
> github.com/salemsayed/omaonedrive

## Optional follow-up (thread)

> Activity rows say "changed in OneDrive", never "uploaded". The plugin sees
> local timestamps and journal events, not what actually transferred — so it
> doesn't claim otherwise. A test enforces that wording.

> Two layouts: Full with storage and the activity timeline, Compact with storage
> and the two actions. Bar badges separate missing-client, login, paused and
> syncing from a healthy monitoring dot.

## Notes

- It drives the existing [OneDrive Client for Linux](https://github.com/abraunegg/onedrive);
  it is not a OneDrive client itself and bundles nothing. Say so if anyone asks
  what it installs.
- Pause/resume is exactly `systemctl --user stop/start onedrive.service`. The
  refresh token is never read — only its presence is checked.
- The marketplace listing is flagged for maintainer review because the plugin
  manages a service, which is expected for what it does. Link the repository
  until that listing is approved.
