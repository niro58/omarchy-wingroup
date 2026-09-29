#!/usr/bin/env bats

# Several Claude accounts, one desktop.
#
# A conversation lives inside the configuration directory it was started in --
# Claude keeps its transcripts under CLAUDE_CONFIG_DIR -- so an account is not a
# login this switches between, it is a directory sessions belong to. That is why
# the registry stores directories and why nothing here ever touches a credential:
# `claude auth login` writes those, under whichever directory it is pointed at.
#
# The account in ~/.claude is the one that already exists on every machine this
# is installed on, so it is the registry's first entry and is never rewritten.

load helper

setup() {
  wg_setup_tmp
  # shellcheck source=lib/state.sh
  source "$WG_LIB_DIR/state.sh"
  # For wg_runtime_read / wg_runtime_update, which the registry is written
  # through -- the same locked read-modify-write the session map uses.
  # shellcheck source=lib/sessions.sh
  source "$WG_LIB_DIR/sessions.sh"
  # shellcheck source=lib/accounts.sh
  source "$WG_LIB_DIR/accounts.sh"
}

teardown() { wg_teardown_tmp; }

@test "with nothing registered, the account is the one in ~/.claude" {
  run wg_account_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.claude" ]
}

@test "the default account is listed even though nobody added it" {
  run wg_account_list
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]
}

@test "an added account gets a directory of its own" {
  wg_account_add second
  run wg_account_dir second
  [ "$status" -eq 0 ]
  [ "$output" = "$WG_ACCOUNTS_DIR/second" ]
  [ -d "$output" ]
}

@test "adding an account does not make it the active one" {
  wg_account_add second
  run wg_account_active
  [ "$output" = "default" ]
}

@test "the active account is the one wingroup hands to a new shell" {
  wg_account_add second
  wg_account_use second
  run wg_account_active
  [ "$output" = "second" ]
  run wg_account_dir
  [ "$output" = "$WG_ACCOUNTS_DIR/second" ]
}

@test "an account that was never added cannot be made active" {
  run wg_account_use ghost
  [ "$status" -ne 0 ]
  run wg_account_active
  [ "$output" = "default" ]
}

@test "adding the same account twice is not two accounts" {
  wg_account_add second
  wg_account_add second
  run wg_account_list
  [ "$output" = "default
second" ]
}

# "default" is not a row in the file -- it is ~/.claude, which exists whether or
# not wingroup knows about it. Letting it be added would put a second, empty
# directory behind the name every session on the machine is already using.
@test "the default account cannot be redefined" {
  run wg_account_add default
  [ "$status" -ne 0 ]
  run wg_account_dir default
  [ "$output" = "$HOME/.claude" ]
}

@test "removing an account leaves the others" {
  wg_account_add second
  wg_account_add third
  wg_account_remove second
  run wg_account_list
  [ "$output" = "default
third" ]
}

# The directory is left where it is: it holds that account's transcripts, and
# a session recorded against it can still be resumed after the account is
# unregistered. Forgetting an account is not the same as destroying its work.
@test "removing an account leaves its directory alone" {
  wg_account_add second
  local dir="$WG_ACCOUNTS_DIR/second"
  : >"$dir/.credentials.json"
  wg_account_remove second
  [ -f "$dir/.credentials.json" ]
}

@test "removing the active account falls back to the default" {
  wg_account_add second
  wg_account_use second
  wg_account_remove second
  run wg_account_active
  [ "$output" = "default" ]
  run wg_account_dir
  [ "$output" = "$HOME/.claude" ]
}

@test "the default account cannot be removed" {
  run wg_account_remove default
  [ "$status" -ne 0 ]
  run wg_account_list
  [ "$output" = "default" ]
}

# What the shell hook calls on every new terminal. It runs in the hot path of
# opening a terminal, so it answers from the state file alone -- no compositor,
# no network, no Claude -- and says nothing at all when it cannot answer, so a
# broken registry leaves the shell with Claude's own default rather than an
# empty CLAUDE_CONFIG_DIR pointing at nowhere.
@test "the directory of a registry that is not readable is nothing at all" {
  mkdir -p "$(dirname "$WG_ACCOUNTS_FILE")"
  printf 'not json\n' >"$WG_ACCOUNTS_FILE"
  run wg_account_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.claude" ]
}

# --- the verbs, run as the command the shell hook calls ------------------------

# `wingroup account dir` runs on every new terminal, before the prompt appears.
# One line, no decoration, nothing else on stdout: the shell hook puts it
# straight into CLAUDE_CONFIG_DIR.
@test "the dir verb prints one bare path and nothing else" {
  run "$WG_ROOT/bin/wingroup" account dir
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "$HOME/.claude" ]
}

@test "the list verb marks the account new terminals will use" {
  "$WG_ROOT/bin/wingroup" account add second
  "$WG_ROOT/bin/wingroup" account use second
  run "$WG_ROOT/bin/wingroup" account list
  [ "$status" -eq 0 ]
  [[ "$output" == *"* second"* ]]
  [[ "$output" == *"  default"* ]]
}

# Adding an account is half the job and the command says so: the half it cannot
# do is the login, which is interactive and belongs to the user.
@test "adding an account says how to log it in" {
  run "$WG_ROOT/bin/wingroup" account add second
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude auth login"* ]]
  [[ "$output" == *"$WG_ACCOUNTS_DIR/second"* ]]
}

@test "using an account that does not exist fails and says so" {
  run "$WG_ROOT/bin/wingroup" account use ghost
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such account"* ]]
}

@test "asking for one account's directory does not change the active one" {
  wg_account_add second
  run wg_account_dir second
  [ "$output" = "$WG_ACCOUNTS_DIR/second" ]
  run wg_account_active
  [ "$output" = "default" ]
}
