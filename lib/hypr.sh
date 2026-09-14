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

# The process name the bar runs under. A variable only so the tests can stand a
# process of their own in for it.
: "${WG_WAYBAR_PROC:=waybar}"

# Asks every running bar to redraw its wingroup modules -- and only a bar that
# is ready to be asked.
#
# The request is real-time signal RTMIN+11, and an unhandled real-time signal
# does not get ignored: its default action is to terminate the process. waybar
# installs a handler for it only once it has built the modules that listen on
# it, so for its first moment after starting, the refresh is fatal. And that
# moment is login, which is exactly when the daemon files a dozen terminals,
# restore respawns sessions and oomwatch starts -- every one of them asking for
# a redraw. The bar died in that burst with no crash, no core, no log line and no
# kill record, and the desktop came up with no top bar at all.
#
# So the mask is read first. /proc/<pid>/status SigCgt lists, as a hex bitmask,
# the signals the process has a handler for -- bit n-1 for signal n. A bar
# without the bit is still starting, and needs no redraw: when it finishes, its
# modules run for the first time and read the state as it is then.
wg_signal_waybar() {
  local offset="${1:-11}" signum pid mask
  signum=$(( $(kill -l RTMIN) + offset ))
  for pid in $(pgrep -x "$WG_WAYBAR_PROC" 2>/dev/null); do
    mask="$(awk '/^SigCgt:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)"
    [[ -n $mask ]] || continue
    (( (16#$mask >> (signum - 1)) & 1 )) || continue
    kill -s "RTMIN+$offset" "$pid" 2>/dev/null || true
  done
  return 0
}
