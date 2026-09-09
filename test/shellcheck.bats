#!/usr/bin/env bats

load helper

@test "there is at least one script to check" {
  run bash -c "ls $WG_ROOT/lib/*.sh | wc -l"
  [ "$output" -ge 1 ]
}

@test "shellcheck passes on every script" {
  run bash -c "cd '$WG_ROOT' && shopt -s nullglob && shellcheck -x lib/*.sh bin/* ./*.sh 2>&1"
  [ "$status" -eq 0 ]
}
