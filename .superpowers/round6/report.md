# Round 6 — public README

Documentation only. No file under `lib/`, `bin/`, `install.sh`, `uninstall.sh`
or `test/` was touched. Suite still 223/223.

## Changed
- `README.md` — rewritten for a reader who has never seen the tool.
- `docs/images/bar.png` — the supplied bar screenshot, referenced with alt text.

## Verification method
Every claim was checked against the source. Where reading was slower than
running, read-only commands settled it:
- `wg_menu_build` was run against sanitised fixtures (invented project names
  `alpha`/`beta`) to capture the picker's true layout for the fenced block.
- `bin/wingroup-waybar 0/1/5` was run to capture the real JSON, tooltip text and
  class arrays.
- `install.sh` was run with every path env var pointed at a scratch directory to
  capture the exact CSS, keybind, autostart and waybar-config text it writes.
- `bin/wingroup new` / `activate` / `monitor` were run to capture real output and
  the pretty-printed shape `state.json` takes after a write.

## Claims from the old README that were corrected
- The old text implied `catchall` applies to the resolver generally. It does
  not: only `wg_daemon_open_window` reads it. `tidy` never applies a catchall.
  Now stated explicitly.
- The old "Known limitations" listed one item (8 slots). Nine more real ones were
  found in the code and added.
- Uninstall was described as restoring "the blank line install prepended to each
  block". The waybar config block is inserted after the opening brace with no
  preceding blank line; softened to "any blank line".
- `bash` version: the daemon uses `EPOCHREALTIME`, which is bash 5.0+, not 4.x.

## Wanted to document but found untrue / absent in the code
- **No CLI for `catchall` or `follow`.** Both are documented as hand edits.
- **The worktree column is dead code.** `wg_cwd_worktree` fills column 8 of
  `wg_window_table` and nothing anywhere reads column 8. Worktrees resolve to
  their parent project purely because `wg_cwd_project` takes the first path
  segment. The README says that, and says nothing about a worktree feature.
- **No `wingroup` command lists groups.** There is no `list`/`status`. The
  picker and the bar are the only readouts; the README does not invent one.
- **`pgrep` is not a dependency.** It appears only in comments in
  `lib/resolve.sh`; it is mentioned in Troubleshooting as user advice, not in
  Requirements.
- Nothing sets `WG_SLOTS` at runtime — it is a constant in two files that must
  agree. Documented as "8" rather than as configurable.

## Smells flagged (separate issue, not fixed here)
- `wg_cwd_worktree` and column 8: dead code.
- `WG_SLOTS` and `WG_IDLE_HEAT_MAX` are duplicated constants in
  `bin/wingroup-waybar` and `install.sh`, kept in sync by comment only.
- No lock between `wingroup-daemon` and `bin/wingroup` around `state.json`
  writes; the last-writer-wins race is acknowledged in a code comment and is now
  in Known limitations.
