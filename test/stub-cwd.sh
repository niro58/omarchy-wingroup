# shellcheck shell=bash
# Replacement for wg_window_cwd that reads the cwd.map fixture instead of
# /proc. Sourced by bin/wingroup-waybar when WG_TEST_STUB_CWD points here.

wg_window_cwd() {
  local pid="$1" p c
  while IFS=$'\t' read -r p c; do
    [[ $p == "$pid" ]] && { printf '%s\n' "$c"; return 0; }
  done <"$WG_FIXTURES/cwd.map"
  return 0
}
