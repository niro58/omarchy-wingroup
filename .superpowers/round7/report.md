# Round 7 — three deliberate smells, cleared

Branch `feat/wingroup-implementation`. Suite 223 → 244 passing;
`shellcheck -x lib/*.sh bin/* install.sh uninstall.sh` clean throughout.

## 1. `wg_cwd_worktree` was dead — wired up, not deleted

Deleting it would have shifted column 9 of the nine-column window table and
broken all four consumers, so wiring it up was the only cheap option — and it
was also what the design spec asked for.

`lib/menu.sh` gained `wg_menu_where`, which builds the picker's last column as
`group` or `group:worktree`, falling back to `ungrouped`. It reads columns 5 and
8 through `wg_row_split`; the nine-column table and its ordering are untouched.

A worktree name is truncated at 16 characters with `…`. That column ends the
row and the one before it is padded to a fixed width, so it is the one field
that can push the layout around; a worktree is named after a branch and a branch
name has no upper bound. The result is left in `WG_WHERE` rather than printed:
`wg_menu_build` runs this once per open window, and a command substitution per
row is a fork per row.

    ✳ Everest-web full redesign                    everest
    ◐ Odtah vozidla price unit handling            everest:odtah-price
    ✳ Connectors spec                              plat:connectors-spec
    · niro@niro:~                                  ungrouped

Tests (`test/menu.bats`): a worktree window names its worktree; a non-worktree
window says nothing extra; two windows in different worktrees of one repo are
told apart (the design intent, stated as a test); `wg_menu_where` joins and
falls back; a long name is cut, one exactly at the limit is not.

**Revert observation.** Restoring `where="${WG_ROW[5]:-ungrouped}"`:
`not ok 6 a window sitting in a worktree names it next to its group` and
`not ok 8 two windows in different worktrees of one repo are told apart`.
Restored: 32/32.

## 2. Two constants duplicated — one definition, sourced

`lib/constants.sh` now defines `WG_SLOTS` and `WG_IDLE_HEAT_MAX` once.
`bin/wingroup-waybar` sources it via `$WG_LIB_DIR`; `install.sh` and
`uninstall.sh` — which also carried its own `WG_SLOTS=8`, a third copy the brief
did not mention — source it via `$WG_ROOT`, resolved from the script's own path,
so it works from any working directory. `install.sh` additionally asserts that
`WG_IDLE_HEAT_RAMP` has exactly `WG_IDLE_HEAT_MAX` entries, since the ramp's
colours stay where the CSS is written.

Tests (`test/constants.bats`, 5): exactly one definition of each name across
`lib/ bin/ ./*.sh`; both halves source it; install works when run from `/`; the
last slot the installer defines is the last slot the module answers for (proved
through the overflow tooltip, which is what actually ties the two numbers); and
every idle class the module emits has a rule, with no rule outrunning the
module's ceiling in either direction.

**Revert observation.** Re-duplicating the constants in `install.sh` with
divergent values (`WG_SLOTS=9`, `WG_IDLE_HEAT_MAX=3`): 4 of the 5 fail —
`each shared constant is defined in exactly one place`,
`install works when it is run from somewhere else entirely` (the ramp-length
guard firing),
`the last slot the installer defines is the last slot the module answers for`,
`every idle class the module emits has a rule…`. Restored: 5/5.

## 3. No lock on `state.json` — closed

`lib/state.sh` gained `wg_state_update <jq filter> [jq args…]`: it takes an
exclusive `flock` on `$WG_STATE_DIR/.state.lock`, reads, applies, writes and
releases. The lock sits beside the file it protects rather than in
`$XDG_RUNTIME_DIR`, so it is always in a directory we create and can write, and
two runs pointed at different state directories do not queue behind each other.

Every read-modify-write now goes through it:

- `bin/wingroup`: `cmd_monitor` (pin and clear), `cmd_new`, `cmd_rename`,
  `cmd_dissolve`, `cmd_send`, `cmd_toggle_auto`.
