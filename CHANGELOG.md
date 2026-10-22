# Changelog

## [0.2.3] — 2026-10-22 — First public release

- Menu bar reading (hottest chip sensor, CPU or GPU) as a coloured pill.
- Dropdown: every sensor group with bars, fans, 60-second CPU/GPU chart, top heating processes (including system processes via `/bin/ps`), all raw sensors.
- Floating widget: always on top, all Spaces and full screen, drag anywhere (position remembered), mini mode, click-through, opacity, border, lock position.
- Two adjustable colour scales: chip (70 / 85 / 95 °C) and body (50 / 57 / 62 °C), plus macOS thermal pressure in the header.
- Optional alert when the hottest chip sensor reaches a limit (at most once every 5 minutes).
- Refresh from 250 ms to 5 s; launch at login.
- `thermal-probe` command-line sensor test (`--raw`, `--watch`, `--bench`).

Earlier versions were private development builds.
