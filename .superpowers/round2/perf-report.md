# Round 2 — four reported issues

Branch `feat/wingroup-implementation`. Suite: **142/142 bats**, `shellcheck -x
lib/*.sh bin/* install.sh uninstall.sh` clean.

---

## Fix 1 — the picker took 1.6 s to appear

### What it was spending the time on

Measured on the seven-window fixture set, back to back, same machine, three
runs each:

| | before | after |
| --- | --- | --- |
| `wg_window_table` | 347 – 425 ms | 100 – 107 ms |
| `wg_menu_build` (what `SUPER+G` runs) | 580 – 591 ms | 141 – 147 ms |

Per window, the old build spent: two `jq` processes (override lookup, then
project lookup), one `pgrep -P` **plus** a `tail`, two `readlink -f`, and a
`grep` of `/etc/shells`. Seven windows meant sixteen `jq` processes and seven
full walks of the process table. On this machine a `jq` costs ~4 ms and a
`pgrep` ~33 ms, so the process-table walks were the single biggest line item
and `jq` the second.

`wg_menu_build` then added its own: per group, two `awk` and two `wc` and a
`jq` for the label; per window, **four** `awk` processes, one per column it
wanted.

### What changed

- `wg_state_map_load` builds both state lookups — `o:<address>` → override
  group, `p:<project>` → owning group — in **one** `jq`, into an associative
  array. Table builds now spawn three `jq` regardless of window count (state
  read, the maps, the client list), where the old code spent 1 + 2N.
- `wg_children_load` replaces the per-window `pgrep -P <pid> | tail -n1` with
  one `ps -eo ppid=,pid=` per table build, reduced to parent → highest-numbered
  child. That is the child `pgrep | tail -n1` picked: pgrep lists matches in
  ascending pid order (verified on this machine). It is loaded from
  `wg_window_table`, not lazily from `wg_window_cwd`, because that function
  runs inside a command substitution — a map built there dies with the
  subshell, and every window would pay for its own walk. It is rebuilt on every
  build rather than cached, because the daemon asks for the same row again and
  again while a terminal's shell is still spawning.
- `/etc/shells` is read once into `$WG_SHELLS` instead of a `grep` per window.
- The two `readlink -f` are one `readlink -f cwd exe`; a result that is not
  exactly two lines is the same "give up" the two separate failures reached.
- `wg_row_split` splits a row into `WG_ROW[1..9]` with parameter expansion —
  no `cut`, no `awk`. `lib/menu.sh` and `bin/wingroup-waybar` use it. It is
  *not* a `IFS=$'\t' read -r a b c ...`, for the documented reason: tab is IFS
  whitespace, so an empty interior column shifts every column after it.
- `wg_menu_build` counts every group in one pass over the table, and gets names
  and labels from one `jq`.

An equivalent bash `/proc` walk was tried first and was **worse** (85 ms
against `ps`'s 40 ms): `read` from a `/proc` file is byte-at-a-time, and the
greedy `${stat##*") "}` needed to skip a comm containing spaces costs more than
the fork it saves.

### Proof the nine-column TSV is unchanged

`wg_window_table` and `wg_window_row` output was captured (through `cat -A`, so
every tab and line end is visible) for: real `/proc` lookups and the stubbed
cwd map, against `state.json`, `state-many.json`, an empty state, and a state
carrying a project name with a tab in it plus an extra override — 144 lines,
before and after. **`diff` is empty.** Re-checked after every subsequent
change.

### Tests that pin it

`test/resolve.bats`: a table build spawns fewer than 8 `jq` (the old code spent
16), the count does not change between a seven-window and a one-window build,
the process table is walked exactly once per build, and `wg_row_split` keeps
empty interior columns in place. The `jq` counter is a shim on `PATH`
(`wg_count_jq` in `test/helper.bash`).

### Left alone, deliberately

`wg_tidy_moves` in `bin/wingroup` and the daemon still pull columns with `cut`.
They are correct and out of the reported scope; `wg_row_split` is there when
someone wants them.

## Fix 2 — launch walker the way Omarchy does

`wg_menu_run` now runs Omarchy's `omarchy-launch-walker` when it exists (which
starts `elephant` and the walker service if they are not up, and applies
`--width 644 --maxheight 300 --minheight 300`), and otherwise calls `walker`
itself with those same flags. `-d -i -p <prompt>` is unchanged in both. The
launcher is skipped when `$WG_WALKER` names a specific binary, so an explicit
override still wins — and `test/helper.bash` points `$WG_WALKER_LAUNCHER` at a
path that does not exist, so no test can put a real walker on the screen.