- `bin/wingroup-daemon`: the `closewindow` override deletion, and
  `wg_daemon_prune` (through `wg_state_prune_overrides`, which is now the
  in-place locked operation its only caller wanted rather than a pure filter
  the caller had to write back itself — its two tests in `test/state.bats` were
  updated to the new contract).

Left unlocked, deliberately:

- `wg_state_read`. It is not a read-modify-write, and the read-only path — the
  bar module, the picker, every resolve — must not queue behind a writer for a
  document it is about to re-read anyway. Its seeding and corrupt-recovery
  writes are creations, not modifications, and `mv` is already atomic.
- The daemon's cheap `.overrides[$a]` probe before a `closewindow` delete. It
  decides *whether* there is work, not what the work is; `wg_state_update`
  re-reads under the lock, so nothing is lost either way.
- `cmd_new`'s duplicate-name check, which stays a message rather than a
  guarantee. The filter itself refuses to append a second group of the same
  name, which is the half that has to hold under a race.
- `install.sh`'s `seed_state`, which creates the file and never modifies it.

The lock cannot wedge: it is an `flock` on an open descriptor, released by the
kernel when the holder dies, taken in exactly one function so there is no second
lock to deadlock against, and a waiter gives up after `WG_STATE_LOCK_WAIT`
(5s) with a message rather than hanging a keybind.

Unit tests (`test/state.bats`, 8 new): filter applied and committed; a failing
filter leaves the file alone; default seeding and corrupt recovery still behave
exactly as before *through* the update path; the lock is released for the next
writer; `wg_state_read` does not wait for a held lock; `wg_state_update` times
out loudly on a held lock and changes nothing; a writer killed with SIGKILL
while holding the lock does not wedge the next one.

### The concurrency test, before and after

`test/concurrency.bats` runs two (and then five) writers at once, each making a
change the others do not touch, and asserts every change survives. A `jq` shim
that sleeps 100 ms is put ahead of the real one on the racers' `PATH` only:
every step of a read-modify-write goes through `jq`, so this widens each
writer's open window to something a scheduler cannot miss. Without it the race
is real but microseconds wide, and the test would pass most of the time whether
the bug were there or not.

1. **a group created while a window closes is not lost** — the exact case the
   original review found: `wingroup new alpha` against the daemon's
   `closewindow>>aaa3` handler.
2. **two CLI writers each making a different change both survive** —
   `wingroup new` against `toggle-auto`, the latter started a quarter-second in
   so its whole read-modify-write falls inside the window the former leaves
   open. Started together it simply finishes first, which is not a race.
3. **a crowd of writers all land** — five concurrent `wingroup new`.

**Before** (the `flock` removed from `wg_state_update`, everything else
identical), three runs in a row: **all three fail, every time.** Test 1 loses
the daemon's override deletion; test 2 loses the toggle; test 3 ends with two or
three of the five groups in the file instead of five.

**After**: all three pass, three runs in a row. The lock unit test
`wg_state_update waits for a held lock and gives up rather than hanging` is the
one that fails if the `flock` call alone is neutered.

## Documentation

`README.md`: the picker section now describes and shows `group:worktree` rows
and the 16-character cut; the `state.json` section documents the lock, what it
protects, that reads never take it, and that a dead holder releases it; the
"Eight waybar slots" limitation now points at `lib/constants.sh`; the
"No lock between the daemon and the CLI" limitation is gone.

## Smells noticed and left alone

- `bin/wingroup` now carries eight `# shellcheck disable=SC2016` comments, one
  per `wg_state_update` call whose jq filter mentions a `$var`. ShellCheck knows
  `jq` takes expressions and does not know `wg_state_update` does. It is noise;
  the alternative is a file-level disable that would hide real findings.
- `docs/specs/` and `docs/plans/` still describe column 8 as unread and the
  state file as unlocked. They are a record of what was planned, not current
  documentation, so they were left as they are.
