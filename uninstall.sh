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

# Puts the "modules-left" line back exactly as install.sh found it.
#
# install.sh edits that line twice -- it appends the slots and it removes
# "hyprland/workspaces" -- and it records the line verbatim inside its own
# marked block first. Restoring the recording is a byte-exact reversal of both
# edits at once, and of any spacing this script would otherwise have to guess
# at. It has to run before strip_block, which deletes the recording along with
# the rest of the block.
#
# The recorded line is itself a "modules-left" line, and it sits above the real
# one, so it is skipped explicitly rather than matched first. ENVIRON, not -v:
# an -v assignment runs escape processing over the value.
restore_modules_left() {
  local recorded tmp
  [[ -f $WG_WAYBAR_CONFIG ]] || return 0
  recorded="$(sed -n 's|^  // wingroup-modules-left:||p' "$WG_WAYBAR_CONFIG" | head -n1)"
  [[ -n $recorded ]] || return 0

  tmp="$(mktemp)"
  wg_line="$recorded" awk '
    index($0, "// wingroup-modules-left:") { print; next }
    !restored && /"modules-left"[[:space:]]*:/ { print ENVIRON["wg_line"]; restored = 1; next }
    { print }
  ' "$WG_WAYBAR_CONFIG" >"$tmp"
  mv -f "$tmp" "$WG_WAYBAR_CONFIG"
}

# A fallback, and only that: restore_modules_left already put the whole line
# back, slots and all, whenever install.sh's recording survived. This catches
# the config whose marked block was edited away by hand, leaving the slots
# behind with nothing to restore them.
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
restore_modules_left
strip_block "$WG_WAYBAR_CONFIG" '// >>> wingroup' '// <<< wingroup'
strip_waybar_slots
strip_block "$WG_WAYBAR_STYLE" '/* >>> wingroup' '/* <<< wingroup'
strip_block "$WG_HYPR_BINDINGS" '# >>> wingroup' '# <<< wingroup'
strip_block "$WG_HYPR_AUTOSTART" '# >>> wingroup' '# <<< wingroup'

printf 'wingroup uninstalled. Your groups are kept in %s\n' "$WG_STATE_DIR"