`cmd_menu` takes `$XDG_RUNTIME_DIR/wingroup-menu.lock` with `flock -n` and
exits 0 quietly if it is held — same pattern as `wingroup-daemon`. Two
`SUPER+G` presses no longer stack two pickers.

## Fix 3 — the bar reports what is free

The superscript is the **idle** count, and the tooltip reads
`template — 3 windows · 2 idle · 1 busy`. A `plain` window (a terminal with no
Claude session) counts towards the total and towards neither of the other two.
`lib/menu.sh`'s group entries carry the same three numbers. The `Projects:` and
slot-7 overflow lines are untouched. Existing waybar tests were rewritten to
the new semantics rather than duplicated.

## Fix 4 — "active" considered only the focused monitor

`bin/wingroup-waybar` reads `hyprctl monitors -j` instead of
`activeworkspace`. A group is `active` when its workspace is the active
workspace of the **focused** monitor, and `visible` when it is the active
workspace of any other monitor. `install.sh` styles `visible` at
`opacity: 0.85`, between the 0.55 default and the focused group's `1` + bold.

Fixtures: `monitors.json` is exactly the reported state (eDP-2 → `3`, not
focused; DP-1 → `template`, focused); `monitors-laptop-focused.json` is the
same two monitors with focus moved to the laptop — the case that used to lose
the highlight; `monitors-single.json` is one monitor. `hypr.bats` asserted that
`monitors` was an *unhandled* stub query, so that test now uses `devices`.

## Revert observations

Each fix was reverted in place, its tests watched to fail, and restored.

| reverted | failing tests |
| --- | --- |
| Fix 1 (map + one process walk) | resolve.bats 22, 23, 24 |
| Fix 2 walker launch | menu.bats 13, 14 |
| Fix 2 picker lock | cli.bats 18 |
| Fix 3 idle counts | waybar.bats 2, 3, 11, 12; menu.bats 17, 18 |
| Fix 4 monitors + CSS | waybar.bats 7, 8, 10; install.bats 27 |

## Assumptions and things worth knowing

- **`ps` replaces `pgrep` as a dependency.** Nothing shipped calls `pgrep` any
  more (`pkill` is still used to signal waybar). README's requirement list was
  updated. Both are procps.
- **The daemon's single-window path is a wash**, not a win: one `ps` (~40 ms)
  where it used to run one `pgrep` (~33 ms). The gain is entirely in
  multi-window builds, which is where the complaint was.
- **A cwd containing a newline is now skipped** rather than emitted. It used to
  produce a row with an embedded newline, which would have corrupted the table
  anyway.
- **`WG_STATE_MAP` keys are prefixed `o:`/`p:`** because a bash associative
  array subscript of exactly `@` or `*` means something else, and a project is
  a directory name the user chose.
- The globals in `lib/resolve.sh` are `declare -g`: the libraries are sourced
  from inside `setup()` in the bats suite, and a plain `declare -A` there would
  be function-local and gone by the time a test ran.
- Verified against live processes that the new `wg_window_cwd` returns exactly
  what the old `pgrep`-based one did for a terminal-with-a-shell tree, and
  empty in the same cases.
