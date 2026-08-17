# Announcement copy

Image to attach: `docs/images/announcement.png` (1600×790, 2:1 — renders full
width in an X timeline without cropping).

## Discord

Image to attach: `docs/images/announcement-discord-v1.2.png` (1785×881, wide
landscape for Discord).

Hey Omarchy folks 👋

I’ve released **OmaOneDrive 1.2** — a OneDrive widget for the Omarchy bar.

It connects to the excellent [OneDrive Client for Linux](https://github.com/abraunegg/onedrive)
by abraunegg. It doesn’t bundle another sync client; it displays and controls
your existing `onedrive` CLI and `onedrive.service`.

Features include:

- Sync, service, login, and failure status
- Cloud storage and recent activity
- Full and Compact layouts
- Keyboard navigation
- Timed pauses for 15 minutes, 1 hour, or 4 hours with automatic resume

Routine refreshes stay local. Microsoft is only contacted when you explicitly
select **Check cloud**, and the plugin never reads or stores your refresh token.

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

> OmaOneDrive — OneDrive status in the Omarchy bar.
>
> Sync state, cloud storage and recent activity, with pause and resume built in.
>
> It only talks to Microsoft when you ask it to. The 30-second refresh reads
> your local service and journal, nothing more.
>
> github.com/salemsayed/omaonedrive

242 characters plus the link.

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
