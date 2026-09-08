# shellcheck shell=bash
WG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WG_ROOT
export WG_FIXTURES="$WG_ROOT/test/fixtures"
export WG_HYPRCTL="$WG_ROOT/test/bin/hyprctl-stub"
export WG_PROJECTS_DIR="/home/niro/projects"
export WG_LIB_DIR="$WG_ROOT/lib"

wg_setup_tmp() {
  WG_TMP="$(mktemp -d)"
  export WG_TMP
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
