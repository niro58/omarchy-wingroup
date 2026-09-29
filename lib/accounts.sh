# shellcheck shell=bash
# Several Claude accounts on one desktop.
#
# Requires lib/state.sh for $WG_STATE_DIR, and lib/sessions.sh for
# wg_runtime_read / wg_runtime_update -- the locked read-modify-write the other
# runtime documents already go through, rather than a second one written here.
#
# An account here is a directory, not a login. Claude keeps everything a session
# is -- its credentials and, more to the point, its transcripts -- under
# CLAUDE_CONFIG_DIR, so `claude --resume <id>` can only find a conversation from
# the directory it was started in. Which account a terminal belongs to is
# therefore decided before Claude starts, by the environment, and switching
# accounts means pointing the next terminal somewhere else. Nothing in this file
# reads, writes or moves a credential: `claude auth login`, run against a
# directory, is what puts one there.
#
# The account already on the machine lives in ~/.claude and is called "default".
# It is not a row in the registry -- it exists whether or not wingroup knows
# about it -- which is why it cannot be added, redefined or removed here.

: "${WG_ACCOUNTS_FILE:=$WG_STATE_DIR/accounts.json}"
# Where the directories for added accounts are made. Under the state directory
# rather than beside ~/.claude, so that everything wingroup created is in one
# place and an uninstall has one thing to consider.
: "${WG_ACCOUNTS_DIR:=$WG_STATE_DIR/accounts}"

wg_accounts_default() { printf '%s\n' '{"active":"default","accounts":[]}'; }

wg_accounts_read() { wg_runtime_read "$WG_ACCOUNTS_FILE" "$(wg_accounts_default)"; }

# Every account, the default first, one name per line.
wg_account_list() {
  printf 'default\n'
  jq -r '.accounts[]?.name // empty' <<<"$(wg_accounts_read)"
}

wg_account_known() {
  local name="$1"
  [[ $name == default ]] && return 0
  jq -e --arg n "$name" 'any(.accounts[]?; .name == $n)' <<<"$(wg_accounts_read)" >/dev/null 2>&1
}

# The name of the account new terminals are opened under.
#
# An active account that has since been removed reads as the default rather than
# as itself: the alternative is every new shell pointing CLAUDE_CONFIG_DIR at a
# name nothing knows, which is a Claude that starts with no credentials and no
# history and looks, from the outside, like being logged out.
wg_account_active() {
  local name
  name="$(jq -r '.active // "default"' <<<"$(wg_accounts_read)")"
  wg_account_known "$name" || name=default
  printf '%s\n' "$name"
}

# The directory for $1, or for the active account when called with nothing.
#
# This is what the shell hook runs on every new terminal, so it answers from the
# state file alone -- no compositor, no network, no Claude -- and it answers
# with ~/.claude when it cannot answer properly. A shell whose CLAUDE_CONFIG_DIR
# points at a directory that does not exist is a session with no credentials and
# no transcripts; falling back to the account the machine already has is the
# failure mode that costs nothing.
wg_account_dir() {
  local name="${1:-}"
  [[ -n $name ]] || name="$(wg_account_active)"
  if [[ $name == default ]]; then
    printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    return 0
  fi
  local dir
  dir="$(jq -r --arg n "$name" 'first(.accounts[]? | select(.name == $n) | .dir) // empty' \
         <<<"$(wg_accounts_read)")"
  [[ -n $dir ]] || dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  printf '%s\n' "$dir"
}

# Registers $1 and makes it a directory. It does not become active and it has no
# credentials yet: `CLAUDE_CONFIG_DIR=<dir> claude auth login` is the next step,
# and it is the user's to take -- a login is an interactive, human thing, and
# nothing here should be in the business of holding one.
wg_account_add() {
  local name="${1:-}"
  [[ -n $name ]] || return 1
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ $name != default ]] || return 1
  mkdir -p "$WG_ACCOUNTS_DIR/$name" || return 1
  # shellcheck disable=SC2016  # jq variables
  wg_runtime_update "$WG_ACCOUNTS_FILE" "$(wg_accounts_default)" '
    if any(.accounts[]?; .name == $n) then .
    else .accounts += [{name: $n, dir: $d}]
    end
  ' --arg n "$name" --arg d "$WG_ACCOUNTS_DIR/$name"
}

wg_account_use() {
  local name="${1:-}"
  [[ -n $name ]] || return 1
  wg_account_known "$name" || return 1
  # shellcheck disable=SC2016  # jq variable
  wg_runtime_update "$WG_ACCOUNTS_FILE" "$(wg_accounts_default)" '.active = $n' --arg n "$name"
}

# Forgets $1. The directory stays: it holds that account's transcripts, and a
# session recorded against it can still be resumed from there. Forgetting an
# account is not destroying its work.
wg_account_remove() {
  local name="${1:-}"
  [[ -n $name ]] || return 1
  [[ $name != default ]] || return 1
  wg_account_known "$name" || return 1
  # shellcheck disable=SC2016  # jq variable
  wg_runtime_update "$WG_ACCOUNTS_FILE" "$(wg_accounts_default)" '
    .accounts = [.accounts[]? | select(.name != $n)]
    | if .active == $n then .active = "default" else . end
  ' --arg n "$name"
}
