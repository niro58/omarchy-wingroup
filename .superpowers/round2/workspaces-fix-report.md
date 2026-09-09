# Correcting change 5: filter the dots, keep the numbers

## What was wrong

Commit `bc1b9d4` read "not have the dots, only names" as "take the numbered
workspace indicator off the bar". It removed `"hyprland/workspaces"` from
`modules-left` outright, and taught `uninstall.sh` to put the line back from a
verbatim recording (`// wingroup-modules-left:`) stashed inside the marked block.

The numbers were never the problem. They are the user's own, and they want them.
The problem is that a group *is* a named Hyprland workspace, and Omarchy's
`hyprland/workspaces` module keys `format-icons` by workspace *number* — so every
group falls through to the `default` glyph and draws as an anonymous dot, one per
group, right beside that group's own name in the wingroup strip. Two views of the
same thing; the dot is the useless one.

## What it does now

Bar order, left to right: Omarchy menu icon → numbered workspaces 1–0 → group strip.

`install.sh` makes three edits to the waybar config in one awk pass:

1. the eight `custom/wingroupN` definitions, after the line that opens the
   top-level object (unchanged);
2. the eight slots appended to `modules-left`, after whatever is already there —
   `"hyprland/workspaces"` stays, and stays where it sat, which is exactly what
   puts the numbers before the groups (this is the pre-`bc1b9d4` behaviour,
   restored);
3. **new:** `"ignore-workspaces": ["^[^0-9]"]` inserted inside the
   `"hyprland/workspaces"` object, wrapped in the project's
   `// >>> wingroup` / `// <<< wingroup` markers.

`ignore-workspaces` takes regexes matched against the workspace *name*, so
`^[^0-9]` drops exactly the named ones and leaves 1–10 untouched. Verified
supported by the waybar build this targets:
`strings $(command -v waybar) | grep -x ignore-workspaces` matches (0.15.0).

The anchor for the new edit is the object's opening line, which must read
`"hyprland/workspaces": {`. If it is not found, `install.sh` reports which part
of the edit failed and exits non-zero with the file byte-unchanged — the same
shape as the two anchor checks that were already there. It does not silently skip.

## Reversal

The new block uses the marker pair `strip_block` already looks for, and
`strip_block` strips *every* block it finds in the file, so it needed no new
machinery. Its closing marker carries no ` no-eof-nl` suffix — only the
definitions block does, and `strip_block` reads the flag off whichever closing
marker has it.

So `restore_modules_left` and the `// wingroup-modules-left:` recording that
`bc1b9d4` added are both gone. `uninstall.sh` is back to
`strip_block` + `strip_waybar_slots`, and the round-trip is byte-exact — proven
by `cmp` on all four edited files, including a fixture with no trailing newline.

## Fixtures

Every waybar fixture now carries a real `"hyprland/workspaces"` object, because
install legitimately fails without one:

- `waybar-config.jsonc`, `waybar-config-leading-comment.jsonc`,
  `waybar-config-no-eof-nl.jsonc`, `waybar-config-no-comma.jsonc` — object added.
  The no-eof-nl fixture still ends without a newline; the no-comma fixture still
  ends on a `modules-left` line with no trailing comma.
- `waybar-config-workspaces-only.jsonc` — deleted; it existed only to exercise
  "removing the module would empty modules-left", a failure mode that no longer
  exists.
- `waybar-config-no-ws-object.jsonc` — new. References the module from
  `modules-left` but defines no object for it, so the ignore line has nowhere to go.

## Tests

`test/install.bats`

- `install keeps hyprland/workspaces where it was and appends the slots after it`
  — asserts the whole `modules-left` line verbatim, which pins the ordering:
  `custom/omarchy`, `hyprland/workspaces`, then `custom/wingroup0..7`.
- `install hides the named group workspaces from the numbered indicator` —
  `grep -A3` off the object's opening line, so adjacency (not mere presence) is
  what is checked; and exactly one occurrence in the file.
- `uninstall takes the ignore-workspaces line back out` — replaces the old
  "puts the indicator back" test; also re-asserts the original `modules-left` line.
- `install is idempotent` — extended: a second run must not duplicate the
  ignore line, nor append a second set of slots.

`test/install-edgecases.bats`

- `install fails loudly when there is no hyprland/workspaces object to edit` —
  replaces "would have emptied it". Non-zero exit, the message names both
  `ignore-workspaces` and the `"hyprland/workspaces": {` line it wanted, and
  `cmp` proves the file was not touched.
- `both marked blocks come back out byte for byte in a config with no trailing
  newline` — replaces the change-5 no-eof-nl test. Two marked blocks in one file
  now, and `strip_block` has to take both while the missing trailing newline
  still comes out the other side missing.

Suite: **173/173** (was 172; net +1). `shellcheck -x lib/*.sh bin/* install.sh
uninstall.sh` clean.

## Revert observation

With `test/` and `test/fixtures/` left at the new state and `install.sh` +
`uninstall.sh` reverted to `bc1b9d4`'s versions, five tests fail:

```
not ok 2  install keeps hyprland/workspaces where it was and appends the slots after it
not ok 3  install hides the named group workspaces from the numbered indicator
not ok 17 install is idempotent
not ok 30 install fails loudly when there is no hyprland/workspaces object to edit
not ok 31 both marked blocks come back out byte for byte in a config with no trailing newline
```

Restoring the two scripts returns all 32 to passing. One caveat worth recording:
`ok 4 uninstall takes the ignore-workspaces line back out` passes under the
revert too — vacuously, because the old code never wrote an ignore line and its
`restore_modules_left` put the `modules-left` line back. It is a real assertion
about the new behaviour, but it is not the test that catches this regression;
tests 2, 3 and 31 are.

## Concern: the already-installed machine

`restore_modules_left` is gone, so the new `uninstall.sh` cannot undo an install
performed by `bc1b9d4`. The user's live `~/.config/waybar/config.jsonc` is in
exactly that state: `modules-left` reads
`["custom/omarchy", "custom/wingroup0", ...]` with `"hyprland/workspaces"` already
stripped out, and the `// wingroup-modules-left:` recording sitting in the block.

Running the new `uninstall.sh` there strips the recording along with the block and
removes the slots, leaving `"modules-left": ["custom/omarchy"],` — the numbered
indicator would *not* come back.

Remediation, before running the new install: either run `bc1b9d4`'s `uninstall.sh`
first (`git show bc1b9d4:uninstall.sh`) to get a clean config back, or hand-edit
`modules-left` to reinsert `"hyprland/workspaces", ` and delete the recording line
and the slots. This is a one-machine migration, not a code defect, so it is
flagged rather than coded around — adding a compatibility shim for a marker that
existed for one commit would be permanent weight for a transient problem.

## Unchanged constraints

- `modules-left` must still be a single line ending in `],`.
- The `"hyprland/workspaces"` object must open on a line of its own ending in `{`.
  This is a *new* constraint, and the reason for the new loud failure.
