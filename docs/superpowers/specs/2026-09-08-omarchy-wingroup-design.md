# omarchy-wingroup — design

Date: 2026-09-08
Status: approved for planning

## Problem

On this machine a single Hyprland workspace routinely holds a dozen or more
Alacritty windows, nearly all of them Claude Code sessions belonging to
different projects. Two things are hard:

1. **Finding a window.** The title carries a session summary
   ("Everest-web full redesign"), but fourteen of them on one workspace is a
   flat, unsearchable pile.
2. **Knowing what is idle.** A session that has finished its task and is
   waiting for input looks exactly like one that is mid-run.

Hyprland's native window groups do not solve this: group members must share a
workspace, a tab bar with twelve tabs is unusable, and a group has no identity
that survives closing its last window.

## Goal

Give every window a **group** — usually a project, sometimes several projects
that belong together — and make groups a first-class, always-visible,
one-keystroke thing:

- a strip of short group names in waybar, showing which group is active and
  which ones have busy sessions;
- one keybind that opens a searchable picker of groups and their windows;
- automatic assignment of new windows to the right group by working directory,
  with a manual override that sticks;
- the ability to re-group and to move a window between groups at any time.

## Non-goals

- Replacing or wrapping Hyprland's native `togglegroup` tabbed stacks.
- Any modification to Claude Code, or any IPC with it. Session state is read
  from the window title only.
- Cross-machine or cross-session persistence of window-level state. Group
  definitions persist; per-window overrides do not outlive the window.
- A graphical drag-and-drop overlay. The picker is walker's dmenu mode.

## Decisions

These were settled during brainstorming and are not open in the plan:

| Question | Decision |
| --- | --- |
| What is a group, mechanically? | A **named Hyprland workspace** (`name:everest`) plus metadata. Activating a group dispatches `workspace name:<group>`; its windows tile normally. |
| How do windows land in a group? | **Automatically by project, with manual override.** Resolution happens once, at window-open time. |
| Can a group span projects? | Yes. A group owns a list of projects. |
| What does the keybind open? | **walker in dmenu mode**, themed like the Omarchy menu. |
| What is always visible? | A strip of short group names in waybar, left side, next to the workspace indicators. |
| Language | bash + `jq`, following Omarchy's `bin/` script conventions. No build step. |

## Architecture

Four executables and a state file. Every component is a thin shell over one
resolution library, so the picker, the daemon and the bar module cannot
disagree about which group a window belongs to.

```
        hyprctl clients -j ──┐
        /proc/<pid>/cwd    ──┼──► lib/resolve.sh ──► (window → project → group, status)
        state.json         ──┘           │
                                         ├──► bin/wingroup         (CLI + walker picker)
                                         ├──► bin/wingroup-daemon  (socket2 listener, auto-assign)
                                         └──► bin/wingroup-waybar  (one bar slot's JSON)
```

### Component: `lib/resolve.sh`

Pure functions. No side effects, no `hyprctl dispatch`. This is the piece that
has to be right, and it is the piece with the most test coverage.

**`wg_window_cwd <pid>`** — the window's working directory.
Mirrors `omarchy-cmd-terminal-cwd`: take the last child of the window pid,
`readlink -f /proc/<child>/cwd`, and validate that the child's `exe` is a
listed shell in `/etc/shells` and that the cwd is a directory. Empty output
when it cannot be determined.

**`wg_cwd_project <cwd>`** — the project a directory belongs to.

- `$HOME/projects/<repo>/.claude/worktrees/<wt>/...` → project `<repo>`,
  worktree label `<wt>`
- `$HOME/projects/<repo>/...` or exactly `$HOME/projects/<repo>` → project `<repo>`
- anything else (including `$HOME` itself) → no project

The worktree label is carried separately and used only for display, so that
two windows in different worktrees of the same repo group together but remain
distinguishable in the picker.

**`wg_project_group <project>`** — first group in `state.json` whose
`projects` array contains the project, else empty.

**`wg_window_group <address> <pid>`** — the resolved group for a window:
an entry in `overrides` keyed by window address wins; otherwise
`wg_project_group(wg_cwd_project(wg_window_cwd(pid)))`.

**`wg_title_status <title>`** — classify the leading glyph of a window title:

| Leading glyph | Status |
| --- | --- |
| `✳` | `idle` — the session is waiting on the user |
| `◐` or `◑` | `busy` — spinner frames; the session is working |
| anything else | `plain` — not a Claude session |

This mapping was verified empirically: sampling titles minutes apart showed a
window transition `◐ → ✳` on completion, and a known-working session
transition `◑ → ◐`. The glyph set is defined in one associative array so a
newly observed state (for example a distinct "needs permission" glyph) is a
one-line addition. Any unrecognised leading glyph classifies as `plain`, never
as an error.

