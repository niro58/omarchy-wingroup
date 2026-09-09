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
# install.sh added, that blank line too -- so uninstall is a byte-exact reversal.
#
# The awk holds a blank line back for one iteration instead of printing it. If the
# next line opens the block, the held blank is dropped along with it; otherwise it
# is printed as normal. Markers are matched with index(), not as regexes, because
# they contain characters (/ and *) that a regex would interpret.
#
# install.sh always leaves the file ending in a newline -- every printf/cat append
# ends in \n, and so does every line awk prints when rewriting the waybar config --
# even when the original file did not end in one. It records that fact as a
# " no-eof-nl" suffix on the closing marker line (still inside a valid comment for
# every file type), so once the marked block is gone we know whether to strip the
# one trailing newline install.sh introduced, restoring the file exactly.
strip_block() {
  local file="$1" open_marker="$2" close_marker="$3" tmp no_eof=0
  [[ -f $file ]] || return 0
  grep -qF -- "$open_marker" "$file" || return 0

  if grep -F -- "$close_marker" "$file" | grep -qF -- 'no-eof-nl'; then
    no_eof=1
  fi

  tmp="$(mktemp)"
  awk -v open="$open_marker" -v close_mark="$close_marker" '
    index($0, open) { skip = 1; pending = 0; next }
    skip            { if (index($0, close_mark)) skip = 0; next }
    /^$/            { if (pending) print ""; pending = 1; next }
                    { if (pending) { print ""; pending = 0 } print }
    END             { if (pending) print "" }
  ' "$file" >"$tmp"

  if (( no_eof )); then
    truncate -s -1 "$tmp"
  fi

  mv -f "$tmp" "$file"
}

# The slots install.sh appended to "modules-left". strip_block cannot reach
# them: they sit on a line of the user's own that has to survive.
#
# Everything else install.sh put in the waybar config -- the module definitions
# and the "ignore-workspaces" entry inside the "hyprland/workspaces" object --
# is inside a marked block, so strip_block takes both.
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
strip_block "$WG_WAYBAR_STYLE" '/* >>> wingroup' '/* <<< wingroup'
strip_block "$WG_HYPR_BINDINGS" '# >>> wingroup' '# <<< wingroup'
strip_block "$WG_HYPR_AUTOSTART" '# >>> wingroup' '# <<< wingroup'

printf 'wingroup uninstalled. Your groups are kept in %s\n' "$WG_STATE_DIR"
