#!/usr/bin/env bash
set -euo pipefail

WG_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

: "${WG_BIN_DIR:=$HOME/.local/bin}"
: "${WG_WAYBAR_CONFIG:=$HOME/.config/waybar/config.jsonc}"
: "${WG_WAYBAR_STYLE:=$HOME/.config/waybar/style.css}"
: "${WG_HYPR_BINDINGS:=$HOME/.config/hypr/bindings.conf}"
: "${WG_HYPR_AUTOSTART:=$HOME/.config/hypr/autostart.conf}"
: "${WG_STATE_DIR:=$HOME/.local/state/omarchy/wingroup}"

WG_SLOTS=8
WG_SIGNAL=11

backup() {
  [[ -f $1 ]] || return 0
  cp -p "$1" "$1.bak.$(date +%s)"
}

# True (exit 0) if the file's last byte is a newline. A missing or empty file
# counts as "has a newline" -- there is nothing to preserve either way.
wg_ends_with_newline() {
  local f="$1"
  [[ -s "$f" ]] || return 0
  [[ "$(tail -c1 -- "$f" | wc -l)" -eq 1 ]]
}

link_binaries() {
  mkdir -p "$WG_BIN_DIR"
  local f
  for f in "$WG_ROOT"/bin/*; do
    ln -sfn "$f" "$WG_BIN_DIR/$(basename "$f")"
  done
}

# $1: suffix to append to the closing marker line (e.g. " no-eof-nl"). Every
# append/rewrite this script does ends the file in a newline, even when the
# original did not -- so uninstall.sh reads this suffix off the closing marker
# to know whether it must strip that trailing newline back off to reverse
# byte-exactly.
waybar_modules_block() {
  local eof_flag="$1" i
  printf '  // >>> wingroup\n'
  for (( i = 0; i < WG_SLOTS; i++ )); do
    printf '  "custom/wingroup%d": {\n' "$i"
    printf '    "exec": "wingroup-waybar %d",\n' "$i"
    printf '    "return-type": "json",\n'
    printf '    "interval": "once",\n'
    printf '    "signal": %d,\n' "$WG_SIGNAL"
    printf '    "on-click": "wingroup activate %d",\n' "$i"
    printf '    "on-click-right": "wingroup menu",\n'
    printf '    "tooltip": true\n'
    printf '  },\n'
  done
  printf '  // <<< wingroup%s\n' "$eof_flag"
}

install_waybar_config() {
  grep -q 'custom/wingroup0' "$WG_WAYBAR_CONFIG" && return 0

  local eof_flag=""
  wg_ends_with_newline "$WG_WAYBAR_CONFIG" || eof_flag=" no-eof-nl"

  local slots i tmp
  slots=""
  for (( i = 0; i < WG_SLOTS; i++ )); do
    slots+=", \"custom/wingroup$i\""
  done

  tmp="$(mktemp)"
  awk -v slots="$slots" -v block="$(waybar_modules_block "$eof_flag")" '
    NR == 1 && $0 ~ /^\{/ { print; print block; next }
    /"modules-left"[[:space:]]*:/ { sub(/\][[:space:]]*,[[:space:]]*$/, slots "],"); print; next }
    { print }
  ' "$WG_WAYBAR_CONFIG" >"$tmp"

  # sub() above only fires when the modules-left line ends in a trailing
  # comma. If it didn't fire, we'd silently ship a config with the module
  # definitions present but no slots wired into modules-left. Fail loudly
  # instead, and touch nothing.
  if ! grep -qE '"modules-left"[[:space:]]*:.*"custom/wingroup0"' "$tmp"; then
    rm -f "$tmp"
    printf 'install.sh: expected "modules-left" in %s to end in a trailing comma (e.g. "modules-left": [...],) so the wingroup slots could be appended to it. No changes were made.\n' "$WG_WAYBAR_CONFIG" >&2
    exit 1
  fi

  backup "$WG_WAYBAR_CONFIG"
  if [[ -n $eof_flag ]]; then
    truncate -s -1 "$tmp"
  fi
  mv -f "$tmp" "$WG_WAYBAR_CONFIG"
}

install_waybar_style() {
  grep -q '>>> wingroup' "$WG_WAYBAR_STYLE" && return 0

  local eof_flag=""
  wg_ends_with_newline "$WG_WAYBAR_STYLE" || eof_flag=" no-eof-nl"

  backup "$WG_WAYBAR_STYLE"

  local i base="" busy="" active=""
  for (( i = 0; i < WG_SLOTS; i++ )); do
    base+="${base:+, }#custom-wingroup$i"
    busy+="${busy:+, }#custom-wingroup$i.busy"
    active+="${active:+, }#custom-wingroup$i.active"
  done

  {
    printf '\n/* >>> wingroup */\n'
    printf '%s { padding: 0 6px; opacity: 0.55; }\n' "$base"
    printf '%s { opacity: 1; }\n' "$busy"
    printf '%s { opacity: 1; font-weight: bold; }\n' "$active"
    printf '/* <<< wingroup%s */\n' "$eof_flag"
  } >>"$WG_WAYBAR_STYLE"
}

install_bindings() {
  grep -q '>>> wingroup' "$WG_HYPR_BINDINGS" && return 0

  local eof_flag=""
  wg_ends_with_newline "$WG_HYPR_BINDINGS" || eof_flag=" no-eof-nl"

  backup "$WG_HYPR_BINDINGS"
  cat >>"$WG_HYPR_BINDINGS" <<EOF

# >>> wingroup
unbind = SUPER, G
bindd = SUPER, G, Window groups, exec, wingroup menu
bindd = SUPER CTRL, G, Send window to group, exec, wingroup send
# <<< wingroup$eof_flag
EOF
}

install_autostart() {
  grep -q '>>> wingroup' "$WG_HYPR_AUTOSTART" && return 0

  local eof_flag=""
  wg_ends_with_newline "$WG_HYPR_AUTOSTART" || eof_flag=" no-eof-nl"

  backup "$WG_HYPR_AUTOSTART"
  cat >>"$WG_HYPR_AUTOSTART" <<EOF

# >>> wingroup
exec-once = wingroup-daemon
# <<< wingroup$eof_flag
EOF
}

seed_state() {
  mkdir -p "$WG_STATE_DIR"
  [[ -f "$WG_STATE_DIR/state.json" ]] && return 0
  printf '%s\n' '{"auto":true,"catchall":null,"groups":[],"overrides":{}}' >"$WG_STATE_DIR/state.json"
}

link_binaries
install_waybar_config
install_waybar_style
install_bindings
install_autostart
seed_state

printf 'wingroup installed. Reload with: hyprctl reload && pkill -SIGUSR2 waybar\n'
printf 'Then create your first group, e.g.: wingroup new everest everest-web everest-rs\n'
printf 'and file the windows you already have open: wingroup tidy\n'
