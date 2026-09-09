#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  export WG_RESTORE_LOG="$WG_TMP/restore.log"
  : >"$WG_RESTORE_LOG"
  # The daemon looks for this exact path; it is spelled out here rather than
  # read off either script, so that the two agreeing on it is what is tested.
  WG_FLAG="$XDG_RUNTIME_DIR/wingroup-restoring"
  export WG_RESTORE_SCRIPT="$WG_ROOT/test/bin/restore-stub"
  export WG_RESTORE_SETTLE=0
  export PATH="$WG_ROOT/bin:$PATH"
}

teardown() { wg_teardown_tmp; }

@test "restore runs the session restore script" {
  "$WG_ROOT/bin/wingroup-restore"
  run cat "$WG_RESTORE_LOG"
  [[ "$output" == restore* ]]
}

@test "restore tidies afterwards so restored terminals land in their groups" {
  "$WG_ROOT/bin/wingroup-restore"
  run bash -c "wc -l <'$WG_DISPATCH_LOG'"
  [ "$output" -eq 4 ]
}

@test "restore passes its arguments through and tidies nothing on a dry run" {
  "$WG_ROOT/bin/wingroup-restore" --dry-run
  run cat "$WG_RESTORE_LOG"
  [ "$output" = "restore --dry-run" ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "restore succeeds and tidies nothing when no restore script is installed" {
  export WG_RESTORE_SCRIPT="$WG_TMP/does-not-exist.sh"
  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# Fourteen terminals respawning at login, each one followed onto its group's
# workspace, is the desktop bouncing around for a minute. The flag is how the
# restore tells the daemon to keep filing them silently.
@test "restore suppresses following while it spawns terminals" {
  "$WG_ROOT/bin/wingroup-restore"
  run cat "$WG_RESTORE_LOG.flag"
  [ "$output" = "flag present" ]
}

@test "restore clears the suppression when it is done" {
  "$WG_ROOT/bin/wingroup-restore"
  [ ! -e "$WG_FLAG" ]
}

# A restore script that dies must not leave following switched off for the rest
# of the session -- the user would silently lose windows again, which is the bug
# this whole setting exists to fix.
@test "a failing restore script still clears the suppression" {
  printf '#!/usr/bin/env bash\nexit 3\n' >"$WG_TMP/failing-restore"
  chmod +x "$WG_TMP/failing-restore"
  export WG_RESTORE_SCRIPT="$WG_TMP/failing-restore"
  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 3 ]
  [ ! -e "$WG_FLAG" ]
}

@test "a dry run clears the suppression too" {
  "$WG_ROOT/bin/wingroup-restore" --dry-run
  [ ! -e "$WG_FLAG" ]
}

# tidy is a bulk move by definition, and it goes through bin/wingroup rather
# than the daemon: it stays silent whatever the follow setting says.
@test "the tidy pass files restored terminals silently" {
  "$WG_ROOT/bin/wingroup-restore"
  run bash -c "grep -c '^movetoworkspacesilent ' '$WG_DISPATCH_LOG'"
  [ "$output" -eq 4 ]
  run bash -c "grep -c '^movetoworkspace ' '$WG_DISPATCH_LOG' || true"
  [ "$output" -eq 0 ]
}
