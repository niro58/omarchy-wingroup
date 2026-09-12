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
# boot id. Every argument after the file and the boot is
# "<session id>:<dir>" or "<session id>:<dir>:<workspace>", and an empty id is a
# session that predates the hook -- all that was ever learned about it is the
# directory.
#
# The workspace is optional because leaving it off is a case of its own: the
# watcher records one only when a compositor answered for that session, and a
# row without one is a row the restore must not move.
wg_write_snapshot() {
  local file="$1" boot="$2"; shift 2
  local entry sessions='{}' n=0 rest cwd ws
  for entry in ${@+"$@"}; do
    n=$(( n + 1 ))
    rest="${entry#*:}"
    cwd="${rest%%:*}"
    ws=""
    [[ $rest == *:* ]] && ws="${rest#*:}"
    # The scope keys are arbitrary here: the restore never looks at them, it
    # reads the session, cwd and workspace out of each value.
    sessions="$(jq --arg scope "scope-$n.scope" --arg session "${entry%%:*}" \
                   --arg cwd "$cwd" --arg ws "$ws" \
                   '.[$scope] = ({session: $session, cwd: $cwd, source: "scan", seen: 0}
                                 + (if $ws == "" then {} else {workspace: $ws} end))' \
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
  local entry rest
  for entry in ${@+"$@"}; do
    rest="${entry#*:}"
    mkdir -p "${rest%%:*}"
  done
}

# The compositor's answer, written for one test. Every argument is
# "<address>:<pid>:<workspace>".
#
# The shared clients.json describes a desktop that is already tidy, which is the
# right fixture for counting group membership and the wrong one for every test
# here: a tidy desktop gives tidy nothing to do, and a desktop of freshly
# restored terminals is not in the fixture at all.
wg_write_clients() {
  local entry addr pid ws clients='[]'
  for entry in ${@+"$@"}; do
    addr="${entry%%:*}"
    pid="${entry#*:}"
    ws="${pid#*:}"
    pid="${pid%%:*}"
    clients="$(jq --arg a "$addr" --argjson p "$pid" --arg w "$ws" \
                  '. + [{address: $a, pid: $p, class: "Alacritty", title: "session",
                         floating: false, workspace: {id: 1, name: $w}}]' <<<"$clients")"
  done
  printf '%s\n' "$clients" >"$WG_TMP/clients.json"
  export WG_FIXTURE_CLIENTS="$WG_TMP/clients.json"
}

# A restored terminal, in $WG_PROC_DIR: the window is the terminal process and
# its child is the `bash -c` the relaunch handed the session id to, which is
# where the id can be read back off the command line. With no id given, the
# child is the plain claude a pre-hook session comes back as, and its directory
# is all there is to recognise it by.
wg_fake_terminal() {
  local pid="$1" child="$2" cwd="$3" session="${4:-}"
  mkdir -p "$WG_PROC_DIR/$pid" "$WG_PROC_DIR/$child" "$cwd"
  # Field 4 of /proc/<pid>/stat is the parent, and that is the only field the
  # restore reads out of it -- the terminal is a child of nothing in particular,
  # the shell is a child of the terminal.
  printf '%s (Alacritty) S 1 1 1 34816 1 0\n' "$pid" >"$WG_PROC_DIR/$pid/stat"
  printf '%s (bash) S %s 1 1 34816 1 0\n' "$child" "$pid" >"$WG_PROC_DIR/$child/stat"
  ln -sfn "$cwd" "$WG_PROC_DIR/$child/cwd"
  # NUL separated, the way the kernel writes it.
  if [[ -n $session ]]; then
    printf 'bash\0-c\0claude --resume "$0" || exec bash\0%s\0' "$session" \
      >"$WG_PROC_DIR/$child/cmdline"
  else
    printf 'bash\0-c\0claude || exec bash\0' >"$WG_PROC_DIR/$child/cmdline"
  fi
}

# A cwd lookup of this test file's own: bin/wingroup sources whatever
# $WG_TEST_STUB_CWD points at, and the shared stub answers only for the pids in
# the cwd.map fixture. A test that needs tidy to want to move a window has to
# give that window a directory inside a project, for a pid of its own.
wg_stub_own_cwd() {
  cat >"$WG_TMP/cwd-stub.sh" <<'STUB'
wg_children_load() { WG_CHILDREN_LOADED=1; }
WG_CHILDREN_LOADED=1
wg_window_cwd() {
  local pid="$1" p c
  while IFS=$'\t' read -r p c; do
    [[ $p == "$pid" ]] && { printf '%s\n' "$c"; return 0; }
  done <"$WG_TMP/cwd.map"
  return 0
}
STUB
  export WG_TEST_STUB_CWD="$WG_TMP/cwd-stub.sh"
  : >"$WG_TMP/cwd.map"
}

wg_window_cwd_is() { printf '%s\t%s\n' "$1" "$2" >>"$WG_TMP/cwd.map"; }

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

# The desktop this asks about is an untidy one, written here rather than taken
# from the shared fixture: that fixture now describes a desktop where every
# window is already on its group's workspace, and tidy run on it moves nothing,
# which would make this test pass for the wrong reason.
#
# 0xaaa3 is the window an override sends to another group, and tidy leaves a
# hand-placed window alone; 0xaaa6 and 0xaaa7 are in no project. So four move.
wg_untidy_desktop() {
  wg_write_clients "0xaaa1:1001:1" "0xaaa2:1002:1" "0xaaa3:1003:3" \
                   "0xaaa4:1004:1" "0xaaa5:1005:1" "0xaaa6:1006:1" "0xaaa7:1007:1"
}

