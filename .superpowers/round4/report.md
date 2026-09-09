# Round 4 — two user-reported bugs

Branch `feat/wingroup-implementation`, worktree `/home/niro/projects/omarchy-wingroup-impl`.
Commits: `683ffb8` (fix 1, following), `dca7e08` (fix 2, per-screen highlighting).
Suite 208/208 (was 190/190); `shellcheck -x lib/*.sh bin/* install.sh uninstall.sh` clean.
Nothing pushed.

## Fix 1 — a newly opened window silently vanished

`bin/wingroup-daemon` filed every window with `movetoworkspacesilent`, so a terminal
the user had just deliberately opened was moved to its group's workspace while the
user stayed where they were. From their seat the window was simply gone; they had
switched `auto` off to stop losing windows.

What changed:

- `lib/state.sh` and `install.sh` seed `{"auto":true,"follow":true,"catchall":null,
  "groups":[],"overrides":{}}`. Key order, corrupt-recovery and the write guards are
  untouched. The daemon reads `follow` as `!= "false"`, so a state file written before
  the key existed behaves as `follow: true` rather than erroring — the seeded test
  fixture deliberately still has no `follow` key, and a test asserts that.
- `wg_daemon_should_follow` gates the dispatch. It returns false when `follow` is
  false, when the restore flag file exists, or while inside the startup grace period.
- Following dispatches `movetoworkspace`; not following keeps `movetoworkspacesilent`.
- `bin/wingroup-restore` creates `${XDG_RUNTIME_DIR:-/tmp}/wingroup-restoring`
  (overridable with `WG_RESTORE_FLAG`, read by both sides) before running the restore
  script and removes it from an `EXIT` trap, so a failed, dry-run or killed restore
  cannot leave following switched off for the session.
- `WG_FOLLOW_GRACE` (default 10, whole seconds) is measured from `WG_START_MS`, set
  when the daemon *loads* — the daemon is started by Hyprland's autostart in the same
  burst as the terminals the grace period exists to cover, so load time is the honest
  origin. It also means the bats suite, which sources the daemon, starts the clock in
  `setup`; `daemon.bats` sets `WG_FOLLOW_GRACE=0` there so the default under test is
  "the burst is over", and the two burst tests put it back explicitly.
- `wingroup tidy` was already silent (it goes through `bin/wingroup`, never the
  daemon) and a `restore.bats` test now pins that: after a restore, every dispatch is
  a `movetoworkspacesilent`, and there is no bare `movetoworkspace` at all.
