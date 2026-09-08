# shellcheck shell=bash
# Replacement for wg_window_cwd that reads the cwd.map fixture instead of
# /proc. Sourced by bin/wingroup-waybar when WG_TEST_STUB_CWD points here.

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
