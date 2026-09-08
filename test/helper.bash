# shellcheck shell=bash
WG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WG_ROOT
export WG_FIXTURES="$WG_ROOT/test/fixtures"
export WG_HYPRCTL="$WG_ROOT/test/bin/hyprctl-stub"
export WG_PROJECTS_DIR="/home/niro/projects"
export WG_LIB_DIR="$WG_ROOT/lib"

wg_setup_tmp() {
  WG_TMP="$(mktemp -d)"
  export WG_TMP
  export WG_STATE_DIR="$WG_TMP/state"
  export WG_DISPATCH_LOG="$WG_TMP/dispatch.log"
  : >"$WG_DISPATCH_LOG"
}

wg_teardown_tmp() {
  [[ -n ${WG_TMP:-} && -d $WG_TMP ]] && rm -rf "$WG_TMP"
  return 0
}

# Seed the state file from a fixture.
wg_seed_state() {
  mkdir -p "$WG_STATE_DIR"
  cp "$WG_FIXTURES/${1:-state.json}" "$WG_STATE_DIR/state.json"
}

# Replacement for wg_window_cwd that reads cwd.map instead of /proc.
wg_stub_cwd() {
  wg_window_cwd() {
    local pid="$1" p c
    while IFS=$'\t' read -r p c; do
      [[ $p == "$pid" ]] && { printf '%s\n' "$c"; return 0; }
    done <"$WG_FIXTURES/cwd.map"
    return 0
  }
}

dispatches() {
  cat "$WG_DISPATCH_LOG"
}

# Export library functions for bash -c subshells used in tests.
# Since bash cannot export arrays, we re-define wg_title_status and wg_title_text
# to include array setup, then export all functions.
wg_export_lib() {
  # Re-define wg_title_status with array setup
  wg_title_status() {
    local title="$1" glyph
    local WG_GLYPHS_IDLE=("✳")
    local WG_GLYPHS_BUSY=("◐" "◑")
    for glyph in "${WG_GLYPHS_IDLE[@]}"; do
      [[ $title == "$glyph"* ]] && { printf 'idle\n'; return 0; }
    done
    for glyph in "${WG_GLYPHS_BUSY[@]}"; do
      [[ $title == "$glyph"* ]] && { printf 'busy\n'; return 0; }
    done
    printf 'plain\n'
  }

  # Re-define wg_title_text with array setup
  wg_title_text() {
    local title="$1" glyph
    local WG_GLYPHS_IDLE=("✳")
    local WG_GLYPHS_BUSY=("◐" "◑")
    for glyph in "${WG_GLYPHS_IDLE[@]}" "${WG_GLYPHS_BUSY[@]}"; do
      if [[ $title == "$glyph"* ]]; then
        title="${title#"$glyph"}"
        printf '%s\n' "${title# }"
        return 0
      fi
    done
    printf '%s\n' "$title"
  }

  # Export variables that the functions depend on
  export WG_STATE_FILE WG_STATE_DIR WG_HYPRCTL WG_PROJECTS_DIR

  # Export all library functions for bash -c subshells
  export -f wg_hypr_query wg_state_default wg_state_read wg_state_write
  export -f wg_window_cwd wg_cwd_project wg_cwd_worktree wg_project_group wg_window_group
  export -f wg_title_status wg_title_text wg_window_table wg_window_row
}
