# omarchy-wingroup — round 2 features report

Branch `feat/wingroup-implementation`. Suite went 142/142 → **172/172**;
`shellcheck -x lib/*.sh bin/* install.sh uninstall.sh` stays clean.

---

## Change 1 — "+ new group…" actually creates a group

`cmd_menu`'s `new` branch called `wg_die`, which writes to a stderr nobody is
attached to when the picker was opened from `SUPER+G`. The belief behind it —
walker's dmenu mode has no text entry — was wrong: `walker -I/--inputonly` is
dmenu mode showing nothing but the input box.

**`lib/menu.sh`**
- `wg_menu_picker` factored out of `wg_menu_run`: it leaves the launch command
  in `WG_PICKER`, so the input prompt gets the same Omarchy-launcher detection,
  the same `--width 644 --maxheight 300 --minheight 300`, and the same
  `$WG_WALKER` override the picker has. One copy of that decision, not two.
- `wg_menu_input <prompt>` runs `-d -I -p "$prompt"` with stdin closed (there
  are no entries in input-only mode), keeps the first line, and trims it.
  Cancelled and empty are indistinguishable to the caller, and there is no
  reason for them not to be.

**`bin/wingroup`** — `cmd_new_interactive`:
1. prompt; empty ⇒ `return 0`, silently;
2. resolve the focused window through `wg_hypr_query activewindow` →
   `wg_window_row` → column 7 (`cut`, never a multi-variable `read`);
3. create through `cmd_new`, so slugification and the duplicate refusal are
   literally the ones `wingroup new` has (a duplicate reaches `wg_die`, which
   now notifies — see change 3);
4. seed the project only when nothing else owns it (`wg_project_group` against
   the pre-create state), and say which of the three outcomes happened with
   `notify-send`.

**Test stub** — `test/bin/walker-stub` now answers by mode: `-I`/`--inputonly`
prints `$WG_WALKER_INPUT`, anything else keeps printing `$WG_WALKER_PICK`.
Because the check is on the argument list, the input path works through
`walker-launcher-stub` too. New fixtures: `activewindow.json`,
`activewindow-ungrouped.json`, `activewindow-none.json`, and an `activewindow`
case in `hyprctl-stub` (which `cmd_send` had always needed but no test reached).

## Change 2 — actions moved up

`wg_menu_build` now emits **groups → new/tidy/toggle-auto → separator →
windows**. Groups stay first because switching is the common case; the actions
move from ~row 20 (15 windows open) to rows 3–5.

The action vocabulary is unchanged (`group:`, `window:`, `new`, `tidy`,
`toggle-auto`, `noop`). The index contract changed, so the tests asserting
against it were rewritten to the new layout rather than worked around:
`test/menu.bats` now asserts the whole column-1 sequence and the exact rows the
actions occupy; `test/cli.bats`'s "menu focuses the window the picker returned"
went from `WG_WALKER_PICK=5` to `7`.

## Change 3 — failures from picker actions are visible

`wg_notify` (stubbable through `$WG_NOTIFY_CMD`, exactly like `$WG_REFRESH_CMD`)
and `wg_has_tty`. `wg_die` always writes stderr; when neither stdout nor stderr
is a tty it also notifies. A CLI invocation at a terminal is unchanged — a
desktop notification for a message already on screen is noise.

`test/helper.bash` points `WG_NOTIFY_CMD` at `test/bin/notify-stub` for every
test, so no test can put a notification on the real desktop. The
terminal-present branch is covered by running under `script -qec` (skipped if
util-linux `script` is absent).

## Change 4 — pin a group to a monitor

- `wingroup monitor <group> <name>` / `<group> -`. The name is validated
  against `hyprctl monitors`; a miss fails with the available names listed.
- `cmd_activate`, for a group with a pin: `focusmonitor <mon>` → look up where
  the workspace actually lives → `moveworkspacetomonitor` only if that is a
  different monitor → `workspace name:<group>`. The move is the whole feature:
  Hyprland binds a named workspace to whatever monitor was focused when it was
  created, so without it a group first opened on the laptop stays there.
