#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  export WG_RESTORE_LOG="$WG_TMP/restore.log"
  : >"$WG_RESTORE_LOG"
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
