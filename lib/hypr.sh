# shellcheck shell=bash
# Every interaction with the compositor goes through these functions, so that
# tests can replace hyprctl with a stub via $WG_HYPRCTL.

: "${WG_HYPRCTL:=hyprctl}"

wg_hypr_query() {
  "$WG_HYPRCTL" -j "$@"
}

# Whether this compositor takes its dispatches as Lua. Empty until asked.
#
# Hyprland 0.56 replaced the dispatch string with a Lua API: "hyprctl dispatch
# movetoworkspacesilent name:plat,address:0x..." is now read as Lua source and
# fails to parse, and every move wingroup makes went that way at once when
# Omarchy 4 landed. The terminals came back from the snapshot and then piled up
# on whatever workspace they opened on, because nothing could place them.
#
# Probed rather than read off the version, because the version that matters is
# the one that answers this socket, not the one a package manager mentions.
# hl.dsp.no_op() is the harmless end of the new API: it exists to do nothing.
# Inherited when the caller has already decided -- the tests pin it, and a
# desktop that wants to force one dialect can export it too.
WG_HYPR_LUA="${WG_HYPR_LUA-}"

wg_hypr_lua() {
  [[ -z $WG_HYPR_LUA ]] || { [[ $WG_HYPR_LUA == 1 ]]; return; }
  if "$WG_HYPRCTL" dispatch 'hl.dsp.no_op()' 2>/dev/null | grep -q '^ok'; then
    WG_HYPR_LUA=1
  else
    WG_HYPR_LUA=0
  fi
  [[ $WG_HYPR_LUA == 1 ]]
}

# A dispatch, in whichever language the compositor speaks.
#
# The old spelling is the one written here and the one the tests read, because
# it says what it does in one line. On a compositor that has moved on, it is
# translated on the way out.
#
# Only the dispatches wingroup makes are translated. Anything else is passed
# through untouched: guessing at a translation for a dispatcher nobody here
# calls would be inventing an API by extrapolation.
wg_hypr_dispatch() {
  if wg_hypr_lua; then
    local lua
    if lua="$(wg_hypr_lua_form "$@")"; then
      "$WG_HYPRCTL" dispatch "$lua"
      return
    fi
  fi
  "$WG_HYPRCTL" dispatch "$@"
}

# The Lua form of one dispatch, or nothing (and non-zero) when there is none.
#
# The workspace keeps its old selector -- "name:plat" for a group, "5" for a
# numbered workspace -- because the new API parses the same grammar. That is
# not a guess: "plat" on its own is accepted and silently moves nothing, which
# is how seventeen windows were dispatched at and stayed where they were.
wg_hypr_lua_form() {
  local what="${1:-}" arg="${2:-}" ws rest addr mon w h
  case $what in
    workspace)
      printf 'hl.dsp.focus({ workspace = "%s" })\n' "$arg" ;;
    movetoworkspace | movetoworkspacesilent)
      ws="${arg%%,*}"
      addr="${arg#*address:}"
      local follow=true
      [[ $what == movetoworkspace ]] || follow=false
      printf 'hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = %s })\n' \
        "$ws" "$addr" "$follow" ;;
    moveworkspacetomonitor)
      ws="${arg%% *}"
      mon="${arg#* }"
      printf 'hl.dsp.workspace.move({ workspace = "%s", monitor = "%s" })\n' "$ws" "$mon" ;;
    focuswindow)
      printf 'hl.dsp.focus({ window = "%s" })\n' "$arg" ;;
    swapwindow)
      # Swaps the focused window with this one, as the old dispatcher did.
      printf 'hl.dsp.window.swap({ target = "%s" })\n' "$arg" ;;
    resizewindowpixel)
      # "exact <w> <h>,address:0x..."
      rest="${arg#exact }"
      w="${rest%% *}"
      rest="${rest#* }"
      h="${rest%%,*}"
      addr="${arg#*address:}"
      printf 'hl.dsp.window.resize({ x = "%s", y = "%s", window = "address:%s", exact = true })\n' \
        "$w" "$h" "$addr" ;;
    *)
      return 1 ;;
  esac
  return 0
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

# How to name workspace $1 to the compositor.
#
# "name:5" is not workspace 5. Hyprland keeps named workspaces apart from
# numbered ones, so dispatching at "name:5" creates a *second* workspace that is
# also called 5, with its own id, on whatever monitor has focus. The window goes
# there and the user's own SUPER+5 goes to the numbered one, which is empty: the
# bar counts a window nobody can find, and the screen shows nothing.
#
# Found on a live desktop with two workspaces called 5 -- one holding a session,
# one being looked at.
#
# A workspace whose name is all digits is therefore addressed as the number it
# is. A scratchpad names itself, and is passed through untouched. Everything
# else -- every group -- is a named workspace and says so.
wg_ws_selector() {
  local ws="${1:-}"
  [[ -n $ws ]] || return 0
  case $ws in
    special:*)       printf '%s\n' "$ws" ;;
    *[!0-9]* | "")   printf 'name:%s\n' "$ws" ;;
    *)               printf '%s\n' "$ws" ;;
  esac
}

# The command that reaches Omarchy 4's shell. A variable so the tests can stand
# something harmless in for it rather than poke the shell on the machine running
# them.
: "${WG_SHELL_CMD:=omarchy-shell}"

# Asks Omarchy 4's shell to redraw wingroup's groups, the way wg_signal_waybar
# asks waybar. Quiet and best-effort: -q returns success whether or not the
# shell, or the widget, is there -- a machine on waybar has neither, and that is
# not an error.
#
# The widget already redraws on the Hyprland events that change it. This is for
# the changes Hyprland never hears about: a group created from a terminal, a pin
# moved, a crash recorded.
wg_signal_shell() {
  command -v "$WG_SHELL_CMD" >/dev/null 2>&1 || return 0
  "$WG_SHELL_CMD" -q wingroup.groups refresh >/dev/null 2>&1 || true
}