- **`workspaces`, not `monitors`, answers "where does this workspace live".**
  `monitors[].activeWorkspace` only reports what is *displayed*; a group
  workspace that exists but is not on screen still belongs to a monitor, and
  that is exactly the case the move exists for. `hyprctl-stub` gained a
  `workspaces` case and a `workspaces.json` fixture (everest on eDP-2, plat on
  DP-1, drivora absent).
- `monitor: null` takes none of that path — asserted, not assumed.
- Surfaced in the picker: the group entry gains ` · on DP-1` when pinned.
- Dispatch-log assertions cover pinned-and-elsewhere (3 dispatches, in order),
  pinned-and-already-right (2 dispatches, no redundant move), pinned-but-no-such
  -workspace-yet, and unpinned-beside-a-pinned-group (1 dispatch).

## Change 5 — numbered workspace indicator removed at install

`install.sh` now drops `"hyprland/workspaces"` from the `modules-left` line,
taking whichever separator the entry carries with it (leading comma, trailing
comma, or neither).

The reversal is not an attempt to undo two edits in sequence. Install records
the `modules-left` line **verbatim** inside its own marked block:

```
  // wingroup-modules-left:  "modules-left": ["custom/omarchy", "hyprland/workspaces"],
```

`uninstall.sh`'s new `restore_modules_left` puts that line back, then
`strip_block` removes the recording along with the rest of the block. That is
byte-exact by construction, and it subsumes the slot removal. Ordering matters
twice: it runs *before* `strip_block` (which deletes the recording), and its
awk normalises the file to a trailing newline that `strip_block`'s existing
`eof_flag`/`truncate -s -1` machinery then strips back off — so the
no-trailing-newline guarantee is preserved without new machinery.
`strip_waybar_slots` stays as a fallback for a config whose block was deleted
by hand.

Two smaller things came with it:
- Values now reach both awks through **`ENVIRON`, not `-v`**. An `-v`
  assignment runs escape processing over its value, and the block and the
  recorded line are verbatim text that must survive unaltered. (Latent, not
  observed — a backslash in a waybar config is unlikely.)
- New loud failure: removing `"hyprland/workspaces"` from a `modules-left` that
  held nothing else leaves `[`, and appending the slots to that gives `[, …`,
  which is not JSON. Detected after the edit, reported, file untouched — the
  same shape as the existing missing-anchor checks. Fixture:
  `waybar-config-workspaces-only.jsonc`.

The recorded line is itself a `"modules-left"` line and sits *above* the real
one, so `restore_modules_left` skips it explicitly; install's validation greps
are unaffected (the recording contains no `custom/wingroup0`).

---

## Revert observations

Each change was reverted in isolation, the suite run, and the change restored.

| Reverted | Failing tests |
| --- | --- |
| 1 — `new` branch back to `wg_die` | cli 21–26, 29 |
| 2 — actions back below the windows | menu 46, 47 (layout) + cli 21–25, 27, 29 |
| 3 — `wg_die` stops notifying | cli 28, 29 |
| 4a — monitor pin out of `cmd_activate`/dispatch | cli 31, 32, 33, 35, 36, 37 |
| 4b — ` · on <mon>` out of the picker entry | menu 9 |
| 5 — `hyprland/workspaces` removal out of install | install 2; edgecases 29, 30 |

Restored: 172/172, shellcheck clean.

## Notes and out-of-scope observations

- **`cmd_send`'s picker still has a dead `+ new group…`.** Sending a window to
  a group offers the entry and answers `wg_die "create the group first"`. It is
  now *visible* (change 3 notifies it), but it is not interactive. Change 1's
  brief named `cmd_menu`, so this was left alone deliberately. Making it prompt
  and then send into the group it just made is a small, obvious follow-up.
- **`README.md` usage block alignment.** The `dissolve` line in `wg_usage` had
  one space too many; fixed while adding `monitor` beside it.
- **The `wingroup-waybar` tooltip does not mention the pin.** The brief asked
  for the picker; the bar was left alone.
- **`hyprland/workspaces` elsewhere.** Only the `modules-left` line is touched.
  A config listing the module in `modules-center`/`-right` keeps it, which is
  the conservative reading of "remove it from the `modules-left` array".
