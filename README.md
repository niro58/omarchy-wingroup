# omarchy-wingroup

Project-based window grouping for [Omarchy](https://omarchy.org) and plain
Hyprland. A **group** is a named Hyprland workspace that owns one or more
projects — directories under `~/projects`. Open a terminal in
`~/projects/alpha-web` and the window is filed onto the group that owns
`alpha-web`, automatically, by the working directory the shell is sitting in.
A strip of buttons in waybar shows every group, and — if the terminals are
running Claude Code — how many sessions in each one have finished and are
waiting on you.

![Waybar strip: the numbered workspaces, then five group buttons — "mail" plain and dimmed with no idle sessions, then "docs" with a superscript one in amber, "api" with a superscript two in orange, "web" with a superscript three in red-orange, and "infra" with a superscript five in bold red](docs/images/bar.png)

## The problem

You have a dozen or more terminals open. Each one is a Claude Code session in
a different project. They are piled onto workspace 1 and workspace 2, stacked
on top of each other, and the only way to find the one that has finished is to
tab through all of them.

Two things are missing. First, the windows have no relationship to the work
they belong to: Hyprland's numbered workspaces are a place, not a project.
Second, a session that has finished and a session that is still grinding look
identical from the outside — you have to look at each one to find out.

`wingroup` answers both with the same mechanism. Every project family gets a
named workspace of its own, new terminals are filed into theirs by working
directory without you doing anything, and each group's button in waybar carries
a count of the sessions in it that are waiting for you, coloured so a group with
work piling up is visible from across the room.

If you do not use Claude Code, the grouping half still works on its own — the
idle and busy counts simply stay at zero.

## Requirements

Everything here ships with Omarchy. On plain Hyprland you may need to install
some of it.

- **`hyprctl`** — every query and every window move goes through it. Hyprland
  itself is required; there is no other compositor backend.
- **`waybar`** — the group strip is eight custom waybar modules. Without waybar
  you still get the CLI and the picker, but no bar.
- **`walker`** — the picker behind `SUPER+G` and `wingroup send`. On Omarchy it
  is opened through `~/.local/share/omarchy/bin/omarchy-launch-walker`, which
  starts the walker and elephant services if they are not up and applies the
  house geometry; elsewhere `walker` is run directly with the same geometry.
- **`jq`** — all state and window-table handling.
- **`socat`** — the daemon reads Hyprland's event socket through it.
- **`pkill`** — sends waybar the redraw signal (`RTMIN+11`).
- **`journalctl`** — `wingroup-oomwatch` follows the user journal to notice
  sessions systemd-oomd has killed. Without systemd there is no oom-kill line to
  read and nothing to detect; everything else still works.
- **`notify-send`** — how an action started from the picker reports what it did.
  Optional: without it the same message still goes to stderr.
- Base utilities: `bash` 5.0 or newer (the daemon times its refresh debounce
  with `EPOCHREALTIME`),
  `flock`, `ps`, `mktemp`, `readlink`, `truncate`, `awk`, `sed`, `cut`, `wc`,
  `tail`, `grep`, `date`.

Your terminals must set the window title (Claude Code's status glyph is read
out of it), and your login shell must be listed in `/etc/shells` — that is how
a terminal's shell is identified before its working directory is read.

## Install

```console
$ git clone https://github.com/<you>/omarchy-wingroup.git
$ cd omarchy-wingroup
$ ./install.sh
$ hyprctl reload && pkill -SIGUSR2 waybar
```

`install.sh` edits your real waybar and Hyprland configuration in place. **It
copies every file to `<file>.bak.<unix-timestamp>` before touching it**, and it
is idempotent: a file that already contains the wingroup block is left alone, so
re-running it is safe.

Exactly four files are modified, plus `~/.claude/settings.json` if you have
one, plus two directories written to:

| File | What changes |
| --- | --- |
| `~/.config/waybar/config.jsonc` | Eight `"custom/wingroup0".."custom/wingroup7"` module definitions, appended to `"modules-left"`; `"ignore-workspaces"` added inside `"hyprland/workspaces"` |
| `~/.config/waybar/style.css` | The `/* >>> wingroup */` block: base, idle ramp, state and crashed rules for all eight slots |
| `~/.config/hypr/bindings.conf` | `unbind = SUPER, G`, then `SUPER+G` and `SUPER+CTRL+G` bound to wingroup |
| `~/.config/hypr/autostart.conf` | `exec-once = wingroup-daemon` and `exec-once = wingroup-oomwatch`, and `exec-once = wingroup-restore` only if you have a restore script |
| `~/.claude/settings.json` | A `SessionStart` hook entry running `wingroup-hook` — only if the file already exists |
| `~/.local/bin/` | Symlinks to `wingroup`, `wingroup-daemon`, `wingroup-hook`, `wingroup-oomwatch`, `wingroup-restore`, `wingroup-waybar` |
| `~/.local/state/omarchy/wingroup/` | `state.json` seeded with an empty group list, if it does not exist |

Four details worth knowing before you run it:

- **It takes over `SUPER+G`.** Hyprland binds that to `togglegroup` — its own
  window-tabbing feature, which is a different concept from this tool's project
  groups. Install emits `unbind = SUPER, G` and rebinds it to `wingroup menu`.
  If you use `togglegroup`, move it to another key first.
- **`"ignore-workspaces": [".*[^0-9].*"]`** goes into the numbered-workspace
  indicator. A group *is* a named workspace, so without this the indicator draws
  an anonymous `format-icons` default dot for every group, right next to that
  group's own name in the strip. The regex is matched against the whole
  workspace name and means "contains at least one non-digit", so every group
  name is hidden — including one starting with a digit, like `3d-assets` — and
  workspaces `1`–`10` are kept. Note that it hides *every* named workspace, not
  only wingroup's.
- **The waybar edit is line-shaped.** `"modules-left"` must be a single line
  ending in `],`, and `"hyprland/workspaces": {` must open on a line of its own.
  If any of the three edits does not land, install prints which one and changes
  nothing at all.
- **It registers a Claude Code hook.** If `~/.claude/settings.json` exists,
  install adds one `SessionStart` entry to it running `wingroup-hook`, which is
  the only way session ids are ever learned — see [Crashed
  sessions](#crashed-sessions). The file is the user's own and mostly nothing to
  do with wingroup, so the edit is careful: it is merged with `jq`, written to a
  temp file beside the target and renamed, backed up first like every other
  file, idempotent on the command string, and **refused outright if the existing
  file is not valid JSON**. Every way it can go wrong — no file, unparseable
  file, failed write — is announced and skipped rather than failing the install.
  Pass `--no-claude-hook` to skip it deliberately; crash detection then names
  the project a lost session was in rather than the session itself.

`"hyprland/workspaces"` keeps its position, so the bar reads left to right:
Omarchy menu button, your numbered workspaces, then the group strip.

### First run

```console
$ wingroup new alpha alpha-web alpha-api
wingroup: filed 2 window(s) onto alpha
$ wingroup new beta beta
$ wingroup tidy --yes
```

`wingroup new` takes a label and the project directory names the group owns.
Creating a group immediately files the windows it has just claimed onto its
workspace; `wingroup tidy` does the same sweep for every group at once, which is
what you want for the windows you already had open.

## Reading the bar

Each group gets one button showing its label, and a superscript when it has idle
sessions. In the screenshot above: `mail` has none, `docs¹` has one, `api²`
two, `web³` three, and `infra⁵` five — which draws at the top step, since the
ramp caps at four. The
gaps between the labels are the gaps between separate waybar modules, not
characters wingroup prints.

A window counts as **idle** when its title starts with `✳`, and **busy** when it
starts with `◐` or `◑` — the glyphs Claude Code puts at the head of its window
title. Anything else is a plain window: it counts towards the group's total and
towards nothing else. The superscript counts idle sessions only, because that is
the number you act on. Hover a button for the full breakdown:

```
alpha — 5 windows · 2 idle · 1 busy
Projects: alpha-web, alpha-api
```

Left-click a button to switch to that group's workspace. Right-click any button
to open the picker.

### Highlighting

A group is in exactly one of four states, and the module emits at most one class
for it:

| Where the group is | Class | Installed rule |
| --- | --- | --- |
| Off screen, nothing busy | *(none)* | `padding: 0 6px; opacity: 0.55;` |
| Off screen, a session busy | `busy` | `opacity: 1;` |
| On screen, on an unfocused monitor | `visible` | `opacity: 0.85;` |
| On the focused monitor | `active` | `opacity: 1; font-weight: bold;` |

Being looked at beats being on screen, which beats being busy.

With more than one monitor, "active" is a fact about *this* screen: the bar on
the external monitor draws the group filling that monitor as active, while the
laptop's bar draws the same group as merely visible. That depends on waybar
exporting `WAYBAR_OUTPUT_NAME` to the module's script. If your waybar does not,
the module falls back to the globally focused monitor and every bar marks the
same group active. Nothing breaks either way.

### The idle colour ramp

Idle heat is a separate fact from the state above, so it is a *second* class
alongside the first, never instead of it — a group can be the one you are
looking at and hold four finished sessions at once.

| Idle sessions | Class | Installed rule |
| --- | --- | --- |
| 0 | *(none)* | — |
| 1 | `idle1` | `color: #e0a458; opacity: 0.75;` |
| 2 | `idle2` | `color: #ef8354; opacity: 0.85;` |
| 3 | `idle3` | `color: #f45d48; opacity: 0.95; font-weight: 600;` |
| 4 or more | `idle4` | `color: #ff3b30; opacity: 1; font-weight: bold;` |

`idle4` is a ceiling: past a handful the exact number stops changing what you do
about it. A group with nothing waiting emits no idle class and looks exactly as
it always has.

In the stylesheet the ramp sits **between** the base rule and the three state
rules. Both kinds of selector are one id plus one class, so they have equal
specificity and the later rule wins each property they share. That ordering
means the ramp lifts the dimmed default for a group with work waiting in it,
while `active` keeps the last word on opacity and weight — the group you are
looking at stays bright and bold and merely takes the ramp's colour with it.

### Changing the ramp yourself

Every installed rule is one line with one selector list naming all eight slots.
To change a step, restate it **after** the wingroup block in
`~/.config/waybar/style.css` — never inside it, because that block is what
`uninstall.sh` removes. Last rule of equal specificity wins, and a step you do
not restate keeps its shipped colour.

```css
/* >>> wingroup */
/* ... installed rules ... */
/* <<< wingroup */

/* keep the theme colour; say what is waiting with weight alone */
#custom-wingroup0.idle1, #custom-wingroup1.idle1,
#custom-wingroup2.idle1, #custom-wingroup3.idle1,
#custom-wingroup4.idle1, #custom-wingroup5.idle1,
#custom-wingroup6.idle1, #custom-wingroup7.idle1 { color: @foreground; opacity: 0.8; }
```

Both classes land on the widget together, so `#custom-wingroup0.active.idle3`
is a valid selector for "the group I am looking at, with three sessions waiting
in it".

## Crashed sessions

Under memory pressure systemd-oomd picks the greediest cgroup on the machine and
kills it. Most days that is the browser. Some days it is a terminal with a Claude
Code session in it, and the window simply disappears — no message, no exit code,
nothing in a shell to scroll back to. You find out an hour later by noticing a
window you were sure you had left open, and then you have to work out which
project it was and whether the conversation was worth anything.

`wingroup crashed` answers that. The group that lost a session is flagged on the
bar, and one command relaunches every lost session in the directory it was
working in — resuming the actual conversation wherever wingroup knows its id.

### How a dead session is identified

Omarchy launches every terminal through uwsm/`xdg-terminal-exec`, which puts it
in a systemd scope of its own:

```
app-Hyprland-xdg\x2dterminal\x2dexec-9029a872.scope
```

Those backslashes are literal characters in the unit name. That name is the only
thing a live session and the record of its death have in common:
`/proc/<pid>/cgroup` ends in it while the session runs, and systemd names it in
the journal when it kills the thing:

```
2026-09-08T14:02:11+0200 host systemd[1443]: app-Hyprland-xdg\x2dterminal\x2dexec-9029a872.scope: Failed with result 'oom-kill'.
```

So the scope is the join key — and everything worth knowing has to be written
down **while the session is still alive**. Afterwards there is nothing left to
read: `/proc` is gone, and the journal's launch line records the directory the
terminal was *opened* in, which is very often not where the session ended up.

Three pieces do it:

- **`wingroup-hook`** is a Claude Code `SessionStart` hook. Claude hands it the
  session id and working directory on stdin and it files them under the scope
  the terminal is running in. This is the only source of session ids anywhere on
  the machine; nothing else can work one out, before or after the kill.
- **`wingroup-oomwatch`** runs from login. It follows the user journal for
  oom-kill lines, and every 15 seconds it rescans `/proc` for live `claude`
  processes to keep the map current. That scan is the fallback for sessions that
  predate the hook: it cannot learn an id, but it does learn that *something* was
  running in that scope, and in which directory.
- **`wingroup crashed`** reads what the two of them left behind.

A kill line naming a scope with no session recorded against it is ignored, which
is how the browser — the thing oomd actually kills most days — stays out of this
entirely.

Both files live under `$XDG_RUNTIME_DIR/wingroup/` and are meant to die at
reboot. A crash you have not dealt with by the time you reboot is one
`restore-claude.sh` already handles from the other end, by replaying the whole
shutdown cluster.

### The crashed bar state

A group holding a crashed session gets the `crashed` class, and its tooltip
gains a line per crash directly under the counts, above the projects:

```
alpha — 4 windows · 1 idle · 0 busy
Crashed: /home/me/projects/alpha-api — 2026-09-08T14:02:11+0200
Projects: alpha-web, alpha-api
```

`crashed` is a *third* class alongside the state and the idle step, never
instead of one: a group can be the one you are looking at, warm with finished
work, and still be short a session oomd took while you were elsewhere.

| Class | Installed rule |
| --- | --- |
| `crashed` | `background: #7f1d1d; color: #ffd7d5; opacity: 1; font-weight: bold;` |

It is the only rule in the block that fills the widget rather than colouring its
text, because a crash is not "more idle sessions" and must not read as another
step on the ramp. And it is written **after** the state rules — the mirror of
why the ramp is written before them. The ramp has to yield to `active` or it
would dim the group you are looking at; this rule raises every property it
touches and lowers none, so it can safely take the last word, and it has to: the
group you are looking at is exactly the one whose lost session you most need to
be told about. Change it the way you change the ramp, by restating the selector
after the wingroup block.

### What cannot be recovered

**A session that was already running when the hook was registered cannot be
resumed by id.** The `/proc` scan can see that a `claude` was alive in that scope
and where it was working; there is no way for it to find out *which* session that
was, and after the kill there is nothing left to ask. Those crashes are still
detected, still flagged on the bar, and `--restore` still opens a terminal in the
right directory — but it starts a fresh `claude` there, and says so on the line
it prints. You get the project back, not the conversation.

Sessions started after the hook is registered are resumable by id. In practice
that means every session opened in a new terminal after you install — the ones
already open when you ran `./install.sh` stay unresumable until you restart them.


## Keybinds

| Keybind | Command | What it does |
| --- | --- | --- |
| `SUPER+G` | `wingroup menu` | Open the group and window picker |
| `SUPER+CTRL+G` | `wingroup send` | Send the focused window to a group |

`SUPER+G` replaces Hyprland's native `togglegroup`, as described under
[Install](#install).

## The picker

`SUPER+G` opens walker with the groups first, the actions next, every open
window below a separator, and a total on the last line:

```
▸ alpha              2 windows · 1 idle · 1 busy · on DP-1
▸ beta               1 windows · 1 idle · 0 busy
+ new group…
− remove a group…
⟳ tidy — file every window by its project
⏻ auto-assign: on
──────────────────────────────
  ✳ ready for review                             alpha
  ◐ running the test suite                       alpha:vat-rounding
  ✳ migration written                            beta
  · user@host:~                                  ungrouped
── 3 Claude sessions · 2 idle · 1 busy
```

Picking a group switches to its workspace. Picking a window focuses it. The
group rows show the monitor a group is pinned to, if it has one. The window rows
show each window's status glyph — `✳` idle, `◐` busy, `·` plain — its title with
the glyph stripped, and the group it resolves to, or `ungrouped`.

The last line is a footer rather than an entry: it cannot be selected, and
picking it does nothing. It counts the Claude sessions across the whole desktop
— every window that is idle or busy, in a group or not — and splits them the
way a group row does. Plain windows are left out of it deliberately: they are
one visible row each already, and the question the footer answers is how many
sessions are running, not how many windows are open.

A window whose shell is sitting in a Claude worktree —
`~/projects/<project>/.claude/worktrees/<branch>` — shows that worktree's name
after the group, as `group:worktree`. Worktrees deliberately do not get groups
of their own: every worktree of a repo resolves to the same project and so onto
the same workspace, which is what you want for filing them and no help at all
when three rows of the picker all read `alpha`. A worktree name longer than 16
characters is cut short with `…` — that column ends the row, and a branch name
has no upper bound. A window that is not in a worktree shows nothing extra.

The four actions sit directly under the groups rather than at the bottom, so
they stay a few rows in no matter how many windows are open:

- **`+ new group…`** prompts for a label in a walker text field, then creates
  the group exactly as `wingroup new` would — same slugification, same refusal
  of a duplicate name, same filing of the windows the new group claims. If the
  window you had focused sits in a project no group owns yet, that project seeds
  the new group; otherwise the group starts empty. Either way you get a desktop
  notification saying which happened, since a picker opened from a keybind has
  no terminal to print to.
- **`− remove a group…`** is `wingroup dissolve` without a terminal. It asks
  which group, then asks again to confirm that one by name — with *Cancel* as
  the entry already under the cursor, because there is no undo. It never closes
  or moves a window.
- **`⟳ tidy`** is `wingroup tidy`.
- **`⏻ auto-assign: on/off`** is `wingroup toggle-auto`, and the row shows the
  current setting.

Opening the picker while one is already up does nothing: the second would only
stack on top of the first.

## Uninstall

```console
$ ./uninstall.sh
$ hyprctl reload && pkill -SIGUSR2 waybar
```

It removes the six symlinks from `~/.local/bin` and strips out exactly what
install added from each of the four config files, restoring the surrounding
content **byte for byte** — including any blank line install prepended to a
block, and including whether the file originally ended in a newline (install
records that on the closing marker so uninstall can put it back).

**The Claude Code hook is removed too**, if install put one there: uninstall
takes out the single `SessionStart` entry running `wingroup-hook` and leaves
everything else in `~/.claude/settings.json` alone, including any `SessionStart`
hooks of your own. This is the one edit that cannot be reversed byte for byte —
the file is JSON and `jq` reformats what it rewrites — so the *content* comes
back exactly and the whitespace is `jq`'s. A settings file that never had the
hook in it is not opened for writing at all, so uninstalling on a machine
installed with `--no-claude-hook` cannot reflow it.

**Your groups are kept.** `~/.local/state/omarchy/wingroup/` is never
touched, so uninstalling and reinstalling later picks up where you left off. To
throw the groups away too, delete that directory by hand.

Run it from the checkout: it reads `bin/` to know which symlinks to remove.

---

# Reference

## Every subcommand

```
wingroup menu                          open the group and window picker
wingroup send [--address A --group G]  send a window to a group
wingroup activate <slot|name>          switch to a group
wingroup next | prev                   cycle through groups
wingroup tidy [--yes]                  file every window by its project
wingroup new <label> [project...]      create a group
wingroup rename <name> <label>         change a group's displayed label
wingroup dissolve <name>               remove a group, leaving its windows alone
wingroup monitor <group> <name|->      pin a group to a monitor, or clear the pin
wingroup toggle-auto                   turn automatic assignment on or off
wingroup crashed [--restore] [--clear] list sessions systemd-oomd killed
```

### `wingroup new <label> [project...]`

```console
$ wingroup new "Alpha Stack" alpha-web alpha-api
wingroup: filed 2 window(s) onto alpha-stack
```

The workspace name is slugified from the label — lowercased, every run of
non-alphanumeric characters replaced by `-`, leading and trailing dashes
trimmed. `Alpha Stack` becomes `alpha-stack`. The label is what shows in the bar
and the picker; the name is what Hyprland sees and never changes afterwards. A
label that slugifies to an empty string, or to the name of an existing group, is
refused.

`project...` is the list of `~/projects/*` directory names the group owns. You
can pass none and add windows later with `wingroup send`.

Creating a group also **files the windows it has just claimed**, by the same
rules `tidy` uses: a floating window is left floating, a window already on the
right workspace is not touched, and a window you sent somewhere by hand keeps
the group you sent it to. A group that counts a window has to be a group that
holds it — otherwise the bar says `alpha¹` and activating it shows an empty
workspace. A group created with no projects owns no window yet, so nothing
moves and nothing is printed.

### `wingroup activate <slot|name>`

```console
$ wingroup activate alpha    # by name
$ wingroup activate 0        # by slot: 0-based index into state.json order
```

An all-digit argument smaller than the number of groups is read as a slot index;
anything else is a group name. This is what a left-click on waybar slot *N*
runs. An unpinned group is switched to wherever it already lives.

### `wingroup next` / `wingroup prev`

```console
$ wingroup next
```

Cycles to the next or previous group's workspace in `state.json` order, wrapping
around. If the focused workspace is not a group's, `next` starts at the first
group and `prev` at the last. Fails if there are no groups.

### `wingroup send [--address A --group G]`

```console
$ wingroup send --address 0xaaa3 --group beta
```

Moves that window to that group's workspace and records the choice as an
**override**, so automatic assignment will not move it back even though its
working directory says otherwise.

With neither flag it defaults to the focused window and opens a picker of
groups — that is what `SUPER+CTRL+G` does. The picker's last entry, `+ new
group…`, opens the same prompt `SUPER+G`'s does: it creates the group and then
sends the window to it, so a window can go somewhere that does not exist yet.
Cancelling the prompt creates nothing and sends nothing.

### `wingroup tidy [--yes]`

```console
$ wingroup tidy --yes
```

One pass over every open window, moving each one that is on the wrong workspace
for the group it resolves to. Skipped: floating windows, windows already in the
right place, windows with no resolvable group, and windows carrying an override.

Without `--yes` it shows the count in the picker first — `Apply 3 move(s)` /
`Cancel` — which doubles as a preview of what the resolver currently thinks.

### `wingroup rename <name> <label>`

```console
$ wingroup rename alpha-stack "EV stack"
```

Changes the displayed label only. The workspace name stays `alpha-stack`, so
open windows and existing overrides are not disturbed.

### `wingroup dissolve <name>`

```console
$ wingroup dissolve beta
```

Removes the group from `state.json` and drops any overrides that pointed at it.
It never touches a window: anything sitting on that workspace stays there, no
longer tracked as a group.

### `wingroup monitor <group> <name|->`

```console
$ wingroup monitor alpha DP-1     # pin
$ wingroup monitor alpha -        # clear the pin
```

The monitor name must be one `hyprctl monitors` reports; anything else is
refused and the available names are listed:

```console
$ wingroup monitor alpha HDMI-9
wingroup: no such monitor: HDMI-9 (available: eDP-2, DP-1)
```

Hyprland creates a named workspace on whichever monitor happens to be focused
and leaves it bound there, so a group first opened on the laptop stays on the
laptop forever. A pin fixes that: `wingroup activate` focuses the pinned monitor
first and, if the group's workspace is currently living on a different one,
drags the workspace across before switching to it.

### `wingroup toggle-auto`

```console
$ wingroup toggle-auto
```

Flips `.auto` in `state.json`. Turns automatic filing of newly opened windows on
or off without touching groups, overrides, or windows already placed.

### `wingroup crashed [--restore] [--clear]`

```console
$ wingroup crashed
2 session(s) killed by systemd-oomd:
  2026-09-08T14:02:11+0200  /home/me/projects/alpha-api  resumable
  2026-09-08T14:09:44+0200  /home/me/projects/beta       no session id, a fresh claude
```

With no flags it lists what was lost and changes nothing — the time systemd
killed it, the directory the session was working in, and whether an id was
recorded for it. See [Crashed sessions](#crashed-sessions) for why some rows have
one and some do not.

`--restore` relaunches all of them: one terminal per session, opened in the
directory that session was working in, running `claude --resume <id>` where there
is an id and a plain `claude` where there is not. A record whose directory no
longer exists — a worktree since removed, a project since moved — is skipped and
said so, because opening the terminal in `$HOME` instead would be a session in
the wrong place under the right name. The list is then cleared **whole**, skips
included: a directory that is gone can never be restored, and leaving the record
in would flag its group on the bar forever.

`--clear` is the "I have dealt with these myself" exit — nothing is relaunched,
the list is emptied, and the bar stops flagging groups that are fine again. Given
both flags, `--restore` wins; it clears the list anyway.

Nothing here is destructive. It only ever reads the two runtime files and opens
terminals.

## `state.json`

Lives at `~/.local/state/omarchy/wingroup/state.json`. One group here owns three
projects, and one window has been sent somewhere by hand:

```json
{
  "auto": true,
  "follow": true,
  "catchall": null,
  "groups": [
    {
      "name": "alpha",
      "label": "Alpha Stack",
      "projects": ["alpha-web", "alpha-api", "alpha-infra"],
      "monitor": "DP-1"
    },
    {
      "name": "beta",
      "label": "beta",
      "projects": ["beta"],
      "monitor": null
    }
  ],
  "overrides": {
    "0xaaa3": "beta"
  }
}
```

- **`auto`** — whether newly opened windows are filed automatically.
  `wingroup toggle-auto` flips it. `tidy` and `send` work either way.
- **`follow`** — whether the daemon takes you *to* a window it has just filed.
  `true` by default; see [Following a window you just
  opened](#following-a-window-you-just-opened). A state file written before this
  key existed has no `follow`, and its absence reads as `true`. No subcommand
  sets it; edit the file.
- **`catchall`** — a group name that windows with no resolvable project are
  filed into instead of being left alone. `null` by default, and only the daemon
  consults it — `tidy` never applies a catchall. No subcommand sets it; edit the
  file.
- **`groups[]`** — array order is the order of the waybar slots, the picker, and
  `next`/`prev`.
  - `name` — the Hyprland workspace name. Slugified at creation, stable
    afterwards.
  - `label` — what the bar and picker show. `wingroup rename` changes this.
  - `projects` — directory names directly under `~/projects` that this group
    owns. The group above owns three. If two groups list the same project, the
    earlier one in this array wins.
  - `monitor` — the monitor this group is pinned to, or `null`.
- **`overrides`** — Hyprland window address to group name, written by
  `wingroup send` and the picker. An override beats project resolution. The
  daemon deletes a window's override when that window closes, and prunes
  overrides for windows that no longer exist when it starts.

The file is rewritten atomically (temp file plus rename), and a write that would
not be valid JSON is refused with the old file left in place. If the file is
found unparseable it is moved to `state.json.corrupt` and replaced with the
empty default.

Anything that reads the file, changes it and writes it back — every subcommand
that touches a group or an override, and the daemon — holds an exclusive
`flock` on `.state.lock`, next to `state.json`, across all three steps. Without
it the second writer commits a document built from a copy taken before the
first writer's change, and that change is silently gone: a `wingroup new`
landing inside the daemon's handling of a window closing used to lose the
group, with no error printed anywhere. Reading alone — the bar, the picker, the
resolver — never takes the lock and never waits for one. The lock is held on an
open file descriptor, so a process that dies holding it releases it; a waiter
gives up after five seconds and says so rather than hanging.

## How automatic assignment decides

For each window, the daemon and `tidy` look at the **shell's** working
directory, not the terminal emulator's. They take the terminal window's pid,
find its highest-numbered direct child — assumed to be its shell, the same
assumption Omarchy's own `omarchy-cmd-terminal-cwd` makes — check that child's
executable is listed in `/etc/shells`, and read `/proc/<pid>/cwd` for it.

Then, in order:

1. If the window's address has an **override**, it goes to that group.
   Overrides always win.
2. Otherwise, if the working directory is inside `~/projects/<project>`, the
   window is filed into whichever group lists `<project>`. Only the first path
   segment under `~/projects` counts, so anything deeper — including a Claude
   Code worktree at `~/projects/<project>/.claude/worktrees/<branch>` — still
   resolves to `<project>`. Worktrees do not get their own groups.
3. If the working directory is **outside `~/projects`** entirely, or its project
   is not owned by any group, **the window is left exactly where it is.** It is
   never filed into some arbitrary or default workspace. The one exception is
   `catchall` in `state.json`: set it to a group name and the daemon sends such
   windows there instead. That is a deliberate choice rather than an arbitrary
   one, which is why it is off by default and has no subcommand.

Floating windows are never filed, at any stage.

`wingroup-daemon` resolves a window as it opens, retrying for about a second
while the shell finishes spawning, and files it at most once per window. It does
not watch for `cd`: if you change directory in a terminal afterwards, the window
stays where it is until the next `wingroup tidy`, which re-resolves every window
from its current working directory.

An **override is sticky against both**. A window you sent by hand is skipped by
`tidy` and by the filing a new group does, and keeps its group until it closes.

## Following a window you just opened

You open a terminal in `~/projects/alpha-web`; it belongs on the `alpha`
workspace; you are on workspace 2. Filing it silently would leave you looking at
workspace 2 while a window you deliberately asked for appears somewhere you
cannot see. So the daemon uses a single `movetoworkspace` dispatch, which moves
the window and switches to its workspace together.

Bulk filing is the opposite case and stays silent, because being dragged across
the desktop once per window is not what a dozen housekeeping moves should do:

- `wingroup tidy`, and the filing `wingroup new` does for the windows its group
  claims, never follow — those are batches by definition.
- `wingroup-restore` creates `$XDG_RUNTIME_DIR/wingroup-restoring` while it
  runs, which tells the daemon to keep filing silently, and removes it however
  the script ends — so a crashed or killed restore cannot leave following
  switched off for the session.
- For the first **10 seconds** after the daemon starts nothing is followed, so a
  login burst is quiet even when something other than `wingroup-restore` spawned
  it.
- `"follow": false` in `state.json` turns following off entirely.

Following changes *how* a window is moved, never *whether* it is.

## Startup integration with `restore-claude.sh`

This part is optional and off unless you already have the script.

If you keep a `~/restore-claude.sh` that respawns the terminals that were open
at shutdown, `install.sh` adds a third autostart line for it:

```
# >>> wingroup
exec-once = wingroup-daemon
exec-once = wingroup-oomwatch
exec-once = wingroup-restore
# <<< wingroup
```

**Install adds the `wingroup-restore` line only if that script exists and is
executable at the moment you run `./install.sh`.** The other two are
unconditional. Otherwise you get those two alone, and install says so in its
closing summary. Respawning terminals at
every login is not something a window grouper should sign a stranger up for.

`wingroup-restore` runs your script with following suppressed, waits five
seconds for the spawned shells to start (their working directory is not readable
until they have), and then runs `wingroup tidy --yes`. The daemon is already
filing each terminal as it opens, but that is a race against the shell spawning;
the tidy pass afterwards makes the result the same whoever wins. Arguments are
passed straight through, and `--dry-run` or `-n` skips the tidy.

If the script is missing or not executable, `wingroup-restore` prints a note and
exits 0.

To turn it on after the fact, create the script and add the line yourself inside
the existing wingroup block in `~/.config/hypr/autostart.conf`.

## Environment variables

All optional; the defaults are what install and the autostart lines use.

| Variable | Default | Used by |
| --- | --- | --- |
| `WG_PROJECTS_DIR` | `~/projects` | Resolution |
| `WG_STATE_DIR` | `~/.local/state/omarchy/wingroup` | Everything |
| `WG_HYPRCTL` | `hyprctl` | Everything |
| `WG_WALKER` | `walker` | Picker |
| `WG_WALKER_LAUNCHER` | `~/.local/share/omarchy/bin/omarchy-launch-walker` | Picker |
| `WG_RESOLVE_RETRIES` | `10` | Daemon |
| `WG_RESOLVE_DELAY` | `0.1` | Daemon |
| `WG_REFRESH_DEBOUNCE_MS` | `150` | Daemon |
| `WG_FOLLOW_GRACE` | `10` (seconds; `0` disables) | Daemon |
| `WG_RESTORE_FLAG` | `$XDG_RUNTIME_DIR/wingroup-restoring` | Daemon, restore |
| `WG_RESTORE_SCRIPT` | `~/restore-claude.sh` | Restore, install |
| `WG_RESTORE_SETTLE` | `5` (seconds) | Restore |
| `WG_RUNTIME_DIR` | `$XDG_RUNTIME_DIR/wingroup` | Hook, watcher, bar, `crashed` |
| `WG_SCAN_INTERVAL` | `15` (seconds) | Watcher |
| `WG_SESSIONS_TTL` | `21600` (seconds) | Watcher |
| `WG_JOURNAL_CMD` | `journalctl --user -f -n0 -o short-iso` | Watcher |
| `WG_LAUNCH_CMD` | `uwsm-app` | `crashed --restore` |

`install.sh` and `uninstall.sh` additionally honour `WG_BIN_DIR`,
`WG_WAYBAR_CONFIG`, `WG_WAYBAR_STYLE`, `WG_HYPR_BINDINGS`, `WG_HYPR_AUTOSTART`
and `WG_CLAUDE_SETTINGS` if you keep those files somewhere non-standard.

## Troubleshooting

**The bar is not updating.** The modules are `"interval": "once"`, so they only
redraw when something signals waybar. Two things have to be true. Waybar must
have been restarted once since install so it picks up the new modules
(`pkill -SIGUSR2 waybar`), and `wingroup-daemon` must be running, because it is
what sends the redraw signal afterwards:

```console
$ pgrep -fa wingroup-daemon
$ pkill -RTMIN+11 waybar     # force one redraw by hand
```

The daemon is started by `exec-once` in `~/.config/hypr/autostart.conf`, so it
comes up at login; `hyprctl reload` does not restart it. Only one can run at a
time — a second exits immediately saying so.

**A window is not being filed.** In rough order of likelihood: its shell's
working directory is not under `~/projects`; the project is not listed in any
group's `projects`; the window is floating; the window is not a terminal at all;
its shell is not in `/etc/shells`; automatic assignment is off. A window that
opened before its shell spawned, or whose retry window ran out, also sits
ungrouped. Almost all of these are fixed by `wingroup tidy`.

**Show me what the resolver sees.** Two ways. `wingroup menu` lists every open
window under the separator with the group it resolves to, or `ungrouped`. And
`wingroup tidy` without `--yes` counts the moves it would make and waits for you
to confirm or cancel, so you can look before anything happens.

**Turn automatic assignment off.** `wingroup toggle-auto`, or the
`⏻ auto-assign` row in the picker, which also shows the current setting.
`tidy`, `send` and `activate` keep working with it off; only the filing of newly
opened windows stops.

**Groups vanished.** Check for `state.json.corrupt` next to `state.json`: an
unparseable state file is moved aside and replaced with the empty default. The
`.corrupt` copy is the previous contents.

**A session died and the bar never flagged it.** In order: `wingroup-oomwatch`
must be running (`pgrep -fa wingroup-oomwatch`) — it is started by `exec-once` in
`~/.config/hypr/autostart.conf`, so it comes up at login and `hyprctl reload`
does not restart it. The scope must have been in the session map before the kill,
which means the watcher must have been up while the session was alive. And it
only ever files *oom-kills*: a session you closed, or one killed by anything
other than systemd-oomd, is not a crash and is not recorded. `wingroup-oomwatch
--once` with `WG_JOURNAL_CMD='journalctl --user -n200 -o short-iso --no-pager'`
replays the recent journal by hand and can be run while the watcher is up.

**A crashed session came back as a fresh `claude`.** No session id was ever
recorded for it, which means it was already running when `wingroup-hook` was
registered. See [What cannot be recovered](#what-cannot-be-recovered).

**The bar shows a group with windows in it, but the workspace is empty.** Run
`wingroup tidy`. Membership and location are separate facts, and something moved
a window out from under the group.

## Known limitations

- **Eight waybar slots.** `WG_SLOTS` is 8, defined once in `lib/constants.sh`
  and read by both the module and the installer.
  Groups past the eighth have no button of their own; they stay fully usable
  from `wingroup menu` and the CLI, and the eighth slot's tooltip lists how many
  more there are and their workspace names.
- **Per-screen highlighting depends on waybar exporting `WAYBAR_OUTPUT_NAME`**
  to the custom module's script. It has not been confirmed that every waybar
  build and configuration does. Without it, every bar highlights the same group
  as active — the behaviour the module has always had.
- **Idle and busy are read out of the window title.** The glyphs are hardcoded:
  `✳` for idle, `◐` and `◑` for busy. A terminal that does not propagate the
  title, a Claude Code version that uses different glyphs, or another program
  that happens to start its title with one of them will be counted wrongly.
- **Finding the shell is a heuristic.** The window's pid, its highest-numbered
  direct child, that child's `exe` matched against `/etc/shells`. A terminal
  running a command directly rather than under a login shell, a `tmux` or
  `screen` session (where the shell is a child of the server, not the terminal),
  and an `ssh` session all fail to resolve — the window is left where it is.
- **Projects are exactly one level under a single root.** `~/projects/foo` is a
  project; `~/work/foo` and `~/projects/a/b` as a project in its own right are
  not. `WG_PROJECTS_DIR` moves the root but there is only ever one.
- **Assignment happens once, when the window opens.** The daemon does not watch
  for `cd`, so a terminal that changes project mid-session keeps its workspace
  until the next `wingroup tidy`.
- **Overrides are keyed by Hyprland window address**, so they die with the
  window. That is deliberate — an address is reused — but it does mean a manual
  placement cannot survive a restart.
- **`"ignore-workspaces"` hides every named workspace** from the numbered
  indicator, not only wingroup's groups. If you keep named workspaces for other
  reasons, they disappear from that module too.
- **The waybar config edit is line-shaped.** `"modules-left"` on several lines,
  or a `"hyprland/workspaces": {` that does not open on its own line, and
  install refuses rather than guessing. Add the pieces by hand in that case.
- **Each bar refresh runs the module once per slot.** Eight processes, each
  querying `hyprctl clients`, walking the whole process table once with `ps`,
  and reading `/proc/<pid>/cwd` for every window. Refreshes are debounced to
  150 ms in the daemon, but a very busy desktop will feel it.
- **A group is one workspace.** It cannot span two, and Hyprland binds a named
  workspace to the monitor it was first created on — `wingroup monitor` is the
  workaround, not a fix.
- **`wingroup activate <n>` prefers the slot reading.** A group whose name is
  all digits and shorter than the group count cannot be activated by name.
- **Only local Hyprland windows exist.** Everything comes from `hyprctl
  clients`; there is no other entry source.
- **A session that predates the hook cannot be resumed by id.** The `/proc` scan
  learns the scope and the directory and never the session, so those crashes give
  you the project back and not the conversation. See [What cannot be
  recovered](#what-cannot-be-recovered).
- **Only systemd-oomd kills are detected.** `wingroup-oomwatch` matches
  `Failed with result 'oom-kill'` on the user journal. The kernel OOM killer, a
  `SIGKILL` from somewhere else, and a terminal you closed yourself all look the
  same from outside and none of them are recorded.
- **Crash records die at reboot.** Both runtime files live under
  `$XDG_RUNTIME_DIR`. A crash you have not dealt with by then is gone from the
  bar — which is deliberate: `restore-claude.sh` handles that case from the other
  end.
- **The scope is the join key, so a terminal outside one is invisible.** A
  session started from an `ssh` login, from a terminal not launched through
  uwsm/`xdg-terminal-exec`, or from anything else with no `.scope` in its cgroup
  path is never recorded and so never reported as crashed.
- **Uninstall reformats `~/.claude/settings.json`.** It is the one file whose
  content, but not whitespace, is restored — see [Uninstall](#uninstall).

## License

MIT — see [LICENSE](LICENSE).
