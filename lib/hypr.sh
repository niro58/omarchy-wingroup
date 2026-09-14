# shellcheck shell=bash
# Every interaction with the compositor goes through these functions, so that
# tests can replace hyprctl with a stub via $WG_HYPRCTL.

: "${WG_HYPRCTL:=hyprctl}"

wg_hypr_query() {
  "$WG_HYPRCTL" -j "$@"
}

wg_hypr_dispatch() {
  "$WG_HYPRCTL" dispatch "$@"
}

# The monitor a group's workspace is on at this moment, or nothing when the
# group has no workspace yet -- a group nobody has opened a window in exists in
# state.json and nowhere else, and Hyprland has never heard of it.
#
# Where the workspace *is*, which is not the same question as where it is
# pinned: a pin says what should happen next, and until something acts on it the
# group is wherever it has always been. Both the CLI and the picker need the
# answer, which is why it lives here.
wg_group_monitor() {
  wg_hypr_query workspaces \
    | jq -r --arg w "${1:?}" 'first(.[] | select(.name == $w) | .monitor) // empty'
}
