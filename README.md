# omarchy-wingroup

Project-based window grouping for [Omarchy](https://omarchy.org) / Hyprland.

A **group** is a named Hyprland workspace that owns one or more projects. New
windows are filed into their project's group automatically, by working
directory. Groups show up as clickable short names in waybar, and one keybind
opens a searchable picker of every group and window — including whether each
Claude Code session is busy or idle.

```
󱓻 1 2 3   ● everest² · plat · drivora · 3dprint
```

Status: design approved, implementation in progress. See
[the design spec](docs/superpowers/specs/2026-09-08-omarchy-wingroup-design.md).

## Requirements

Hyprland, waybar, walker, `socat`, `jq`. All ship with Omarchy.

## License

MIT
