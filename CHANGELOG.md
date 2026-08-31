# Changelog

## 1.5.5 - 2026-08-31

- Make repair and open-panel notification clicks survive shell and plugin
  reloads by using Omarchy's persisted, fixed-command `--exec` hint.
- Validate the plugin against current Omarchy Quattro and run its isolated test
  suite in CI.

## 1.5.4 - 2026-08-26

- Keep the panel's IPC target available while moving its bar slot.
