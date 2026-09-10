#!/usr/bin/env bash
set -euo pipefail

WG_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# WG_SLOTS, from the one file that defines it: the slots stripped out of
# "modules-left" here are exactly the ones install.sh appended to it.
# shellcheck source=lib/constants.sh
source "$WG_ROOT/lib/constants.sh"

: "${WG_BIN_DIR:=$HOME/.local/bin}"
: "${WG_WAYBAR_CONFIG:=$HOME/.config/waybar/config.jsonc}"
: "${WG_WAYBAR_STYLE:=$HOME/.config/waybar/style.css}"
: "${WG_HYPR_BINDINGS:=$HOME/.config/hypr/bindings.conf}"
: "${WG_HYPR_AUTOSTART:=$HOME/.config/hypr/autostart.conf}"
: "${WG_STATE_DIR:=$HOME/.local/state/omarchy/wingroup}"
: "${WG_CLAUDE_SETTINGS:=$HOME/.claude/settings.json}"

# The exact command string install.sh registered. Matching on it is what makes
# this take out our entry and nobody else's.
WG_CLAUDE_HOOK_CMD="wingroup-hook"

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
  # The crashed button is a module of its own rather than a slot -- it answers
  # for no group -- but install appends it to the same line, after the slots, so
  # it comes off the same way. Named rather than folded into the loop above,
  # because there is no Nth of it.
  sed -i 's|, "custom/wingroup-crashed"||g' "$tmp"
  mv -f "$tmp" "$WG_WAYBAR_CONFIG"
}

# Takes the SessionStart hook back out of the Claude Code settings file.
#
# This is the one thing uninstall cannot reverse byte for byte, and it is worth
# being plain about why: the file is JSON, install rewrote it through jq, and jq
# reformats. So the *content* is restored exactly -- our entry gone, everything
# else untouched -- and the whitespace is jq's. That is also why this returns
# early when the entry is not there: a machine that never had the hook, or one
# installed with --no-claude-hook, must not have its settings file reformatted
# by an uninstall that had nothing to remove.
#
# Every failure is silent and harmless. Missing file, unparseable file, jq
# error: leave it alone. There is nothing to gain by failing an uninstall over
# a file we are only trying to tidy.
strip_claude_hook() {
  local updated tmp
  [[ -f $WG_CLAUDE_SETTINGS ]] || return 0
  jq -e --arg c "$WG_CLAUDE_HOOK_CMD" \
    'any(.hooks.SessionStart // [] | .[].hooks // [] | .[]; .command == $c)' \
    "$WG_CLAUDE_SETTINGS" >/dev/null 2>&1 || return 0

  # Drop our command from every entry, then drop entries left with no commands,
  # then drop the containers if they are now empty. The container cleanup can
  # remove an empty "hooks": {} the user happened to have already -- an empty
  # object and an absent key mean the same thing to Claude Code, so that is a
  # cosmetic difference and not a lost setting.
  #
  # An entry with no "hooks" key at all is a different matter and is left where
  # it is. It runs nothing, so it is dead config either way, but it is dead
  # config the *user* wrote, and "drop the entries left with no commands" is
  # about entries this uninstall emptied -- not about entries that arrived that
  # way. Hence both halves being guarded on has("hooks") rather than on length:
  # length cannot tell "we emptied it" from "it was never there".
  #
  # Every iteration is guarded with // [], and that is not belt and braces: a
  # SessionStart entry is allowed to carry a matcher and no "hooks" key at all,
  # and `.hooks[]` over that null aborts the whole filter. Which fails the way
  # that hurts most -- the error is swallowed, the uninstall reports success,
  # and our command stays registered pointing at the symlink that has just been
  # removed, so every session start afterwards runs a command that is not there.
  # shellcheck disable=SC2016  # $c is a jq variable, not a shell one
  updated="$(jq --arg c "$WG_CLAUDE_HOOK_CMD" '
      .hooks.SessionStart = [
        (.hooks.SessionStart // [])[]
        | if has("hooks") then .hooks = [(.hooks // [])[] | select(.command != $c)] else . end
        | select((has("hooks") | not) or (.hooks | length) > 0)
      ]
    | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
    | if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$WG_CLAUDE_SETTINGS" 2>/dev/null)" || { strip_claude_hook_failed; return 0; }
  jq -e . >/dev/null 2>&1 <<<"$updated" || { strip_claude_hook_failed; return 0; }

  tmp="$(mktemp "$(dirname -- "$WG_CLAUDE_SETTINGS")/.wingroup.XXXXXX")" \
    || { strip_claude_hook_failed; return 0; }
  # mktemp makes the temp file 0600 and mv carries that mode across, which would
  # silently tighten a settings file wingroup did not create. Copy the mode we
  # are replacing instead of imposing one.
  chmod --reference="$WG_CLAUDE_SETTINGS" "$tmp" 2>/dev/null || true
  if printf '%s\n' "$updated" >"$tmp" && mv -f "$tmp" "$WG_CLAUDE_SETTINGS"; then
    return 0
  fi
  rm -f "$tmp"
  strip_claude_hook_failed
}

# The one failure in this script that must not be silent.
#
# Everything else an uninstall gives up on leaves the machine tidier than it
# found it. This one does the opposite: unlink_binaries has already taken
# wingroup-hook off $PATH, so a registration left behind is a command Claude
# Code runs -- and fails -- at the start of every session from here on. If we
# cannot take it out, the user has to know to do it by hand.
strip_claude_hook_failed() {
  printf 'wingroup: could not remove the SessionStart hook from %s\n' \
    "$WG_CLAUDE_SETTINGS" >&2
  printf '          remove the "%s" entry by hand, or it will run at every session start\n' \
    "$WG_CLAUDE_HOOK_CMD" >&2
}

unlink_binaries
strip_block "$WG_WAYBAR_CONFIG" '// >>> wingroup' '// <<< wingroup'
strip_waybar_slots
strip_block "$WG_WAYBAR_STYLE" '/* >>> wingroup' '/* <<< wingroup'
strip_block "$WG_HYPR_BINDINGS" '# >>> wingroup' '# <<< wingroup'
strip_block "$WG_HYPR_AUTOSTART" '# >>> wingroup' '# <<< wingroup'
strip_claude_hook

printf 'wingroup uninstalled. Your groups are kept in %s\n' "$WG_STATE_DIR"
