# shellcheck shell=bash
# Every interaction with the compositor goes through these two functions,
# so that tests can replace hyprctl with a stub via $WG_HYPRCTL.

: "${WG_HYPRCTL:=hyprctl}"

wg_hypr_query() {
  "$WG_HYPRCTL" -j "$@"
}

wg_hypr_dispatch() {
  "$WG_HYPRCTL" dispatch "$@"
}