### Component: state

Path: `~/.local/state/omarchy/wingroup/state.json`.

```json
{
  "auto": true,
  "catchall": null,
  "groups": [
    {
      "name": "everest",
      "label": "everest",
      "projects": ["everest-web", "everest-rs", "everest-api"],
      "monitor": null
    },
    { "name": "plat", "label": "plat", "projects": ["niro-platform"], "monitor": null }
  ],
  "overrides": { "0x5573a1e5f650": "plat" }
}
```

- `name` — the Hyprland workspace name. Immutable for the life of the group;
  renaming a group changes `label` only, so windows never need to move.
- `label` — the short name drawn in the bar and the picker.
- `projects` — directory names under `~/projects`.
- `monitor` — optional monitor description; when set, the group's workspace is
  bound to it on creation, so a group always opens on the same screen.
- `overrides` — window address → group name. Set by an explicit "send to
  group" action. Entries for addresses that are no longer present are pruned
  on every write.
- `auto` — master switch for automatic assignment.
- `catchall` — group name for windows with no project match, or `null`.
  **Default `null`: such windows are left exactly where they are.** Doing
  nothing is preferable to filing a window under the wrong group.

Order of the `groups` array is the order of the bar strip and the picker.

Writes are atomic: write a temporary file in the same directory, then
`mv`. A missing or unparseable state file is replaced with the documented
default rather than causing a failure; the unparseable file is preserved
alongside with a `.corrupt` suffix.

### Component: `bin/wingroup-daemon`

`socat -U - UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock`
piped into a `while read` loop.

**`openwindow>>ADDR,WORKSPACE,CLASS,TITLE`** — the only event that moves a
window.

1. Skip if `auto` is false.
2. Skip if the window is floating (`hyprctl clients -j`, `.floating`).
3. Resolve the group. The child shell may not exist yet at the instant the
   window appears, so retry resolution up to 10 times at 100 ms intervals
   before giving up.
4. If a group resolves and the window is not already on that workspace,
   `hyprctl dispatch movetoworkspacesilent name:<group>,address:0x<ADDR>`.
5. If no group resolves, do nothing (or move to `catchall` when configured).

**`closewindow`, `windowtitle`, `workspace`, `activewindow`, `movewindow`** —
prune stale overrides where relevant and request a bar refresh.

Bar refresh is debounced: at most one `pkill -RTMIN+11 waybar` per 150 ms, so
a burst of title changes across fourteen busy sessions costs one signal.

**Auto-assignment happens only at open time.** The daemon never relocates a
window it has already seen. A window the user moves by hand stays moved.

Single-instance: a lock file under `$XDG_RUNTIME_DIR` holding the pid; a
second start exits cleanly. The daemon exits when the socket closes, so it
dies with the Hyprland session.

### Component: `bin/wingroup-waybar`

`wingroup-waybar <slot-index>` prints one line of waybar JSON for slot *n*:

```json
{ "text": "everest²", "tooltip": "everest — 3 windows, 2 busy\nProjects: everest-web, everest-rs", "class": "active" }
```

Waybar cannot turn a single custom module into several independently clickable
buttons, and the group list is dynamic while waybar's config is static.
Resolution: **eight pre-declared slot modules**, `custom/wingroup0` through
`custom/wingroup7`, all in `modules-left`. Each runs this script with its own
index. A slot with no corresponding group prints an empty `text`, and waybar
hides a custom module whose text is empty — so the strip shows exactly as many
buttons as there are groups, and each one is genuinely clickable.

- `class` is `active` for the group whose workspace is focused, `busy` when
  the group holds at least one busy session, else empty. Styling lives in
  `~/.config/waybar/style.css`.
- The busy count is rendered as a superscript digit appended to the label.
- `on-click` → `wingroup activate <slot>`; `on-click-right` → `wingroup menu`.
- Modules use `"interval": "once"` plus `"signal": 11`; the daemon drives all
  refreshes. Groups beyond eight are reachable through the picker and are
  listed in slot 7's tooltip.

### Component: `bin/wingroup` (CLI and picker)

| Subcommand | Behaviour |
| --- | --- |
| `menu` | The walker picker. Groups first (label, window count, busy count), a separator, then every window (status glyph, title, group). Selecting a group activates it; selecting a window focuses it. Trailing actions: `+ new group…`, `tidy…`, `toggle auto`. |
| `send [--address ADDR]` | Choose a group for the focused window (or `ADDR`), write an override, move the window. Offers `+ new group…`. |
| `activate <slot\|name>` | `hyprctl dispatch workspace name:<group>`. |
| `next` / `prev` | Cycle through groups in strip order. |
| `tidy` | Re-resolve every open window by project and show the full list of proposed moves; apply only on confirmation. Windows with a manual override are left alone. |
| `new <label> [project…]` | Create a group. |
| `rename <name> <label>` | Change the displayed label. |
| `dissolve <name>` | Remove the group. Its windows stay on that workspace, which keeps its Hyprland name but is no longer tracked; nothing is closed or moved. |
| `toggle-auto` | Flip `auto`, notify, refresh the bar. |

