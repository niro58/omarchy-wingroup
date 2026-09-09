# shellcheck shell=bash
# Replacement for wg_window_cwd that reads the cwd.map fixture instead of
# /proc. Sourced by bin/wingroup and bin/wingroup-waybar when WG_TEST_STUB_CWD
# points here, and by test/helper.bash for tests that source the libs directly.

# The process-table scan belongs to the /proc lookup this file replaces, so it
# goes too: the fixture pids are not processes, and nothing here should read the
# machine's real process list.
wg_children_load() { WG_CHILDREN_LOADED=1; }
WG_CHILDREN_LOADED=1

wg_window_cwd() {
  local pid="$1" p c
  # Test-only: when $WG_CWD_LOG is set, record every lookup. One lookup is one
  # pgrep plus two /proc readlinks in the real implementation, so the count is
  # the cost of a table build.
  [[ -z ${WG_CWD_LOG:-} ]] || printf '%s\n' "$pid" >>"$WG_CWD_LOG"
  while IFS=$'\t' read -r p c; do
    [[ $p == "$pid" ]] && { printf '%s\n' "$c"; return 0; }
  done <"$WG_FIXTURES/cwd.map"
  return 0
}
