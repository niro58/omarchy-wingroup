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

unlink_binaries() {
  local f
  for f in "$WG_ROOT"/bin/*; do
    rm -f "$WG_BIN_DIR/$(basename "$f")"
  done
}

# Deletes the marked block and, if the block was preceded by a blank line that
# install.sh added, that blank line too — so uninstall is a byte-exact reversal.
#
# The awk holds a blank line back for one iteration instead of printing it. If the
# next line opens the block, the held blank is dropped along with it; otherwise it
# is printed as normal. Markers are matched with index(), not as regexes, because
# they contain characters (/ and *) that a regex would interpret.
strip_block() {
  local file="$1" open_marker="$2" close_marker="$3" tmp
  [[ -f $file ]] || return 0
  grep -qF -- "$open_marker" "$file" || return 0
  tmp="$(mktemp)"
  awk -v open="$open_marker" -v close_mark="$close_marker" '
    index($0, open) { skip = 1; pending = 0; next }
    skip            { if (index($0, close_mark)) skip = 0; next }
    /^$/            { if (pending) print ""; pending = 1; next }
                    { if (pending) { print ""; pending = 0 } print }
    END             { if (pending) print "" }
  ' "$file" >"$tmp"
  mv -f "$tmp" "$file"
}

strip_waybar_slots() {
  local i tmp
  [[ -f $WG_WAYBAR_CONFIG ]] || return 0
  tmp="$(mktemp)"
  cp "$WG_WAYBAR_CONFIG" "$tmp"
  for (( i = 0; i < WG_SLOTS; i++ )); do
    sed -i "s|, \"custom/wingroup$i\"||g" "$tmp"
  done
  mv -f "$tmp" "$WG_WAYBAR_CONFIG"
}

unlink_binaries
strip_block "$WG_WAYBAR_CONFIG" '// >>> wingroup' '// <<< wingroup'
strip_waybar_slots
strip_block "$WG_WAYBAR_STYLE" '/* >>> wingroup */' '/* <<< wingroup */'
strip_block "$WG_HYPR_BINDINGS" '# >>> wingroup' '# <<< wingroup'
strip_block "$WG_HYPR_AUTOSTART" '# >>> wingroup' '# <<< wingroup'

printf 'wingroup uninstalled. Your groups are kept in %s\n' "$WG_STATE_DIR"