`tidy` is the first-run path: it files the windows that were already open
before the daemon started.

### Component: `lib/hypr.sh`

Every compositor interaction goes through `wg_hypr_query` and
`wg_hypr_dispatch`. In tests both are replaced with stubs that read fixture
JSON and append dispatches to a log file, so the suite never touches the live
compositor.

## Keybinds

Appended to `~/.config/hypr/bindings.conf`:

```
unbind = SUPER, G
bindd = SUPER, G, Window groups, exec, wingroup menu
bindd = SUPER CTRL, G, Send window to group, exec, wingroup send
```

`SUPER+G` is currently Hyprland's `togglegroup`. It is being taken
deliberately: no native groups are in use on this machine, and the native
group binds under `SUPER+ALT` are left untouched, so `togglegroup` remains
reachable by rebinding if it is ever wanted back.

## Installation

`install.sh`, idempotent, every edited file backed up first:

1. Symlink `bin/*` into `~/.local/bin`.
2. Merge the eight slot modules and their definitions into
   `~/.config/waybar/config.jsonc` (`jq`-based, comment-preserving via a
   marked block), and append the styling block to `style.css`.
3. Append the keybind block to `~/.config/hypr/bindings.conf`, guarded by a
   marker comment so re-running does not duplicate it.
4. Append `exec-once = wingroup-daemon` to `~/.config/hypr/autostart.conf`.
5. Seed `state.json` if absent.

`uninstall.sh` reverses each step by marker.

## Testing

`bats` and `shellcheck` are both already installed.

**Fixtures.** Real `hyprctl clients -j` and `hyprctl workspaces -j` dumps
captured from this machine — fourteen Claude windows across three workspaces,
including two worktrees of the same repo, a plain non-Claude shell, and a
window whose cwd is `$HOME` — plus recorded `.socket2.sock` event lines.

**Unit tests** (`lib/resolve.sh`, table-driven):
`wg_cwd_project` for worktree, plain-project, home and outside-projects paths;
`wg_project_group` for multi-project groups and misses; `wg_title_status` for
each glyph and for unknown glyphs; override precedence in `wg_window_group`;
state read/write round-trips, atomic replacement, corrupt-file recovery and
stale-override pruning.

**Bar tests:** slot JSON for a populated slot, an empty slot, the active
group, a busy group, and the overflow tooltip on slot 7.

**Daemon tests:** feed recorded event lines through the handler with stubbed
`hyprctl` and assert on the dispatch log — that an `openwindow` for a project
window produces exactly one `movetoworkspacesilent`, that a floating window
produces none, that a window with no project produces none under the default
`catchall`, that a second event for the same address produces none, and that a
burst of `windowtitle` events produces exactly one refresh signal.

**Picker tests:** menu text generation from fixtures, and the mapping from a
selected line back to an action, with walker itself stubbed.

`shellcheck` runs clean over every script as part of the suite.

Nothing in the suite starts a daemon, signals waybar, or dispatches to the
running compositor.

## Risks

- **Title-glyph drift.** A Claude Code release could change the indicators.
  Contained to one associative array; unknown glyphs degrade to `plain`, which
  costs the status column and nothing else.
- **cwd resolution failure.** A terminal whose child is not a listed shell, or
  a session started before `cd`-ing into a project, resolves to no project.
  The window is left alone and can be filed by hand — the failure mode is
  inaction, not a wrong move.
- **Named workspaces in the existing workspace module.** Waybar's
  `hyprland/workspaces` may render group workspaces as anonymous icons
  alongside the numbered ones. If it does, `ignore-workspaces` is added to
  that module during implementation. To be confirmed against waybar 0.15.0
  behaviour, not assumed.
- **Racing the shell at window open.** Handled by bounded retry; after ten
  attempts the window is left alone.

## Environment

Recorded because the design depends on it: Hyprland 0.55.2, waybar 0.15.0,
walker (dmenu mode with `-d -p -i`), Omarchy layout under
`~/.local/share/omarchy`, waybar signals 7–10 already in use so the strip
takes 11, `socat`/`jq`/`bats`/`shellcheck` present, projects under
`~/projects`, Claude worktrees under `<repo>/.claude/worktrees/<name>`.
