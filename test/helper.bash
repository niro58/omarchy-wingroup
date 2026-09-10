# shellcheck shell=bash
WG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WG_ROOT
export WG_FIXTURES="$WG_ROOT/test/fixtures"
export WG_HYPRCTL="$WG_ROOT/test/bin/hyprctl-stub"
export WG_PROJECTS_DIR="/home/dev/projects"
export WG_LIB_DIR="$WG_ROOT/lib"
# Never the real one. If this machine has Omarchy installed, the picker would
# otherwise hand the entries to omarchy-launch-walker, which starts services and
# puts a real walker on the user's screen. A test that wants that path points
# this at a stub itself.
export WG_WALKER_LAUNCHER="$WG_ROOT/test/bin/no-such-launcher"

wg_setup_tmp() {
  # The bar tells a custom module which monitor it is drawn on through this.
  # Inherited from a real desktop session it would make the class tests depend
  # on which screen the terminal running them happens to be on.
  unset WAYBAR_OUTPUT_NAME
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
  # Never the real notify-send: a failing test must not push a notification
  # onto the user's actual desktop.
  export WG_NOTIFY_CMD="$WG_ROOT/test/bin/notify-stub"
  export WG_NOTIFY_LOG="$WG_TMP/notify.log"
  : >"$WG_NOTIFY_LOG"
  # sessions.json and crashed.json. Never the real runtime directory: a test
  # that wrote there would tell the user's own bar that sessions had crashed.
  export WG_RUNTIME_DIR="$WG_TMP/runtime"
  # Nothing in the tests may read the machine's real process table, for the
  # same reason test/stub-cwd.sh exists: the fixture pids are not processes.
  export WG_PROC_DIR="$WG_TMP/proc"
  mkdir -p "$WG_PROC_DIR"
  # Never the real uwsm-app: a test must not put terminals on the user's screen.
  export WG_LAUNCH_CMD="$WG_ROOT/test/bin/launch-stub"
  export WG_LAUNCH_LOG="$WG_TMP/launch.log"
  : >"$WG_LAUNCH_LOG"
}

# Adds one process to the fake $WG_PROC_DIR: pid, comm, scope, cwd.
#
# A directory of files rather than a stubbed function, because wg_sessions_scan
# reads /proc itself -- globbing the pid list and reading three files per hit --
# and stubbing that away would leave the part that actually ships untested.
wg_fake_proc() {
  local pid="$1" comm="$2" scope="$3" cwd="$4" dir="$WG_PROC_DIR/$pid"
  mkdir -p "$dir" "$cwd"
  printf '%s\n' "$comm" >"$dir/comm"
  printf '0::/user.slice/user-1000.slice/app.slice/app-graphical.slice/%s\n' "$scope" >"$dir/cgroup"
  ln -sfn "$cwd" "$dir/cwd"
}

# The scope name a terminal launched through uwsm/xdg-terminal-exec ends up in.
# Written once here so a test names a scope the way the desktop does, escapes
# and all -- those backslashes are literal, and they are why the scope is never
# round-tripped through @tsv.
wg_fake_scope() {
  printf 'app-Hyprland-xdg\\x2dterminal\\x2dexec-%s.scope\n' "$1"
}

launches() {
  cat "$WG_LAUNCH_LOG"
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

notifications() {
  cat "$WG_NOTIFY_LOG"
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
