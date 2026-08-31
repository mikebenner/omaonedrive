# Changelog

## 1.5.6 - 2026-08-31

- Make actionable notifications compatible with Omarchy 4.0.1 by placing
  `--exec` after the title and body and preserving the click command as
  separate argv elements.
- Render filenames, folders, and helper output as literal plain text so
  markup-shaped data cannot be interpreted by the shell, including the shared
  Omarchy 4.0.1 bar tooltip and panel hero.
- Make the partial-output timeout regression reliable on the single-vCPU
  Omarchy compatibility VM instead of depending on a 50 ms cold Python start.

## 1.5.5 - 2026-08-31

- Make repair and open-panel notification clicks survive shell and plugin
  reloads by using Omarchy's persisted, fixed-command `--exec` hint.
- Validate the plugin against current Omarchy Quattro and run its isolated test
  suite in CI.

## 1.5.4 - 2026-08-26

- Keep the panel's IPC target available while moving its bar slot.
