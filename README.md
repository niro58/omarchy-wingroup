# omarchy-wingroup

Project-based window grouping for [Omarchy](https://omarchy.org) / Hyprland.

```
󱓻 1 2 3   ● everest² · plat · drivora · 3dprint
```

## What this is

If you work on several projects at once, your windows end up scattered
across numbered Hyprland workspaces with no relationship to the work they
belong to. `wingroup` fixes that by giving each project family its own named
workspace — a **group** — and filing windows into their group automatically,
by the working directory their shell is sitting in.

A **group** is just a named Hyprland workspace (`everest`, `plat`,
`drivora`, ...) that owns one or more **projects** — directories under
`~/projects`. Open a terminal in `~/projects/everest-web` and the window
lands on the `everest` workspace without you doing anything. Open a Claude
Code session there and its busy/idle status shows up on the group's waybar
button too.

## The waybar strip

```
everest² · plat · drivora · 3dprint
```

Each group gets a short button showing its label (each `·` above is just
the gap between separate waybar modules, not a character wingroup prints).
Reading the example above:

- **`everest²`** — two of the group's Claude Code sessions are **idle**:
  finished, waiting for input, ready for the next thing (title starts with
  `✳`). The small `²` is that idle count, rendered as a Unicode superscript.
  A group with nothing waiting on you shows no superscript at all. Hover the
  button for the full breakdown — `everest — 3 windows · 2 idle · 1 busy`,
  where a busy session is one currently working (`◐` or `◑`) and the
  remainder are plain terminals with no session in them.
- **Highlighting** — a group's button is dimmed (55% opacity) by default.
  It goes to 85% when the group's workspace is on screen on a monitor that
  does not have focus, to full opacity when one of its sessions is busy, and
  to full opacity **and bold** when its workspace is the focused one. Being
  looked at beats being on screen, which beats being busy.

Left-click a button to switch to that group's workspace. Right-click any
button to open the picker menu (`wingroup menu`).

Only the first 8 groups get a button — see **Known limitations** below.

## Keybinds

Installed into `~/.config/hypr/bindings.conf`:

| Keybind | Action |
| --- | --- |
| `SUPER+G` | Open the group and window picker (`wingroup menu`) |
| `SUPER+CTRL+G` | Send the focused window to a group (`wingroup send`) |

Installing `wingroup` unbinds Hyprland's native `SUPER+G` (`togglegroup`,
which toggles Hyprland's own window-grouping feature — a different concept
from this tool's project groups) and rebinds it to open the picker instead.
If you rely on `togglegroup`, remap it to something else before installing.

## The `wingroup` command

Every subcommand:

```
wingroup menu                          open the group and window picker
wingroup send [--address A --group G]  send a window to a group
wingroup activate <slot|name>          switch to a group
wingroup next | prev                   cycle through groups
wingroup tidy [--yes]                  file every window by its project
wingroup new <label> [project...]      create a group
wingroup rename <name> <label>         change a group's displayed label
wingroup dissolve <name>               remove a group, leaving its windows alone
wingroup monitor <group> <mon|->       pin a group to a monitor, or clear the pin
wingroup toggle-auto                   turn automatic assignment on or off
```

Worked examples:

```console
$ wingroup new "Niro 3D Print" niro-3dprint-app niro-3dprint-web
```
Creates a group. The workspace/group name is slugified from the label
(`niro-3d-print`), while the label (`Niro 3D Print`) is what shows in the
picker and tooltips. `project...` is the list of `~/projects/*` directories
that belong to this group — you can pass none and add windows to it later
with `wingroup send`.

Creating the group also **files the windows it has just claimed**: every open
window whose project belongs to the new group is moved onto its workspace
straight away, by the same rules `wingroup tidy` uses — a floating window is
left floating, a window already on the right workspace is not touched, and a
window you sent somewhere by hand keeps the group you sent it to. A group that
counts a window has to be a group that holds it; otherwise the bar says
`other¹` and activating it shows an empty workspace. A group created with no
projects owns no window yet, so nothing moves.

```console
$ wingroup activate everest      # by name
$ wingroup activate 1            # by slot index (0-based, in state.json order)
```
Switches to a group's workspace.

```console
$ wingroup next
$ wingroup prev
```
Cycles to the next/previous group's workspace, wrapping around. If focus
isn't currently on a group workspace, `next` starts at the first group and
`prev` at the last.

```console
$ wingroup send --address 0xaaa1 --group plat
```
Moves a specific window to a group and remembers that choice as an
**override**, so automatic assignment won't move it back even if its cwd
says otherwise. Run without `--address`/`--group` and it defaults to the
currently focused window and opens a picker of groups to send it to —
that's what `SUPER+CTRL+G` does. That picker's last entry, `+ new group…`,
opens the same prompt `SUPER+G`'s does: it creates the group and then sends the
window to it, so a window can go somewhere that does not exist yet.

```console
$ wingroup rename everest "EV stack"
```
Changes a group's display label. The underlying workspace name (`everest`)
never changes, so open windows and existing overrides aren't disturbed.

```console
$ wingroup dissolve plat
```
Removes a group from `state.json` and drops any overrides that pointed at
it. It never touches a window — anything sitting on that workspace just
stays there, no longer tracked as a group. The picker's `− remove a group…`
does exactly this, after asking which group and confirming that one by name.

```console
$ wingroup monitor everest DP-1
$ wingroup monitor everest -
```
Pins a group to a monitor, or clears the pin with `-`. The monitor name is one
of the names `hyprctl monitors` reports; anything else is refused, with the
available names listed. A pinned group always opens on its monitor: `wingroup
activate` focuses that monitor first and, if the group's workspace is currently
living on a different one, moves the workspace across before switching to it.
That move is the point — Hyprland creates a named workspace on whichever
monitor happens to be focused and leaves it bound there, so a group first
opened on the laptop would otherwise stay on the laptop forever. A group with
no pin (`"monitor": null`, the default) is switched to exactly as before,
wherever it already is.

```console
$ wingroup tidy --yes
```
Files every window that's on the wrong workspace for its group in one pass.
Floating windows and windows with no resolvable group are left alone.
Without `--yes` it previews the moves in the picker first ("Apply N
move(s)" / "Cancel") — this doubles as a way to see exactly what the
resolver currently thinks, before committing to anything.

```console
$ wingroup toggle-auto
```
Turns automatic assignment (new windows filed on open) on or off, without
affecting groups, overrides, or windows already placed.

```console
$ wingroup menu
```
Opens the walker picker, in this order:

1. every group, with its window, idle and busy counts, and the monitor it is
   pinned to if it has one;
2. the four actions — `+ new group…`, `− remove a group…`, `⟳ tidy`,
   `⏻ auto-assign: on/off`;
3. a separator, then every window with its status glyph and group.

The actions sit directly under the groups rather than at the bottom, so they
stay a few rows in no matter how many windows are open. This is `SUPER+G`.
Opening it while a picker is already up does nothing — the second one would
only stack on top of the first.

`+ new group…` prompts for the label in a walker text field, then creates the
group the same way `wingroup new` does — same slugification, same refusal of a
duplicate name, and the same filing of the windows the new group claims. If the
window you had focused sits in a project that no group owns yet, that project is
added to the new group; otherwise the group starts empty. Either way it tells
you which happened, and how many windows it filed, with a desktop notification,
since a picker opened from a keybind has no terminal to print to. Failures from
picker actions are notified the same way, so an entry can never look like it
silently did nothing.

`− remove a group…` is `wingroup dissolve` without a terminal: it asks which
group, then asks again to confirm that one by name — with *Cancel* as the entry
already under the cursor, because there is no undo — and then removes the group
and its overrides. It never closes or moves a window; everything on that
workspace stays exactly where it is. It says which group went, and says so too
when there are no groups to remove.

## `state.json`

Lives at `~/.local/state/omarchy/wingroup/state.json`. Shape:

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
    }
  ],
  "overrides": {
    "0xaaa3": "plat"
  }
}
```

- **`auto`** — whether new windows get filed automatically on open
  (`wingroup toggle-auto`).
- **`catchall`** — an optional group name that windows with no resolvable
  project are filed into instead of being left alone. `null` by default.
- **`groups[]`** — `name` is the Hyprland workspace name (slugified,
  stable); `label` is what's shown in waybar and the picker; `projects` is
  the list of `~/projects/*` directory names this group owns — the example
  above is one group (`everest`) owning three projects
  (`everest-web`, `everest-rs`, `everest-api`); `monitor` is the monitor this
  group is pinned to (`wingroup monitor`), or `null` for no pin.
- **`overrides`** — window address to group name, for windows explicitly
  sent to a group with `wingroup send` (or the picker). Overrides beat
  automatic resolution and are dropped automatically when the window
  closes.

## How automatic assignment decides

For each window, the daemon and `tidy` look at the *shell's* working
directory (not the terminal emulator's): they find the terminal window's
most recently spawned direct child process — assumed to be its shell, the
same assumption Omarchy's own `omarchy-cmd-terminal-cwd` makes — and read
`/proc/<pid>/cwd` for that process:

1. If the window's address has an **override** (`wingroup send` was used on
   it), it goes to that group. Overrides always win.
2. Otherwise, if the cwd is inside `~/projects/<project>`, the window is
   filed into whichever group lists `<project>` in its `projects` array. A
   cwd inside a Claude Code worktree
   (`~/projects/<project>/.claude/worktrees/<name>`) still resolves to
   `<project>` for this purpose — worktrees don't get their own groups.
3. If the cwd is **outside `~/projects`** entirely (or the project isn't
   owned by any group), the window is **left exactly where it is** — it is
   never filed into some arbitrary or default workspace. The only exception
   is if you've explicitly set `catchall` in `state.json` to a group name;
   then such windows go there instead, since that's a deliberate choice
   rather than an arbitrary one.

New windows are resolved by the daemon as they open (`wingroup-daemon`,
retrying briefly while the shell finishes spawning). `wingroup tidy` runs
the same resolution over every currently open window in one pass, useful
after moving things around by hand or when timing didn't work out.

## Startup integration with `restore-claude.sh`

If you use a `~/restore-claude.sh` script that respawns the Claude Code
terminals that were open at shutdown (each via
`xdg-terminal-exec --dir="$cwd"`), install adds `wingroup-restore` to
Hyprland's autostart, right after the daemon:

```
exec-once = wingroup-daemon
exec-once = wingroup-restore
```

This is opt-in by having the script: install adds the `wingroup-restore`
line **only** if the restore script -- `$HOME/restore-claude.sh`, or
`$WG_RESTORE_SCRIPT` if you set it -- exists and is executable at the moment
you run `./install.sh`. Otherwise you get the daemon line alone, and install
says so. Respawning terminals at every login is not something a window
grouper should sign you up for silently.

To turn it on later, create the script, then either re-run `./install.sh`
after `./uninstall.sh`, or just add the line yourself inside the wingroup
block in `~/.config/hypr/autostart.conf`:

```
# >>> wingroup
exec-once = wingroup-daemon
exec-once = wingroup-restore
# <<< wingroup
```

`wingroup-restore` runs your restore script and then runs `wingroup tidy
--yes`. The daemon already tries to file each terminal as it opens, but
that's a race against the shell spawning — `wingroup-restore`'s `tidy` pass
afterwards makes the outcome deterministic regardless of who wins.

Two environment variables control it:

- **`WG_RESTORE_SCRIPT`** — path to your restore script. Defaults to
  `$HOME/restore-claude.sh`. If it's missing or not executable,
  `wingroup-restore` prints a note and exits 0 — not everyone has one.
- **`WG_RESTORE_SETTLE`** — seconds to wait after the restore script
  returns, before running `tidy`, so spawned shells have time to actually
  start (their cwd isn't readable until they have). Defaults to `5`.

Arguments are passed straight through to your restore script, so
`wingroup-restore --dry-run` stays a dry run — nothing gets tidied.

## Install / uninstall

```console
$ ./install.sh
```

- Symlinks everything in `bin/` into `~/.local/bin`.
- Adds 8 `custom/wingroup0`–`custom/wingroup7` modules to
  `~/.config/waybar/config.jsonc` and wires them into `modules-left`.
  `"hyprland/workspaces"` stays exactly where it was, so the bar reads left to
  right: Omarchy menu icon, your numbered workspaces, then the group strip.
- Adds `"ignore-workspaces": [".*[^0-9].*"]` to the `"hyprland/workspaces"`
  object. A group *is* a named Hyprland workspace, and that module has no icon
  for a name — it falls through to its `format-icons` `default` glyph and draws
  an anonymous dot per group, right next to that group's own name in the strip.
  Waybar matches these patterns against the *whole* workspace name, so the regex
  reads "contains at least one non-digit": every group name matches, including
  one that starts with a digit like `3dprint`, and your numbered workspaces 1–0
  match nothing and stay. `uninstall.sh` takes the line back out. If the edit
  cannot be made — `modules-left` is spread over several lines, or there is no
  `"hyprland/workspaces": {` object to put the setting in — install says which
  part failed and changes nothing.
- Appends matching styles to `~/.config/waybar/style.css`.
- Adds the `SUPER+G` / `SUPER+CTRL+G` keybinds to
  `~/.config/hypr/bindings.conf` (and unbinds native `SUPER+G`).
- Adds the `exec-once = wingroup-daemon` autostart line to
  `~/.config/hypr/autostart.conf`, plus `exec-once = wingroup-restore` if
  you have an executable restore script (see above). The output tells you
  which of the two it added.
- Seeds `~/.local/state/omarchy/wingroup/state.json` if it doesn't exist
  yet.

Every config file it touches is backed up first (`<file>.bak.<timestamp>`),
and install is idempotent — running it again is a no-op for anything
already installed. Reload afterwards:

```console
$ hyprctl reload && pkill -SIGUSR2 waybar
```

```console
$ ./uninstall.sh
```

Removes the symlinks and strips out exactly what install added from each
config file — restoring the surrounding content **byte-for-byte**, right
down to trailing newlines. Your groups are left alone: `state.json` is
never touched, so uninstalling and reinstalling later picks up right where
you left off.

## Requirements

All of these ship with Omarchy:

- `hyprctl`, `waybar`, `walker` — the compositor, bar, and picker this tool
  drives. The picker is opened through Omarchy's own
  `omarchy-launch-walker` when that exists, so it starts the walker/elephant
  services if they are not up and gets the same geometry as every other
  Omarchy menu; without Omarchy, `walker` is called directly with the same
  flags.
- `jq` — every bit of `state.json` and window-table handling goes through
  it.
- `socat` — the daemon reads Hyprland's event socket through it.
- `pkill` — signals waybar to redraw its custom modules after a change.
- `notify-send` — how a picker action reports what it did, or why it could
  not. There is no terminal behind `SUPER+G`. If it is missing, nothing breaks:
  the same message still goes to stderr.
- Standard base utilities the scripts and installer rely on: `flock` (the
  daemon's and the picker's single-instance locks), `mktemp`, `readlink`,
  `ps` (one walk of the process table per window-table build, to find each
  terminal's shell), `awk`, `sed`, `cut`, `wc`, `date`, `truncate`.

## Troubleshooting

**The bar isn't updating.** Two separate things have to be true: waybar
needs to have been reloaded once since install
(`pkill -SIGUSR2 waybar`) so it picks up the new modules, and
`wingroup-daemon` needs to actually be running (it's what sends the reload
signal waybar listens for afterwards). Check with
`pgrep -fa wingroup-daemon`.

**A window isn't being filed into its group.** The most common cause is
that its shell's working directory isn't under `~/projects` — see **How
automatic assignment decides** above. A window opened before its shell
finished starting, or one the daemon's retry window ran out on, will also
sit ungrouped until the next `wingroup tidy`.

**I want to see what the resolver sees before it moves anything.** Run
`wingroup tidy` (no `--yes`). It previews the moves it would make in the
picker before applying anything, so you can confirm or cancel.

## Known limitations

- **Only the first 8 groups get a waybar slot.** Groups beyond the 8th
  aren't shown as their own button, but they're still fully usable — reach
  them from `wingroup menu`, and the 8th slot's tooltip lists how many more
  there are and their names.

## Future work (not in scope)

- **Remote agents.** The existing remote agent setup could surface as its
  own group whose "windows" are remote sessions rather than local ones.
  That would need an entry source other than `hyprctl clients`, which the
  current design doesn't have.
- **A GTK layer-shell overlay** replacing the walker picker, with
  drag-and-drop between groups. The backend is already CLI-shaped, so the
  UI is replaceable without touching resolution, state, or the daemon.

## License

MIT
