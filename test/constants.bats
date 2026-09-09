#!/usr/bin/env bats
#
# WG_SLOTS and WG_IDLE_HEAT_MAX describe one thing each, and two programs have
# to agree about it: bin/wingroup-waybar answers for a slot and emits a class,
# install.sh defines the module and writes the rule. They used to be written out
# twice, kept in step by a comment. These tests fail if the two halves ever say
# different numbers again -- whichever half is changed.

load helper

setup() {
  wg_setup_tmp
  export WG_BIN_DIR="$WG_TMP/bin"
  export WG_WAYBAR_CONFIG="$WG_TMP/config.jsonc"
  export WG_WAYBAR_STYLE="$WG_TMP/style.css"
  export WG_HYPR_BINDINGS="$WG_TMP/bindings.conf"
  export WG_HYPR_AUTOSTART="$WG_TMP/autostart.conf"
  # Never the real one: whether it exists decides what install writes.
  export WG_RESTORE_SCRIPT="$WG_TMP/restore-claude.sh"
  cp "$WG_FIXTURES/waybar-config.jsonc" "$WG_WAYBAR_CONFIG"
  cp "$WG_FIXTURES/waybar-style.css" "$WG_WAYBAR_STYLE"
  printf '# my bindings\n' >"$WG_HYPR_BINDINGS"
  printf '# my autostart\n' >"$WG_HYPR_AUTOSTART"
  source "$WG_ROOT/lib/constants.sh"
}

teardown() { wg_teardown_tmp; }

# $1 groups named s0..s$1-1, and nothing else.
wg_seed_group_count() {
  mkdir -p "$WG_STATE_DIR"
  jq -n --argjson n "$1" '{auto: true, follow: true, catchall: null,
    groups: [range(0; $n) | {name: "s\(.)", label: "s\(.)", projects: [], monitor: null}],
    overrides: {}}' >"$WG_STATE_DIR/state.json"
}

# The highest N in a "custom/wingroupN": { ... } definition install.sh wrote.
wg_last_installed_slot() {
  sed -n 's/.*"custom\/wingroup\([0-9]\+\)"[[:space:]]*:[[:space:]]*{.*/\1/p' \
    "$WG_WAYBAR_CONFIG" | sort -n | tail -n1
}

# The static half: one definition each, in the file both sides source.
@test "each shared constant is defined in exactly one place" {
  local name
  for name in WG_SLOTS WG_IDLE_HEAT_MAX; do
    run bash -c "cd '$WG_ROOT' && shopt -s nullglob \
      && grep -cE \"^[[:space:]]*$name=\" lib/*.sh bin/* ./*.sh | grep -v ':0\$'"
    [ "$output" = "lib/constants.sh:1" ]
  done
}

@test "both halves source the file that defines them" {
  run bash -c "grep -c 'lib/constants.sh' '$WG_ROOT/install.sh'"
  [ "$output" -ge 1 ]
  run bash -c "grep -c 'constants.sh' '$WG_ROOT/bin/wingroup-waybar'"
  [ "$output" -ge 1 ]
}

# install.sh is run from the checkout in the README, but nothing says it has to
# be: it resolves its own path, and sourcing must not depend on the caller's
# working directory.
@test "install works when it is run from somewhere else entirely" {
  run bash -c "cd / && '$WG_ROOT/install.sh'"
  [ "$status" -eq 0 ]
  run bash -c "grep -c '\"custom/wingroup0\"[[:space:]]*:[[:space:]]*{' '$WG_WAYBAR_CONFIG'"
  [ "$output" -eq 1 ]
}

# The slot half. With one more group than there are slots, the *last installed*
# slot is the one that has to carry the overflow line -- that is the module and
# the installer naming the same last slot. If either side's WG_SLOTS moved, the
# overflow would land on a slot the bar does not draw, or not land at all.
@test "the last slot the installer defines is the last slot the module answers for" {
  wg_seed_group_count $(( WG_SLOTS + 1 ))
  "$WG_ROOT/install.sh"

  run bash -c "grep -cE '\"custom/wingroup[0-9]+\"[[:space:]]*:[[:space:]]*\{' '$WG_WAYBAR_CONFIG'"
  [ "$output" -eq "$WG_SLOTS" ]

  local last
  last="$(wg_last_installed_slot)"
  [ "$last" -eq $(( WG_SLOTS - 1 )) ]

  run "$WG_ROOT/bin/wingroup-waybar" "$last"
  [ "$(jq -r '.text' <<<"$output")" = "s$last" ]
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"1 more: s$WG_SLOTS"* ]]
}

# The ramp half. Every class the module can emit needs a rule, and the
# stylesheet must not carry a rule for a class the module never emits.
@test "every idle class the module emits has a rule, and no rule outruns the module" {
  wg_seed_group_count 1
  "$WG_ROOT/install.sh"

  local n emitted
  for (( n = 1; n <= WG_IDLE_HEAT_MAX; n++ )); do
    wg_group_windows s0 "$n"
    emitted="$("$WG_ROOT/bin/wingroup-waybar" 0 | jq -r 'if (.class|type) == "array" then (.class|join(" ")) else .class end')"
    [ "$emitted" = "idle$n" ]
    run bash -c "grep -c '#custom-wingroup0.idle$n' '$WG_WAYBAR_STYLE'"
    [ "$output" -eq 1 ]
  done

  # One past the ceiling: the module caps there, so a rule for it would style
  # nothing on any bar.
  wg_group_windows s0 $(( WG_IDLE_HEAT_MAX + 1 ))
  emitted="$("$WG_ROOT/bin/wingroup-waybar" 0 | jq -r 'if (.class|type) == "array" then (.class|join(" ")) else .class end')"
  [ "$emitted" = "idle$WG_IDLE_HEAT_MAX" ]
  run bash -c "grep -c 'idle$(( WG_IDLE_HEAT_MAX + 1 ))' '$WG_WAYBAR_STYLE' || true"
  [ "$output" -eq 0 ]
}

# A client list of $2 idle Claude windows, all sent to group $1 by an override.
wg_group_windows() {
  local group="$1" idle="$2"
  jq -n --argjson i "$idle" '
    [ range(0; $i) | {address: "0xbb\(.)", title: "✳ waiting for the next thing",
                      pid: 9000, class: "Alacritty", floating: false,
                      workspace: {id: 1, name: "1"}} ]' >"$WG_TMP/clients-heat.json"
  export WG_FIXTURE_CLIENTS="$WG_TMP/clients-heat.json"
  jq --arg g "$group" --argjson i "$idle" '
    .overrides = (reduce range(0; $i) as $n ({}; .["0xbb\($n)"] = $g))' \
    "$WG_STATE_DIR/state.json" >"$WG_TMP/state.heat"
  mv -f "$WG_TMP/state.heat" "$WG_STATE_DIR/state.json"
}
