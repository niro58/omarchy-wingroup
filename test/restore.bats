#!/usr/bin/env bats
#
# There are two ways for the restore to know what was open, and the tests come
# in two halves accordingly.
#
# The snapshot is a record the watcher wrote while the sessions were running,
# and it is what the restore uses whenever it has one. The rest is the fallback
# for a boot with no such record, which guesses from session file timestamps --
# still worth having, and still tested, but no longer the main path.

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  export WG_RESTORE_LOG="$WG_TMP/restore.log"
  : >"$WG_RESTORE_LOG"
  # The daemon looks for this exact path; it is spelled out here rather than
  # read off either script, so that the two agreeing on it is what is tested.
  WG_FLAG="$XDG_RUNTIME_DIR/wingroup-restoring"
  export WG_RESTORE_SCRIPT="$WG_ROOT/test/bin/restore-stub"
  export WG_RESTORE_SETTLE=0
  export PATH="$WG_ROOT/bin:$PATH"

  # The two snapshot paths, spelled out for the same reason $WG_FLAG is: the
  # watcher writes these files and the restore reads them, and what is being
  # tested is that the two agree on where they are.
  WG_SNAPSHOT="$WG_STATE_DIR/sessions-snapshot.json"
  WG_SNAPSHOT_PREVIOUS="$WG_STATE_DIR/sessions-snapshot.prev.json"

  # The kernel's boot id, faked. The whole safety question the restore asks is
  # "was this written before the machine came up", and a test reading the real
  # boot id could not write a snapshot from any boot but this one.
  WG_BOOT_NOW="4f8e2c10-boot-now"
  WG_BOOT_BEFORE="1a77bd93-boot-before"
  export WG_BOOT_ID_FILE="$WG_TMP/boot-id"
  printf '%s\n' "$WG_BOOT_NOW" >"$WG_BOOT_ID_FILE"
}

teardown() { wg_teardown_tmp; }

# Writes a snapshot the way the watcher does: the session map, stamped with a
# boot id. Every argument after the file and the boot is "<session id>:<dir>",
# and an empty id is a session that predates the hook -- all that was ever
# learned about it is the directory.
wg_write_snapshot() {
  local file="$1" boot="$2"; shift 2
  local entry sessions='{}' n=0
  for entry in ${@+"$@"}; do
    n=$(( n + 1 ))
    # The scope keys are arbitrary here: the restore never looks at them, it
    # reads the session and cwd out of each value.
    sessions="$(jq --arg scope "scope-$n.scope" --arg session "${entry%%:*}" \
                   --arg cwd "${entry#*:}" \
                   '.[$scope] = {session: $session, cwd: $cwd, source: "scan", seen: 0}' \
                   <<<"$sessions")"
  done
  mkdir -p "$WG_STATE_DIR"
  jq -n --arg boot "$boot" --argjson sessions "$sessions" \
     '{boot: $boot, sessions: $sessions}' >"$file"
}

# The record a previous boot left behind -- the case a restore exists for.
wg_snapshot_from_last_boot() {
  wg_write_snapshot "$WG_SNAPSHOT" "$WG_BOOT_BEFORE" ${@+"$@"}
}

# Makes the directories a snapshot's entries point at, so that "the directory
# is gone" is only ever true for a test that means it.
wg_make_dirs() {
  local entry
  for entry in ${@+"$@"}; do mkdir -p "${entry#*:}"; done
}