@test "restore tidies afterwards so restored terminals land in their groups" {
  wg_untidy_desktop
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
  wg_untidy_desktop
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

# --- putting the terminals back ----------------------------------------------
#
# Where a window is, is the truth. The snapshot records the workspace each
# session was on, and handing the terminals to the daemon's filing by project
# instead gives back a desktop the user did not arrange: a session in a project
# no group claims lands wherever it opens, and one the user had deliberately
# moved is dragged back to its project's group.

@test "a restored session is put back on the workspace it was recorded on" {
  local shop="$WG_TMP/projects/shop-web"
  wg_make_dirs "abc-123:$shop:misc"
  wg_snapshot_from_last_boot "abc-123:$shop:misc"
  wg_fake_terminal 2001 2002 "$shop" "abc-123"
  wg_write_clients "0xbbb1:2001:1"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"place  $shop  misc"* ]]
  run dispatches
  [ "$output" = "movetoworkspacesilent name:misc,address:0xbbb1" ]
}

# No compositor answered for this session when the snapshot was written, so
# nothing is known about where it was. Inventing a workspace would be worse than
# the daemon's filing by project, which has already happened by now.
@test "a session recorded with no workspace is not moved at all" {
  local shop="$WG_TMP/projects/shop-web"
  wg_make_dirs "abc-123:$shop"
  wg_snapshot_from_last_boot "abc-123:$shop"
  wg_fake_terminal 2001 2002 "$shop" "abc-123"
  wg_write_clients "0xbbb1:2001:1"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [[ "$output" != *place* ]]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# The daemon may well have filed it correctly already -- most sessions are in a
# project their group owns, and for those the two answers agree.
@test "a session already on its recorded workspace is not dispatched at" {
  local shop="$WG_TMP/projects/shop-web"
  wg_make_dirs "abc-123:$shop:misc"
  wg_snapshot_from_last_boot "abc-123:$shop:misc"
  wg_fake_terminal 2001 2002 "$shop" "abc-123"
  wg_write_clients "0xbbb1:2001:misc"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [[ "$output" != *place* ]]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# A session from before the hook has no id on anyone's command line, so its
# window can only be recognised by the directory it was opened in.
@test "a session with no id is matched by its directory" {
  local legacy="$WG_TMP/projects/fleet-hub"
  wg_make_dirs ":$legacy:misc"
  wg_snapshot_from_last_boot ":$legacy:misc"
  wg_fake_terminal 2001 2002 "$legacy"
  wg_write_clients "0xbbb1:2001:1"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"place  $legacy  misc"* ]]
  run dispatches
  [ "$output" = "movetoworkspacesilent name:misc,address:0xbbb1" ]
}

# The ordering is the whole point, so the order of the dispatches is what is
# asserted. tidy files this window by its project, which the shop group owns;
# the record says the user had parked it on misc. Placing before tidy would
# have tidy quietly undo it, and the user would lose the arrangement again.
@test "the placement happens after tidy, so it wins over filing by project" {
  local shop="$WG_TMP/projects/shop-web"
  wg_make_dirs "abc-123:$shop:misc"
  wg_snapshot_from_last_boot "abc-123:$shop:misc"
  wg_fake_terminal 2001 2002 "$shop" "abc-123"
  wg_write_clients "0xbbb1:2001:1"
  export WG_PROJECTS_DIR="$WG_TMP/projects"
  wg_stub_own_cwd
  wg_window_cwd_is 2001 "$shop"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  run dispatches
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "movetoworkspacesilent name:shop,address:0xbbb1" ]
  [ "${lines[1]}" = "movetoworkspacesilent name:misc,address:0xbbb1" ]
}

@test "a dry run says what it would put back and moves nothing" {
  local shop="$WG_TMP/projects/shop-web"
  wg_make_dirs "abc-123:$shop:misc"
  wg_snapshot_from_last_boot "abc-123:$shop:misc"
  wg_fake_terminal 2001 2002 "$shop" "abc-123"
  wg_write_clients "0xbbb1:2001:1"

  run "$WG_ROOT/bin/wingroup-restore" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"place  $shop  misc"* ]]
  [ ! -s "$WG_DISPATCH_LOG" ]
  [ ! -s "$WG_LAUNCH_LOG" ]
}

# Everything else on the desktop: a window the user opened by hand, a browser,
# a session the snapshot never knew about. The restore has no claim on any of
# them, and moving one would be the bug this pass exists to fix, committed from
# the other side.
@test "a window that matches no recorded session is left alone" {
  local shop="$WG_TMP/projects/shop-web" other="$WG_TMP/projects/site-platform"
  wg_make_dirs "abc-123:$shop:misc"
  wg_snapshot_from_last_boot "abc-123:$shop:misc"
  wg_fake_terminal 2001 2002 "$other" "zzz-999"
  wg_write_clients "0xbbb1:2001:1"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  [[ "$output" != *place* ]]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# A scratchpad is not an arrangement.
#
# Hyprland reports those workspaces as "special:<name>", and Omarchy ships
# special:magic as the default scratchpad. "movetoworkspacesilent
# name:special:magic" does not send a window to the scratchpad -- it creates an
# ordinary workspace whose name happens to be "special:magic" and leaves the
# terminal somewhere reachable only by typing that. So a session recorded on one
# is left to the daemon to file by project instead.
@test "a session recorded on the scratchpad is not placed there" {
  local shop="$WG_TMP/projects/shop-web"
  wg_make_dirs "abc-123:$shop"
  wg_snapshot_from_last_boot "abc-123:$shop:special:magic"
  wg_fake_terminal 2001 2002 "$shop" "abc-123"
  wg_write_clients "0xbbb1:2001:1"

  run "$WG_ROOT/bin/wingroup-restore"
  [ "$status" -eq 0 ]
  run bash -c "grep -c 'special' '$WG_DISPATCH_LOG' || true"
  [ "$output" -eq 0 ]
}
