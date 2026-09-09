# shellcheck shell=bash
WG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WG_ROOT
export WG_FIXTURES="$WG_ROOT/test/fixtures"
export WG_HYPRCTL="$WG_ROOT/test/bin/hyprctl-stub"
export WG_PROJECTS_DIR="/home/niro/projects"
export WG_LIB_DIR="$WG_ROOT/lib"
# Never the real one. If this machine has Omarchy installed, the picker would
# otherwise hand the entries to omarchy-launch-walker, which starts services and
# puts a real walker on the user's screen. A test that wants that path points
# this at a stub itself.
export WG_WALKER_LAUNCHER="$WG_ROOT/test/bin/no-such-launcher"

wg_setup_tmp() {
  WG_TMP="$(mktemp -d)"
  export WG_TMP
  # The picker's single-instance lock lives here; keep it out of the real one.
  export XDG_RUNTIME_DIR="$WG_TMP"
  export WG_STATE_DIR="$WG_TMP/state"
  export WG_DISPATCH_LOG="$WG_TMP/dispatch.log"
  : >"$WG_DISPATCH_LOG"
  export WG_TEST_STUB_CWD="$WG_ROOT/test/stub-cwd.sh"
  export WG_REFRESH_CMD="$WG_ROOT/test/bin/refresh-stub"
  export WG_REFRESH_LOG="$WG_TMP/refresh.log"
  : >"$WG_REFRESH_LOG"
}

wg_teardown_tmp() {
  [[ -n ${WG_TMP:-} && -d $WG_TMP ]] && rm -rf "$WG_TMP"
  return 0
}

# Seed the state file from a fixture.
wg_seed_state() {
  mkdir -p "$WG_STATE_DIR"
  cp "$WG_FIXTURES/${1:-state.json}" "$WG_STATE_DIR/state.json"
}

# Replacement for wg_window_cwd that reads cwd.map instead of /proc. One copy
# only: the executables source the same file when $WG_TEST_STUB_CWD points at it.
wg_stub_cwd() {
  # shellcheck source=test/stub-cwd.sh
  source "$WG_ROOT/test/stub-cwd.sh"
}

dispatches() {
  cat "$WG_DISPATCH_LOG"
}

# Puts a counting `jq` ahead of the real one on PATH, so a test can assert how
# many jq processes a code path spawns. jq is the most expensive thing these
# scripts fork, so the count is a fair proxy for what the work costs.
wg_count_jq() {
  local dir="$WG_TMP/shim" real
  real="$(command -v jq)"
  mkdir -p "$dir"
  export WG_JQ_LOG="$WG_TMP/jq.log"
  : >"$WG_JQ_LOG"
  cat >"$dir/jq" <<EOF
#!/usr/bin/env bash
printf 'jq\n' >>"$WG_JQ_LOG"
exec "$real" "\$@"
EOF
  chmod +x "$dir/jq"
  export PATH="$dir:$PATH"
}

jq_calls() {
  wc -l <"$WG_JQ_LOG"
}

# Applies a jq expression to the seeded state file in place.
wg_patch_state() {
  jq "$1" "$WG_STATE_DIR/state.json" >"$WG_TMP/state.patched"
  mv -f "$WG_TMP/state.patched" "$WG_STATE_DIR/state.json"
}