# The terminals are spawned in the background, so the log can lag the script
# that asked for them. Bounded polling rather than a sleep: a sleep long enough
# to be safe here would be paid by every test in the file.
wait_until() {
  local i=0
  while (( i++ < 100 )); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

launched_at_least() { (( $(wc -l <"$WG_LAUNCH_LOG") >= $1 )); }

launch_count() { wc -l <"$WG_LAUNCH_LOG"; }

# Matched against the whole launch line rather than a field of it, because the
# two facts that matter belong together: which directory the terminal was
# opened in, and which session it was told to pick up there.
launched_resume() {
  local cwd="$1" session="$2" line
  while IFS= read -r line; do
    [[ $line == *"--dir=$cwd"*"claude --resume"*$'\t'"$session"$'\t'* ]] && return 0
  done <"$WG_LAUNCH_LOG"
  return 1
}

# A terminal opened in $1 running a plain claude -- no id was recorded, so
# there is nothing to resume.
launched_fresh() {
  local cwd="$1" line
  while IFS= read -r line; do
    [[ $line == *"--dir=$cwd"* && $line != *--resume* ]] && return 0
  done <"$WG_LAUNCH_LOG"
  return 1
}

launched_in() {
  local cwd="$1" line
  while IFS= read -r line; do
    [[ $line == *"--dir=$cwd"* ]] && return 0
  done <"$WG_LAUNCH_LOG"
  return 1
}

# Also asserts that nothing was launched: the fallback is for a boot with no
# record of what was open, and the restore must not have relaunched anything
# out of a record it does not have.
@test "restore runs the session restore script" {
  "$WG_ROOT/bin/wingroup-restore"
  run cat "$WG_RESTORE_LOG"
  [[ "$output" == restore* ]]
  [ ! -s "$WG_LAUNCH_LOG" ]
}

@test "restore tidies afterwards so restored terminals land in their groups" {
  "$WG_ROOT/bin/wingroup-restore"
  run bash -c "wc -l <'$WG_DISPATCH_LOG'"
  [ "$output" -eq 4 ]
}

@test "restore passes its arguments through and tidies nothing on a dry run" {
  "$WG_ROOT/bin/wingroup-restore" --dry-run
  run cat "$WG_RESTORE_LOG"
  [ "$output" = "restore --dry-run" ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "restore succeeds and tidies nothing when no restore script is installed" {
  export WG_RESTORE_SCRIPT="$WG_TMP/does-not-exist.sh"
  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# Fourteen terminals respawning at login, each one followed onto its group's
# workspace, is the desktop bouncing around for a minute. The flag is how the
# restore tells the daemon to keep filing them silently.
@test "restore suppresses following while it spawns terminals" {
  "$WG_ROOT/bin/wingroup-restore"
  run cat "$WG_RESTORE_LOG.flag"
  [ "$output" = "flag present" ]
}

@test "restore clears the suppression when it is done" {
  "$WG_ROOT/bin/wingroup-restore"
  [ ! -e "$WG_FLAG" ]
}

# A restore script that dies must not leave following switched off for the rest
# of the session -- the user would silently lose windows again, which is the bug
# this whole setting exists to fix.
@test "a failing restore script still clears the suppression" {
  printf '#!/usr/bin/env bash\nexit 3\n' >"$WG_TMP/failing-restore"
  chmod +x "$WG_TMP/failing-restore"
  export WG_RESTORE_SCRIPT="$WG_TMP/failing-restore"
  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 3 ]
  [ ! -e "$WG_FLAG" ]
}

@test "a dry run clears the suppression too" {
  "$WG_ROOT/bin/wingroup-restore" --dry-run
  [ ! -e "$WG_FLAG" ]
}

# tidy is a bulk move by definition, and it goes through bin/wingroup rather
# than the daemon: it stays silent whatever the follow setting says.
@test "the tidy pass files restored terminals silently" {
  "$WG_ROOT/bin/wingroup-restore"
  run bash -c "grep -c '^movetoworkspacesilent ' '$WG_DISPATCH_LOG'"
  [ "$output" -eq 4 ]
  run bash -c "grep -c '^movetoworkspace ' '$WG_DISPATCH_LOG' || true"
  [ "$output" -eq 0 ]
}

# --- the snapshot path -------------------------------------------------------
#
# What the fallback above gets wrong is why these exist. Measured on a real
# machine after a real reboot, guessing from timestamps dropped three sessions
# that were open -- idle 29 minutes and 2 hours, so outside the cluster it
# anchors on -- and reopened four that were not.

@test "the sessions in a previous boot's snapshot are relaunched from the record" {
  local shop="$WG_TMP/projects/shop-web" site="$WG_TMP/projects/site-platform"
  wg_make_dirs "abc-123:$shop" "def-456:$site"
  wg_snapshot_from_last_boot "abc-123:$shop" "def-456:$site"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume $shop  abc-123"* ]]
  [[ "$output" == *"resume $site  def-456"* ]]
  [[ "$output" == *"restored 2 session(s)"* ]]

  wait_until launched_at_least 2
  [ "$(launch_count)" -eq 2 ]
  launched_resume "$shop" "abc-123"
  launched_resume "$site" "def-456"
}

# The row with no session id is the one the obvious way of splitting a tab
# separated line silently loses: tab is IFS whitespace, so `read -r session cwd`
# collapses the empty first column and slides the directory into the id, and the
# row is then dropped for having no directory. It is also the row that matters
# most to the user who has it -- a session from before the hook existed, whose
# directory is the only thing anyone ever learned about it.
@test "a snapshot entry with no session id opens a plain claude in its directory" {
  local legacy="$WG_TMP/projects/fleet-hub" shop="$WG_TMP/projects/shop-web"
  wg_make_dirs ":$legacy" "abc-123:$shop"
  wg_snapshot_from_last_boot ":$legacy" "abc-123:$shop"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fresh  $legacy"* ]]
  [[ "$output" == *"restored 2 session(s)"* ]]

  wait_until launched_at_least 2
  [ "$(launch_count)" -eq 2 ]
  launched_fresh "$legacy"
  launched_resume "$shop" "abc-123"
}

# A project that was deleted, moved, or lives on a drive that has not been
# mounted yet. Opening a terminal in a directory that is not there gets the
# user a shell somewhere they did not ask for, so say so and move on.
@test "a snapshot entry whose directory is gone is skipped and the rest still go" {
  local shop="$WG_TMP/projects/shop-web" site="$WG_TMP/projects/site-platform"
  local gone="$WG_TMP/projects/deleted-thing"
  wg_make_dirs "abc-123:$shop" "def-456:$site"
  wg_snapshot_from_last_boot "abc-123:$shop" "ghi-789:$gone" "def-456:$site"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip   $gone  (directory is gone)"* ]]
  [[ "$output" == *"restored 2 session(s)"* ]]

  wait_until launched_at_least 2
  [ "$(launch_count)" -eq 2 ]
  launched_resume "$shop" "abc-123"
  launched_resume "$site" "def-456"
  ! launched_in "$gone"
}

# The fallback guesses, and its guesses were wrong in both directions. With a
# record in hand there is nothing to guess about, so it must not run at all --
# every session it invented would be a second terminal on the user's screen.
@test "a usable snapshot means the fallback script is never asked" {
  local shop="$WG_TMP/projects/shop-web"
  wg_make_dirs "abc-123:$shop"
  wg_snapshot_from_last_boot "abc-123:$shop"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [ ! -s "$WG_RESTORE_LOG" ]
  wait_until launched_at_least 1
  [ "$(launch_count)" -eq 1 ]
}

# The one a wrong answer costs the most. The watcher writes the snapshot after
# every scan, so on a machine that has been up for a minute there is always a
# file sitting there describing the sessions that are on screen right now.
# Restoring from it would open a duplicate terminal for every one of them.
@test "a snapshot stamped with the current boot is not restored from" {
  local shop="$WG_TMP/projects/shop-web"
  wg_make_dirs "abc-123:$shop"
  wg_write_snapshot "$WG_SNAPSHOT" "$WG_BOOT_NOW" "abc-123:$shop"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [ ! -s "$WG_LAUNCH_LOG" ]
  # Nothing is known to have been open before this boot, so this is a boot with
  # no record, and the fallback is exactly right here.
  [[ "$(cat "$WG_RESTORE_LOG")" == restore* ]]
}

# .prev is where the watcher puts the outgoing snapshot on the first scan of a
# new boot, so on a machine where the watcher came up before the restore did,
# this is the file the restore actually reads.
@test "the previous boot's record is read from .prev when the watcher has moved it" {
  local shop="$WG_TMP/projects/shop-web"
  wg_make_dirs "abc-123:$shop"
  wg_write_snapshot "$WG_SNAPSHOT_PREVIOUS" "$WG_BOOT_BEFORE" "abc-123:$shop"
  # And the live one the watcher wrote in its place, which describes now.
  wg_write_snapshot "$WG_SNAPSHOT" "$WG_BOOT_NOW"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume $shop  abc-123"* ]]
  wait_until launched_at_least 1
  [ "$(launch_count)" -eq 1 ]
  launched_resume "$shop" "abc-123"
}

@test "a dry run on the snapshot path says what would come back and spawns nothing" {
  local shop="$WG_TMP/projects/shop-web" legacy="$WG_TMP/projects/fleet-hub"
  wg_make_dirs "abc-123:$shop" ":$legacy"
  wg_snapshot_from_last_boot "abc-123:$shop" ":$legacy"

  run "$WG_ROOT/bin/wingroup-restore" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume $shop  abc-123"* ]]
  [[ "$output" == *"fresh  $legacy"* ]]
  [ ! -s "$WG_LAUNCH_LOG" ]
  [ ! -s "$WG_DISPATCH_LOG" ]
  [ ! -e "$WG_FLAG" ]
}

# The same bargain the fallback path makes: a dozen terminals coming back at
# once must not drag the desktop from workspace to workspace while the user
# watches. The snapshot path spawns them itself rather than handing off to a
# script, so it has to hold the flag over its own launches.
@test "the suppression is in place while the snapshot's terminals are spawned" {
  local shop="$WG_TMP/projects/shop-web"
  wg_make_dirs "abc-123:$shop"
  wg_snapshot_from_last_boot "abc-123:$shop"
  # A launcher of this test's own: the shared stub records the arguments, and
  # what this test needs recorded is what was true on disk at the moment the
  # terminal was asked for.
  cat >"$WG_TMP/flag-launcher" <<EOF
#!/usr/bin/env bash
if [[ -e "$WG_FLAG" ]]; then printf 'flag present\n' >>"$WG_TMP/launch.flag"; fi
EOF
  chmod +x "$WG_TMP/flag-launcher"
  export WG_LAUNCH_CMD="$WG_TMP/flag-launcher"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  wait_until test -s "$WG_TMP/launch.flag"
  [ "$(cat "$WG_TMP/launch.flag")" = "flag present" ]
  [ ! -e "$WG_FLAG" ]
}

# And it has to come off again however the restore ends. Following left switched
# off for the rest of the session is the bug the flag exists to avoid, and a
# tidy pass that dies once the terminals are already up is the easiest way there.
@test "a snapshot restore that dies on the way out still clears the suppression" {
  local shop="$WG_TMP/projects/shop-web"
  wg_make_dirs "abc-123:$shop"
  wg_snapshot_from_last_boot "abc-123:$shop"
  mkdir -p "$WG_TMP/bin"
  printf '#!/usr/bin/env bash\nexit 3\n' >"$WG_TMP/bin/wingroup"
  chmod +x "$WG_TMP/bin/wingroup"
  export PATH="$WG_TMP/bin:$PATH"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 3 ]
  [ ! -e "$WG_FLAG" ]
}

# Which of the two files holds the last boot's record depends on whether the
# watcher wrote before the restore ran, so both can be from earlier boots at
# once -- the main file from the boot that just ended, .prev from the one
# before it. Restoring from .prev there brings back a set of terminals that has
# been wrong for a whole session.
@test "the newer of two old snapshots is the one restored from" {
  local shop="$WG_TMP/projects/shop-web" stale="$WG_TMP/projects/fleet-hub"
  wg_make_dirs "abc-123:$shop" "old-999:$stale"
  wg_write_snapshot "$WG_SNAPSHOT_PREVIOUS" "0000aaaa-boot-older" "old-999:$stale"
  wg_snapshot_from_last_boot "abc-123:$shop"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume $shop  abc-123"* ]]
  wait_until launched_at_least 1
  [ "$(launch_count)" -eq 1 ]
  launched_resume "$shop" "abc-123"
  ! launched_in "$stale"
}

# "Nothing was open when you shut down" is an answer, and doing nothing is the
# right thing to do with it.
#
# This is the case that made the count the wrong thing to branch on. Close every
# Claude terminal, reboot, and the last scan writes a snapshot with no sessions
# in it -- a correct, complete record. Reading that as "no record" hands over to
# the guesser, which reopens whatever was written to most recently: the exact
# behaviour the snapshot exists to replace, arriving through the front door.
@test "a previous boot that recorded no open sessions restores nothing" {
  wg_snapshot_from_last_boot

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [ ! -s "$WG_RESTORE_LOG" ]
  [ ! -s "$WG_LAUNCH_LOG" ]
}

# Same distinction, reached the other way: there was a record, it named one
# session, and its directory has not come back -- an unmounted drive, a worktree
# that was removed. Nothing can be restored, but the record was still read, and
# guessing on top of it would invent terminals the record never mentioned.
@test "a record whose only directory is gone does not fall back to guessing" {
  wg_snapshot_from_last_boot "abc-123:$WG_TMP/projects/never-existed"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"directory is gone"* ]]
  [ ! -s "$WG_RESTORE_LOG" ]
  [ ! -s "$WG_LAUNCH_LOG" ]
}
