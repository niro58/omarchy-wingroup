# shellcheck shell=bash
# Requires lib/hypr.sh and lib/state.sh to be sourced first.

: "${WG_PROJECTS_DIR:=$HOME/projects}"

# Glyphs Claude Code puts at the head of the window title.
# Verified empirically: a finishing session goes ◐ → ✳; a working one
# alternates ◐ ↔ ◑. Add newly observed glyphs to these arrays and nowhere else.
WG_GLYPHS_IDLE=("✳")
WG_GLYPHS_BUSY=("◐" "◑")

# Mirrors omarchy-cmd-terminal-cwd: the window's pid is the terminal, its
# last child is the shell, and the shell's cwd is what we want.
wg_window_cwd() {
  local pid="$1" shell_pid cwd shell
  shell_pid="$(pgrep -P "$pid" 2>/dev/null | tail -n1)"
  [[ -n $shell_pid ]] || return 0
  cwd="$(readlink -f "/proc/$shell_pid/cwd" 2>/dev/null)" || return 0
  shell="$(readlink -f "/proc/$shell_pid/exe" 2>/dev/null)" || return 0
  if grep -qs -- "$shell" /etc/shells && [[ -d $cwd ]]; then
    printf '%s\n' "$cwd"
  fi
}

wg_cwd_project() {
  local cwd="$1" rest
  [[ -n $cwd ]] || return 0
  [[ $cwd == "$WG_PROJECTS_DIR"/* ]] || return 0
  rest="${cwd#"$WG_PROJECTS_DIR"/}"
  printf '%s\n' "${rest%%/*}"
}

wg_cwd_worktree() {
  local cwd="$1" rest
  [[ $cwd == *"/.claude/worktrees/"* ]] || return 0
  rest="${cwd#*/.claude/worktrees/}"
  printf '%s\n' "${rest%%/*}"
}

wg_project_group() {
  local project="$1" state="${2:-$(wg_state_read)}"
  [[ -n $project ]] || return 0
  jq -r --arg p "$project" \
    'first(.groups[] | select(.projects | index($p)) | .name) // empty' <<<"$state"
}

wg_window_group() {
  local address="$1" project="$2" state="${3:-$(wg_state_read)}" override
  override="$(jq -r --arg a "$address" '.overrides[$a] // empty' <<<"$state")"
  if [[ -n $override ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  wg_project_group "$project" "$state"
}

wg_title_status() {
  local title="$1" glyph
  for glyph in "${WG_GLYPHS_IDLE[@]}"; do
    [[ $title == "$glyph"* ]] && { printf 'idle\n'; return 0; }
  done
  for glyph in "${WG_GLYPHS_BUSY[@]}"; do
    [[ $title == "$glyph"* ]] && { printf 'busy\n'; return 0; }
  done
  printf 'plain\n'
}

wg_title_text() {
  local title="$1" glyph
  for glyph in "${WG_GLYPHS_IDLE[@]}" "${WG_GLYPHS_BUSY[@]}"; do
    if [[ $title == "$glyph"* ]]; then
      title="${title#"$glyph"}"
      printf '%s\n' "${title# }"
      return 0
    fi
  done
  printf '%s\n' "$title"
}

wg_window_table() {
  local clients="${1:-}" state
  [[ -n $clients ]] || clients="$(wg_hypr_query clients)"
  state="$(wg_state_read)"

  local address pid workspace floating title
  local cwd project worktree group status
  while IFS=$'\t' read -r address pid workspace floating title; do
    cwd="$(wg_window_cwd "$pid")"
    project="$(wg_cwd_project "$cwd")"
    worktree="$(wg_cwd_worktree "$cwd")"
    group="$(wg_window_group "$address" "$project" "$state")"
    status="$(wg_title_status "$title")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$address" "$pid" "$workspace" "$floating" \
      "$group" "$status" "$project" "$worktree" "$title"
  done < <(jq -r '.[] | [.address, (.pid|tostring), .workspace.name, (.floating|tostring), .title] | @tsv' <<<"$clients")
}

wg_window_row() {
  local address="$1" clients="${2:-}"
  wg_window_table "$clients" | awk -F'\t' -v a="$address" '$1 == a'
}
