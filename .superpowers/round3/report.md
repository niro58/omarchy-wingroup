# Round 3 — four fixes

Status: all four applied. Suite 190/190 (was 173/173). `shellcheck -x lib/*.sh bin/* install.sh uninstall.sh` clean.

Commits:
- `e4a2d83` fix 1 — ignore-workspaces pattern
- `a07f3ea` fixes 2–4 — filing on group creation, picker delete, send picker's new group

## Fix 1 — ignore-workspaces

Pattern is now `.*[^0-9].*` ("contains at least one non-digit"), per the mid-task
correction. `^[^0-9]` describes one character and so matched nothing under
whole-name matching; `^[^0-9].*` then missed a digit-leading group name such as
`3dprint`. The test reads the pattern back out of the installed config and asserts
behaviour: hides `plat mgmt template other 3dprint niro-3d-print`, leaves `1 6 10 0`
alone under both whole-name and search matching.

## Fix 2 — membership implies location

`wg_tidy_moves [group]` gained an optional filter; `wg_group_file_windows <group>`
dispatches its moves and prints the count. `cmd_new` calls it right after the state
write, and skips it entirely when the group has no projects (nothing can resolve to
it, and there is then no reason to build the window table). `WG_NEW_NAME` /
`WG_NEW_MOVED` carry the result out for the picker paths. `cmd_new_interactive`
appends "Filed N window(s) onto it." to the notification it already sent.

No subcommand adds a project to an existing group, so none was changed and none was
invented. `cmd_send` already moves the window it overrides.

## Fix 3 — picker delete

Action `delete` ("− remove a group…") sits between `new` and `tidy`. It opens
`wg_group_list_build` (groups only — no "+ new group…" on a chooser where one entry
off is the wrong group gone), then `wg_delete_confirm_build` with Cancel at index 0
so the entry under the cursor is the harmless one. Confirm action token is
`delete:<name>`. Then `cmd_dissolve`, unchanged, and a notification. No group at
all is reported rather than showing an empty walker.

## Fix 4 — send picker's new group

`cmd_send`'s `new` branch calls `cmd_new_interactive` (same `wg_menu_input` path, no
second implementation), then sends the window to `$WG_NEW_NAME`. A cancelled prompt
creates nothing and sends nothing.

## Revert observations

Each fix reverted in isolation, suite re-run, then restored:

- Fix 1 with `^[^0-9]`: install.bats 3 and 4 fail; with `^[^0-9].*`: 3 and 4 still
  fail (4 is the digit-leading case) while the numbered-workspace test passes — the
  behavioural test is what separates the two wrong patterns from the right one.
- Fix 2 (drop the `wg_group_file_windows` call in `cmd_new`): cli.bats 28, 29, 32 fail.
- Fix 3 (drop the `delete` entry and its dispatch): cli.bats 33, 34, 37 and menu.bats
  58, 59, 60 fail.
- Fix 4 (restore the `wg_die`): cli.bats 38, 39 fail.
- Restored each time: 0 failures.

## Test infrastructure

- `test/bin/walker-stub`: `$WG_WALKER_PICKS`, a space-separated list consumed one
  entry per invocation, for a flow with two pickers (choose, then confirm). Running
  past the end answers nothing, which is what cancelling looks like.
- `test/bin/hyprctl-stub`: `$WG_FIXTURE_CLIENTS` override.
- `test/fixtures/clients-new-group.json`: 0xaaa1 already on the everest workspace,
  0xaaa8 floating over everest-web — the already-filed and floating skips.

## Notes / concerns

- `cmd_new` prints "wingroup: filed N window(s) onto <name>" on stdout, which is
  visible at a terminal and goes nowhere from a keybind; the picker path notifies
  instead. Deliberate, mirroring how `wg_die` splits the two audiences.
- `cmd_new_interactive` seeds the new group's project from the *active* window. In
  the send flow that is normally the window being sent (SUPER+CTRL+G), but
  `wingroup send --address X` with a different window focused would seed from the
  focused one. The window still gets its override either way, so the outcome is
  right; only the seeding is arguably off. Left as is rather than forking the
  prompt path.
- Design smell, not touched: `cmd_new` now does two jobs (record the group, move
  windows), and its two out-parameters exist because bash command substitution
  cannot return them. Fine at this size; worth revisiting if a third caller appears.