- The once-only guard, the floating skip and the `auto` check are unchanged. Two
  existing tests (floating; already on its group's workspace) assert an *empty*
  dispatch log and now run with following on, which makes them the stronger statement
  that following changes how a window is moved, never whether it is.

### `movetoworkspace` vs silent-plus-`workspace`

`movetoworkspace name:<g>,address:<a>` — one dispatch, chosen over
`movetoworkspacesilent` followed by `workspace name:<g>`:

1. **Atomicity.** Two dispatches leave a gap the user (and the compositor) can act in.
   If they switch workspace or focus a different monitor between them, the second
   dispatch lands somewhere unintended, and the window ends up on one workspace while
   the switch happens on another.
2. **Monitor correctness.** `workspace name:<g>` acts on whichever monitor has focus
   at that instant. Hyprland binds a named workspace to the monitor it was created on,
   so a bare `workspace` switch can *pull the group's workspace onto the wrong screen*
   — the exact failure `wingroup monitor` exists to prevent. `movetoworkspace` moves
   to the workspace where it already lives.
3. **Focus target.** After a plain `workspace` switch, focus lands on whatever that
   workspace last had focused; the window the user actually opened may not be it.
   `movetoworkspace` leaves the moved window focused, which is the point.

The cost is that `movetoworkspace` is a single, coarser primitive with no way to move
without switching — which is why the silent variant is still what every suppressed
path dispatches, rather than trying to undo a switch afterwards.

## Fix 2 — the bar marked the same group active on every monitor

`bin/wingroup-waybar` derived `active`/`visible` from the globally focused monitor, so
both bars rendered identically.

- When `WAYBAR_OUTPUT_NAME` is set, that monitor is the reference: `active` when the
  group's workspace is *its* active workspace, `visible` when the workspace is active
  on some other monitor, otherwise no class (falling through to `busy`).
- When it is unset, the reference monitor is the focused one — today's behaviour
  exactly. This path is not a fallback in name only: it has its own test asserting
  both the `active` and the `visible` outcome, because it has not been confirmed on
  the live machine that waybar 0.15.0 exports the variable for a single-bar config.
- An output name the compositor does not list (a monitor unplugged between the two
  questions) degrades to "visible if the group is on screen anywhere" rather than to
  no class — hence the `// null` on the `$self` binding, since `first(empty)` would
  otherwise make the whole jq program produce nothing.
- Cost is unchanged: still one `hyprctl monitors` query and one `jq`, now printing two
  lines (the reference monitor's workspace, and how many *other* monitors show this
  group) read with `mapfile`. No multi-variable `IFS=$'\t' read` anywhere.
- `test/helper.bash` unsets `WAYBAR_OUTPUT_NAME` in `wg_setup_tmp`, so the class tests
  cannot be perturbed by the screen a real desktop session happens to run them on.

Against the existing two-monitor fixture (`eDP-2` ws `3` unfocused, `DP-1` ws
`template` focused): `WAYBAR_OUTPUT_NAME=DP-1` → `active`; `=eDP-2` → `visible`;
unset → `active` (global focus), and `visible` against `monitors-laptop-focused.json`.

## Revert observations (each fix removed, its tests watched to fail)

| Reverted | Failing tests |
| --- | --- |
| follow branch → always `movetoworkspacesilent` | daemon 1, 2, 3, 6, 8 |
| restore-flag check in `wg_daemon_should_follow` | daemon 7 (`filed while a restore is running`) |
| grace-period check | daemon 5 (`filed during the startup grace period`) |
| `follow == false` check | daemon 4 (`follow=false keeps the silent move`) |
| `wingroup-restore` no longer sets the flag | restore 5 (`suppresses following while it spawns terminals`) |
| flag set but trap removed (never cleared) | restore 6, 7, 8 |
| `follow` dropped from the default state | state 1, 2, 4 |
| waybar ignores `WAYBAR_OUTPUT_NAME` | waybar 11, 14 |

Every fix was restored immediately afterwards and the suite re-run green.

Note on the waybar row: reverting fails 11 (`eDP-2` should be `visible`) and 14 (the
unknown-output degradation) but *not* 10 (`DP-1` → `active`), because `DP-1` is the
focused monitor in the fixture and the two rules agree there. 11 is the discriminating
test; 10 is there so the pair reads as one statement.

## Concerns

- **`WAYBAR_OUTPUT_NAME` is still unverified on the live machine.** The fallback is
  correct and tested, so nothing regresses if waybar does not export it — but the fix
  the user asked for only takes effect if it does. Worth one check: add
  `"exec": "echo $WAYBAR_OUTPUT_NAME"` to a scratch module, or run
  `strings $(which waybar) | grep WAYBAR_OUTPUT_NAME`.
- **The user has `auto: false` in their live state.** Fix 1 is invisible until they
  run `wingroup toggle-auto`. Worth telling them.
- **`WG_FOLLOW_GRACE` must be whole seconds.** `(( now - WG_START_MS >= GRACE * 1000 ))`
  aborts on a fractional value. Documented as whole seconds; not validated, because a
  daemon that refuses to start over a malformed tuning knob is worse than one that
  errors on the first window.
- **The restore flag is a file with no owner.** If `wingroup-restore` is `SIGKILL`ed
  (not caught by the `EXIT` trap), the flag survives until something removes it and
  following stays off for the session. A pid-stamped flag the daemon could validate
  would close that; it did not seem worth the machinery for a failure mode that needs
  a `kill -9`.
- **Following and `wingroup monitor` have not been exercised together on real
  hardware.** `movetoworkspace` should switch on the monitor the workspace lives on,
  which is what the pin arranges — but the fixtures cannot prove Hyprland's behaviour
  when a pinned group's workspace is on the other screen.
- **Pre-existing smell, not touched:** `wg_daemon_open_window` now reads `state`
  through three separate `jq` invocations (`.auto`, `.catchall`, `.follow`). Only the
  first is on the common path and the third only runs when a move is actually
  happening, so this is not hot — but one `jq` producing all three would be tidier.
