# omarchy-wingroup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group Hyprland windows by project — a clickable strip of short group names in waybar, a walker picker on a keybind, and automatic filing of new windows into their project's group by working directory.

**Architecture:** A group is a named Hyprland workspace plus metadata in a JSON state file. Three thin executables (`wingroup`, `wingroup-daemon`, `wingroup-waybar`) sit on top of one shared resolution library, so the picker, the daemon and the bar can never disagree about which group a window belongs to. Every compositor interaction funnels through `lib/hypr.sh`, which tests replace with a stub.

**Tech Stack:** bash 5 + `jq`, `socat` (Hyprland event socket), `walker` (dmenu mode), waybar custom modules. Tests: `bats` + `shellcheck`. No build step, no compiled dependencies.

**Spec:** `docs/superpowers/specs/2026-09-08-omarchy-wingroup-design.md`

## Global Constraints

- Every script starts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- `shellcheck` must pass clean over every file in `bin/` and `lib/`. This is enforced by a bats test, not by discipline.
- Runtime dependencies are exactly: `hyprctl`, `jq`, `socat`, `walker`, `waybar`, `pkill`. Adding any other dependency is out of scope.
- **No test may touch the live compositor.** No `hyprctl` call, no `pkill`, no daemon start. Everything goes through `lib/hypr.sh`, stubbed via `$WG_HYPRCTL`.
- Paths are overridable so tests never read or write real user state:
  `WG_STATE_DIR` (default `$HOME/.local/state/omarchy/wingroup`),
  `WG_PROJECTS_DIR` (default `$HOME/projects`),
  `WG_HYPRCTL` (default `hyprctl`),
  `WG_LIB_DIR` (default: the `lib/` dir next to the script).
- Waybar refresh signal is **`SIGRTMIN+11`**. Signals 7, 8, 9 and 10 are already taken by Omarchy's own modules — do not reuse them.
- The bar has exactly **8 slots**, `custom/wingroup0` through `custom/wingroup7`.
- Status glyphs: `✳` = idle, `◐`/`◑` = busy, anything else = plain. Unknown glyphs classify as `plain`; they never raise an error.
- Default `catchall` is `null`, meaning **a window with no project match is left exactly where it is**. Never invent a group for it.
- Auto-assignment happens **only** on `openwindow`, once per window address, and never for a floating window.
- All work happens on branch `feat/wingroup-implementation`, never on `main`. Open a PR at the end.

---

### Task 1: Test harness, fixtures, and the compositor boundary

Everything downstream is tested against these fixtures, and every compositor call in the project goes through the two functions written here. Nothing else can be built or verified until this exists.

**Files:**
- Create: `lib/hypr.sh`
- Create: `test/helper.bash`
- Create: `test/bin/hyprctl-stub`
- Create: `test/fixtures/clients.json`
- Create: `test/fixtures/activeworkspace.json`
- Create: `test/fixtures/activeworkspace-shop.json`
- Create: `test/fixtures/state.json`
- Create: `test/fixtures/cwd.map`
- Create: `test/fixtures/events.txt`
- Test: `test/hypr.bats`, `test/shellcheck.bats`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `wg_hypr_query <args...>` — runs `$WG_HYPRCTL -j <args>`, prints JSON to stdout.
  - `wg_hypr_dispatch <args...>` — runs `$WG_HYPRCTL dispatch <args>`.
  - `test/helper.bash` exporting `WG_ROOT`, `WG_FIXTURES`, `WG_HYPRCTL`, `WG_DISPATCH_LOG`, `WG_STATE_DIR`, `WG_PROJECTS_DIR`, and defining `wg_stub_cwd` (a `wg_window_cwd` replacement backed by `cwd.map`) and `dispatches` (prints the dispatch log).

- [ ] **Step 1: Create the branch**

```bash
cd ~/projects/omarchy-wingroup
git checkout -b feat/wingroup-implementation
```

- [ ] **Step 2: Write the fixtures**

`test/fixtures/clients.json` — seven windows covering every case the code must handle: a plain project window, a worktree window, a window whose group comes from an override, two more project windows, a non-Claude shell with no project, and a floating non-terminal window.

```json
[
  {"address":"0xaaa1","pid":1001,"class":"Alacritty","title":"✳ Everest-web full redesign","floating":false,"workspace":{"id":1,"name":"1"}},
  {"address":"0xaaa2","pid":1002,"class":"Alacritty","title":"◐ Odtah vozidla price unit handling","floating":false,"workspace":{"id":1,"name":"1"}},
  {"address":"0xaaa3","pid":1003,"class":"Alacritty","title":"◑ Sentry errors review","floating":false,"workspace":{"id":3,"name":"3"}},
  {"address":"0xaaa4","pid":1004,"class":"Alacritty","title":"✳ Connectors spec","floating":false,"workspace":{"id":1,"name":"1"}},
  {"address":"0xaaa5","pid":1005,"class":"Alacritty","title":"◐ CMS preview 503 error","floating":false,"workspace":{"id":1,"name":"1"}},
  {"address":"0xaaa6","pid":1006,"class":"Alacritty","title":"dev@host:~","floating":false,"workspace":{"id":1,"name":"1"}},
  {"address":"0xaaa7","pid":1007,"class":"org.gnome.Nautilus","title":"Home","floating":true,"workspace":{"id":1,"name":"1"}}
]
```

`test/fixtures/cwd.map` — pid to working directory, tab-separated. Backs the `wg_window_cwd` stub so no test reads `/proc`.

```
1001	/home/dev/projects/shop-web
1002	/home/dev/projects/shop-core/.claude/worktrees/price-units
1003	/home/dev/projects/shop-api
1004	/home/dev/projects/site-platform/.claude/worktrees/spec-draft
1005	/home/dev/projects/site-platform
1006	/home/dev
1007	/home/dev
```

`test/fixtures/state.json` — two groups, one of which owns three projects, plus one override that deliberately contradicts project resolution (`0xaaa3` is in `shop-api` but overridden to `site`).

```json
{
  "auto": true,
  "catchall": null,
  "groups": [
    {"name":"shop","label":"shop","projects":["shop-web","shop-core","shop-api"],"monitor":null},
    {"name":"site","label":"site","projects":["site-platform"],"monitor":null},
    {"name":"fleet","label":"fleet","projects":["fleet-hub"],"monitor":null}
  ],
  "overrides": {"0xaaa3":"site"}
}
```

This fixture set yields: `shop` = 2 windows (1 busy), `site` = 3 windows (2 busy),
`fleet` = 0 windows (its project `fleet-hub` has no window open, which is what
exercises the empty-count rendering), and 2 windows ungrouped.

`test/fixtures/activeworkspace.json`:

```json
{"id":1,"name":"1"}
```

`test/fixtures/activeworkspace-shop.json`:

```json
{"id":-99,"name":"shop"}
```

`test/fixtures/events.txt` — recorded Hyprland event lines. Note that addresses on the event socket carry **no** `0x` prefix.

```
openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign
openwindow>>aaa7,1,org.gnome.Nautilus,Home
openwindow>>aaa6,1,Alacritty,dev@host:~
openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign
windowtitle>>aaa1
windowtitle>>aaa2
windowtitle>>aaa3
```

- [ ] **Step 3: Write the hyprctl stub**

`test/bin/hyprctl-stub` (make it executable with `chmod +x`):

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == dispatch ]]; then
  shift
  printf '%s\n' "$*" >>"$WG_DISPATCH_LOG"
  exit 0
fi

if [[ ${1:-} == -j ]]; then
  case ${2:-} in
    clients) cat "$WG_FIXTURES/clients.json" ;;
    activeworkspace) cat "${WG_FIXTURE_ACTIVEWS:-$WG_FIXTURES/activeworkspace.json}" ;;
    *) printf 'hyprctl-stub: unhandled query %s\n' "${2:-}" >&2; exit 1 ;;
  esac
  exit 0
fi

printf 'hyprctl-stub: unhandled invocation %s\n' "$*" >&2
exit 1
```

- [ ] **Step 4: Write the test helper**

`test/helper.bash`:

```bash
# shellcheck shell=bash
WG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WG_ROOT
export WG_FIXTURES="$WG_ROOT/test/fixtures"
export WG_HYPRCTL="$WG_ROOT/test/bin/hyprctl-stub"
export WG_PROJECTS_DIR="/home/dev/projects"
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
```

- [ ] **Step 5: Write the failing tests**

`test/hypr.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  source "$WG_ROOT/lib/hypr.sh"
}

teardown() { wg_teardown_tmp; }

@test "wg_hypr_query returns the clients fixture as JSON" {
  run wg_hypr_query clients
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" -eq 7 ]
}

@test "wg_hypr_query reads the active workspace" {
  run wg_hypr_query activeworkspace
  [ "$status" -eq 0 ]
  [ "$(jq -r '.name' <<<"$output")" = "1" ]
}

@test "wg_hypr_dispatch records the dispatch instead of running it" {
  wg_hypr_dispatch movetoworkspacesilent "name:shop,address:0xaaa1"
  [ "$(dispatches)" = "movetoworkspacesilent name:shop,address:0xaaa1" ]
}

@test "wg_hypr_query fails loudly on an unhandled query" {
  run wg_hypr_query monitors
  [ "$status" -ne 0 ]
}
```

`test/shellcheck.bats`:

```bash
#!/usr/bin/env bats

load helper

@test "there is at least one script to check" {
  run bash -c "ls $WG_ROOT/lib/*.sh | wc -l"
  [ "$output" -ge 1 ]
}

@test "shellcheck passes on every script" {
  run bash -c "cd '$WG_ROOT' && shopt -s nullglob && shellcheck -x lib/*.sh bin/* ./*.sh 2>&1"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 6: Run the tests to verify they fail**

Run: `cd ~/projects/omarchy-wingroup && bats test/`
Expected: FAIL — `lib/hypr.sh: No such file or directory`.

- [ ] **Step 7: Write the implementation**

`lib/hypr.sh`:

```bash
# shellcheck shell=bash
# Every interaction with the compositor goes through these two functions,
# so that tests can replace hyprctl with a stub via $WG_HYPRCTL.

: "${WG_HYPRCTL:=hyprctl}"

wg_hypr_query() {
  "$WG_HYPRCTL" -j "$@"
}

wg_hypr_dispatch() {
  "$WG_HYPRCTL" dispatch "$@"
}
```

`bin/` and the top-level `*.sh` scripts do not exist yet, which is why the test
enables `nullglob` and runs from `$WG_ROOT` — an unmatched glob must expand to
nothing rather than to a literal path shellcheck then fails to open. As later
tasks add `bin/wingroup`, `install.sh` and `uninstall.sh`, this one test starts
covering them with no change.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd ~/projects/omarchy-wingroup && bats test/`
Expected: PASS, 6 tests.

- [ ] **Step 9: Commit**

```bash
git add lib/hypr.sh test/
git commit -m "test: add harness, fixtures, and the compositor boundary"
```

---

### Task 2: State file

**Files:**
- Create: `lib/state.sh`
- Test: `test/state.bats`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `wg_state_default` → prints `{"auto":true,"catchall":null,"groups":[],"overrides":{}}`
  - `wg_state_read` → prints the state JSON; seeds the default if missing; on unparseable input moves the bad file to `state.json.corrupt` and seeds the default
  - `wg_state_write <json>` → atomic write (temp file in the same directory, then `mv`)
  - `wg_state_group_names [state_json]` → newline-separated group names in order
  - `wg_state_group_field <name> <field> [state_json]` → one field of one group; empty if absent
  - `wg_state_prune_overrides [state_json]` → reads live addresses on stdin, prints state JSON with unknown override keys removed

- [ ] **Step 1: Write the failing tests**

`test/state.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  source "$WG_ROOT/lib/state.sh"
}

teardown() { wg_teardown_tmp; }

@test "wg_state_read seeds the default when no state file exists" {
  run wg_state_read
  [ "$status" -eq 0 ]
  [ "$(jq -r '.auto' <<<"$output")" = "true" ]
  [ "$(jq -r '.catchall' <<<"$output")" = "null" ]
  [ "$(jq '.groups | length' <<<"$output")" -eq 0 ]
  [ -f "$WG_STATE_DIR/state.json" ]
}

@test "wg_state_read returns the seeded fixture" {
  wg_seed_state
  run wg_state_read
  [ "$(jq -r '.groups[0].name' <<<"$output")" = "shop" ]
  [ "$(jq -r '.overrides["0xaaa3"]' <<<"$output")" = "site" ]
}

@test "wg_state_read recovers from a corrupt file and preserves it" {
  mkdir -p "$WG_STATE_DIR"
  printf 'not json at all' >"$WG_STATE_DIR/state.json"
  run wg_state_read
  [ "$status" -eq 0 ]
  [ "$(jq '.groups | length' <<<"$output")" -eq 0 ]
  [ -f "$WG_STATE_DIR/state.json.corrupt" ]
  [ "$(cat "$WG_STATE_DIR/state.json.corrupt")" = "not json at all" ]
}

@test "wg_state_write replaces the file atomically and leaves no temp files" {
  wg_seed_state
  wg_state_write "$(jq '.auto = false' "$WG_STATE_DIR/state.json")"
  [ "$(jq -r '.auto' "$WG_STATE_DIR/state.json")" = "false" ]
  run bash -c "ls $WG_STATE_DIR | grep -c . "
  [ "$output" -eq 1 ]
}

@test "wg_state_group_names lists groups in order" {
  wg_seed_state
  run wg_state_group_names
  [ "${lines[0]}" = "shop" ]
  [ "${lines[1]}" = "site" ]
}

@test "wg_state_group_field reads a scalar and a missing group" {
  wg_seed_state
  run wg_state_group_field shop label
  [ "$output" = "shop" ]
  run wg_state_group_field nosuch label
  [ "$output" = "" ]
}

@test "wg_state_prune_overrides drops addresses that are gone" {
  wg_seed_state
  run bash -c "printf '0xaaa1\n0xaaa2\n' | { source '$WG_ROOT/lib/state.sh'; wg_state_prune_overrides; }"
  [ "$(jq '.overrides | length' <<<"$output")" -eq 0 ]
}

@test "wg_state_prune_overrides keeps addresses that are still live" {
  wg_seed_state
  run bash -c "printf '0xaaa3\n' | { source '$WG_ROOT/lib/state.sh'; wg_state_prune_overrides; }"
  [ "$(jq -r '.overrides["0xaaa3"]' <<<"$output")" = "site" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/state.bats`
Expected: FAIL — `lib/state.sh: No such file or directory`.

- [ ] **Step 3: Write the implementation**

`lib/state.sh`:

```bash
# shellcheck shell=bash

: "${WG_STATE_DIR:=$HOME/.local/state/omarchy/wingroup}"
WG_STATE_FILE="$WG_STATE_DIR/state.json"

wg_state_default() {
  printf '%s\n' '{"auto":true,"catchall":null,"groups":[],"overrides":{}}'
}

wg_state_read() {
  if [[ ! -f $WG_STATE_FILE ]]; then
    wg_state_write "$(wg_state_default)"
  elif ! jq -e . "$WG_STATE_FILE" >/dev/null 2>&1; then
    mv -f "$WG_STATE_FILE" "$WG_STATE_FILE.corrupt"
    wg_state_write "$(wg_state_default)"
  fi
  cat "$WG_STATE_FILE"
}

wg_state_write() {
  local json="$1" tmp
  mkdir -p "$WG_STATE_DIR"
  tmp="$(mktemp "$WG_STATE_DIR/.state.XXXXXX")"
  printf '%s\n' "$json" >"$tmp"
  mv -f "$tmp" "$WG_STATE_FILE"
}

wg_state_group_names() {
  local state="${1:-$(wg_state_read)}"
  jq -r '.groups[].name' <<<"$state"
}

wg_state_group_field() {
  local name="$1" field="$2" state="${3:-$(wg_state_read)}"
  jq -r --arg n "$name" --arg f "$field" \
    'first(.groups[] | select(.name == $n) | .[$f]) // empty' <<<"$state"
}

wg_state_prune_overrides() {
  local state="${1:-$(wg_state_read)}" live
  live="$(jq -R -s 'split("\n") | map(select(length > 0))')"
  jq --argjson live "$live" \
    '.overrides |= with_entries(select(.key as $k | $live | index($k)))' <<<"$state"
}
```

Note on the corrupt path: `state.json.corrupt` is written before the default is seeded, so a second corruption overwrites the previous copy rather than accumulating files. That is deliberate — the most recent bad state is the useful one.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/state.bats && bats test/shellcheck.bats`
Expected: PASS, 8 + 2 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/state.sh test/state.bats
git commit -m "feat: add state file with atomic writes and corrupt-file recovery"
```

---

### Task 3: Resolution library

The heart of the project. Everything else reads its answers from here.

**Files:**
- Create: `lib/resolve.sh`
- Test: `test/resolve.bats`

**Interfaces:**
- Consumes: `wg_hypr_query` (Task 1); `wg_state_read` (Task 2). `lib/hypr.sh` and `lib/state.sh` must be sourced first.
- Produces:
  - `wg_window_cwd <pid>` → working directory of the window's shell, or empty
  - `wg_cwd_project <cwd>` → project directory name, or empty
  - `wg_cwd_worktree <cwd>` → worktree name, or empty
  - `wg_project_group <project> [state]` → group name, or empty
  - `wg_window_group <address> <project> [state]` → group name, or empty (override wins over project)
  - `wg_title_status <title>` → `idle` | `busy` | `plain`
  - `wg_title_text <title>` → title with the leading status glyph and its space removed
  - `wg_window_table [clients_json]` → one TSV row per window:
    `address · pid · workspace · floating · group · status · project · worktree · title`
  - `wg_window_row <address> [clients_json]` → the single TSV row for one address, or empty

- [ ] **Step 1: Write the failing tests**

`test/resolve.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  source "$WG_ROOT/lib/hypr.sh"
  source "$WG_ROOT/lib/state.sh"
  source "$WG_ROOT/lib/resolve.sh"
  wg_stub_cwd
  wg_seed_state
}

teardown() { wg_teardown_tmp; }

@test "wg_cwd_project reads a plain project directory" {
  run wg_cwd_project /home/dev/projects/shop-web
  [ "$output" = "shop-web" ]
}

@test "wg_cwd_project reads a subdirectory of a project" {
  run wg_cwd_project /home/dev/projects/shop-web/src/lib
  [ "$output" = "shop-web" ]
}

@test "wg_cwd_project collapses a claude worktree to its repo" {
  run wg_cwd_project /home/dev/projects/site-platform/.claude/worktrees/spec-draft
  [ "$output" = "site-platform" ]
}

@test "wg_cwd_project returns empty for home, for the projects dir itself, and for outside paths" {
  run wg_cwd_project /home/dev
  [ "$output" = "" ]
  run wg_cwd_project /home/dev/projects
  [ "$output" = "" ]
  run wg_cwd_project /etc
  [ "$output" = "" ]
  run wg_cwd_project ""
  [ "$output" = "" ]
}

@test "wg_cwd_worktree extracts the worktree name only when there is one" {
  run wg_cwd_worktree /home/dev/projects/site-platform/.claude/worktrees/spec-draft
  [ "$output" = "spec-draft" ]
  run wg_cwd_worktree /home/dev/projects/site-platform/.claude/worktrees/spec-draft/src
  [ "$output" = "spec-draft" ]
  run wg_cwd_worktree /home/dev/projects/shop-web
  [ "$output" = "" ]
}

@test "wg_project_group maps every project of a multi-project group" {
  run wg_project_group shop-web
  [ "$output" = "shop" ]
  run wg_project_group shop-core
  [ "$output" = "shop" ]
  run wg_project_group shop-api
  [ "$output" = "shop" ]
  run wg_project_group site-platform
  [ "$output" = "site" ]
}

@test "wg_project_group returns empty for an unmapped project" {
  run wg_project_group some-other-repo
  [ "$output" = "" ]
}

@test "wg_window_group prefers an override over project resolution" {
  run wg_window_group 0xaaa3 shop-api
  [ "$output" = "site" ]
}

@test "wg_window_group falls back to the project when there is no override" {
  run wg_window_group 0xaaa1 shop-web
  [ "$output" = "shop" ]
}

@test "wg_window_group returns empty with no override and no project" {
  run wg_window_group 0xaaa6 ""
  [ "$output" = "" ]
}

@test "wg_title_status classifies every known glyph" {
  run wg_title_status "✳ Everest-web full redesign"
  [ "$output" = "idle" ]
  run wg_title_status "◐ CMS preview 503 error"
  [ "$output" = "busy" ]
  run wg_title_status "◑ Sentry errors review"
  [ "$output" = "busy" ]
}

@test "wg_title_status degrades unknown and absent glyphs to plain" {
  run wg_title_status "dev@host:~"
  [ "$output" = "plain" ]
  run wg_title_status "⏳ some future glyph"
  [ "$output" = "plain" ]
  run wg_title_status ""
  [ "$output" = "plain" ]
}

@test "wg_title_text strips the status glyph but leaves plain titles alone" {
  run wg_title_text "✳ Everest-web full redesign"
  [ "$output" = "Everest-web full redesign" ]
  run wg_title_text "dev@host:~"
  [ "$output" = "dev@host:~" ]
}

@test "wg_window_table emits one row per window" {
  run bash -c "wg_window_table | wc -l"
  [ "$output" -eq 7 ]
}

@test "wg_window_table resolves a worktree window" {
  run bash -c "wg_window_table | awk -F'\t' '\$1==\"0xaaa2\"{print \$5, \$6, \$7, \$8}'"
  [ "$output" = "shop busy shop-core price-units" ]
}

@test "wg_window_table honours an override" {
  run bash -c "wg_window_table | awk -F'\t' '\$1==\"0xaaa3\"{print \$5, \$7}'"
  [ "$output" = "site shop-api" ]
}

@test "wg_window_table leaves a projectless window ungrouped" {
  run bash -c "wg_window_table | awk -F'\t' '\$1==\"0xaaa6\"{print \"[\" \$5 \"]\" \$6}'"
  [ "$output" = "[]plain" ]
}

@test "wg_window_table marks the floating window" {
  run bash -c "wg_window_table | awk -F'\t' '\$1==\"0xaaa7\"{print \$4}'"
  [ "$output" = "true" ]
}

@test "wg_window_row returns exactly one row, or nothing for an unknown address" {
  run bash -c "wg_window_row 0xaaa1 | wc -l"
  [ "$output" -eq 1 ]
  run bash -c "wg_window_row 0xdead | wc -c"
  [ "$output" -eq 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/resolve.bats`
Expected: FAIL — `lib/resolve.sh: No such file or directory`.

- [ ] **Step 3: Write the implementation**

`lib/resolve.sh`:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/`
Expected: PASS — all tests including shellcheck.

- [ ] **Step 5: Commit**

```bash
git add lib/resolve.sh test/resolve.bats
git commit -m "feat: resolve windows to projects, groups and Claude session status"
```

---

### Task 4: Waybar slot module

**Files:**
- Create: `bin/wingroup-waybar`
- Create: `test/fixtures/state-many.json`
- Test: `test/waybar.bats`

**Interfaces:**
- Consumes: `wg_window_table`, `wg_state_group_names`, `wg_state_group_field`, `wg_hypr_query`.
- Produces: the executable `wingroup-waybar <slot>`, printing one line of waybar JSON with keys `text`, `tooltip`, `class`. Also `wg_superscript <n>`, defined in the script.

Slot semantics: slot *n* renders the *n*-th group in state order. A slot with no group prints `{"text":"","tooltip":"","class":""}`, and waybar hides a custom module whose text is empty. Slot 7 additionally lists any groups past the eighth in its tooltip.

- [ ] **Step 1: Write the overflow fixture**

`test/fixtures/state-many.json` — ten groups, so slot 7 has two to overflow.

```json
{
  "auto": true,
  "catchall": null,
  "groups": [
    {"name":"g0","label":"g0","projects":[],"monitor":null},
    {"name":"g1","label":"g1","projects":[],"monitor":null},
    {"name":"g2","label":"g2","projects":[],"monitor":null},
    {"name":"g3","label":"g3","projects":[],"monitor":null},
    {"name":"g4","label":"g4","projects":[],"monitor":null},
    {"name":"g5","label":"g5","projects":[],"monitor":null},
    {"name":"g6","label":"g6","projects":[],"monitor":null},
    {"name":"g7","label":"g7","projects":[],"monitor":null},
    {"name":"g8","label":"g8","projects":[],"monitor":null},
    {"name":"g9","label":"g9","projects":[],"monitor":null}
  ],
  "overrides": {}
}
```

- [ ] **Step 2: Write the failing tests**

`test/waybar.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  export WG_TEST_STUB_CWD=1
}

teardown() { wg_teardown_tmp; }

@test "slot 0 renders the first group with its busy count as a superscript" {
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' <<<"$output")" = "shop¹" ]
}

@test "slot 1 renders the second group" {
  run "$WG_ROOT/bin/wingroup-waybar" 1
  [ "$(jq -r '.text' <<<"$output")" = "plat²" ]
}

@test "a group with no busy windows gets no superscript" {
  run "$WG_ROOT/bin/wingroup-waybar" 2
  [ "$(jq -r '.text' <<<"$output")" = "fleet" ]
  [ "$(jq -r '.class' <<<"$output")" = "" ]
}

@test "an empty slot renders empty text so waybar hides it" {
  run "$WG_ROOT/bin/wingroup-waybar" 5
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' <<<"$output")" = "" ]
}

@test "a group with busy windows gets the busy class" {
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "busy" ]
}

@test "the focused group gets the active class, which beats busy" {
  export WG_FIXTURE_ACTIVEWS="$WG_FIXTURES/activeworkspace-shop.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "active" ]
}

@test "the tooltip reports counts and the group's projects" {
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"2 windows, 1 busy"* ]]
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"shop-web, shop-core, shop-api"* ]]
}

@test "slot 7 lists overflow groups in its tooltip" {
  cp "$WG_FIXTURES/state-many.json" "$WG_STATE_DIR/state.json"
  run "$WG_ROOT/bin/wingroup-waybar" 7
  [ "$(jq -r '.text' <<<"$output")" = "g7" ]
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"2 more: g8, g9"* ]]
}

@test "slot 7 has no overflow line when there are exactly eight groups or fewer" {
  run "$WG_ROOT/bin/wingroup-waybar" 7
  [[ "$(jq -r '.tooltip' <<<"$output")" != *"more:"* ]]
}

@test "the module output is valid JSON even when the state file is corrupt" {
  printf 'garbage' >"$WG_STATE_DIR/state.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  run bash -c "'$WG_ROOT/bin/wingroup-waybar' 0 | jq -e . >/dev/null"
  [ "$status" -eq 0 ]
}
```

The `WG_TEST_STUB_CWD` variable makes the executable use the fixture cwd map instead of `/proc`; without it the script would try to read real process directories. Wire it in the implementation step below.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats test/waybar.bats`
Expected: FAIL — `bin/wingroup-waybar: No such file or directory`.

- [ ] **Step 4: Write the implementation**

`bin/wingroup-waybar` (`chmod +x`):

```bash
#!/usr/bin/env bash
set -euo pipefail

WG_LIB_DIR="${WG_LIB_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)}"
# shellcheck source=../lib/hypr.sh
source "$WG_LIB_DIR/hypr.sh"
# shellcheck source=../lib/state.sh
source "$WG_LIB_DIR/state.sh"
# shellcheck source=../lib/resolve.sh
source "$WG_LIB_DIR/resolve.sh"

# Tests replace /proc lookups with a fixture map.
if [[ -n ${WG_TEST_STUB_CWD:-} ]]; then
  wg_window_cwd() {
    local pid="$1" p c
    while IFS=$'\t' read -r p c; do
      [[ $p == "$pid" ]] && { printf '%s\n' "$c"; return 0; }
    done <"$WG_FIXTURES/cwd.map"
    return 0
  }
fi

WG_SLOTS=8

wg_superscript() {
  local n="$1" out="" i
  local sup=("⁰" "¹" "²" "³" "⁴" "⁵" "⁶" "⁷" "⁸" "⁹")
  [[ $n =~ ^[0-9]+$ ]] || return 0
  (( n > 0 )) || return 0
  for (( i = 0; i < ${#n}; i++ )); do
    out+="${sup[${n:i:1}]}"
  done
  printf '%s\n' "$out"
}

wg_emit() {
  jq -cn --arg text "$1" --arg tooltip "$2" --arg class "$3" \
    '{text: $text, tooltip: $tooltip, class: $class}'
}

main() {
  local slot="${1:?usage: wingroup-waybar <slot>}"
  local state name label projects active
  local -a names=()

  state="$(wg_state_read)"
  mapfile -t names < <(wg_state_group_names "$state")

  if (( slot >= ${#names[@]} )); then
    wg_emit "" "" ""
    return 0
  fi

  name="${names[slot]}"
  label="$(wg_state_group_field "$name" label "$state")"
  [[ -n $label ]] || label="$name"

  local total=0 busy=0 group status
  while IFS=$'\t' read -r group status; do
    [[ $group == "$name" ]] || continue
    (( total++ ))
    [[ $status == busy ]] && (( busy++ ))
  done < <(wg_window_table | cut -f5,6)

  active="$(wg_hypr_query activeworkspace | jq -r '.name')"

  local class=""
  if [[ $active == "$name" ]]; then
    class="active"
  elif (( busy > 0 )); then
    class="busy"
  fi

  projects="$(jq -r --arg n "$name" \
    'first(.groups[] | select(.name == $n) | .projects) | join(", ")' <<<"$state")"

  local tooltip
  tooltip="$(printf '%s — %d windows, %d busy' "$label" "$total" "$busy")"
  [[ -n $projects ]] && tooltip+=$'\n'"Projects: $projects"

  if (( slot == WG_SLOTS - 1 && ${#names[@]} > WG_SLOTS )); then
    local -a overflow=("${names[@]:WG_SLOTS}")
    tooltip+=$'\n'"$(printf '%d more: %s' "${#overflow[@]}" "$(IFS=', '; printf '%s' "${overflow[*]}")")"
  fi

  wg_emit "$label$(wg_superscript "$busy")" "$tooltip" "$class"
}

main "$@"
```

Note the `IFS=', '` subshell trick joins the overflow names with `", "`; `IFS` only takes its first character for `${array[*]}`, so this produces `g8,g9`. Use an explicit join instead:

```bash
  if (( slot == WG_SLOTS - 1 && ${#names[@]} > WG_SLOTS )); then
    local -a overflow=("${names[@]:WG_SLOTS}")
    local joined
    joined="$(printf '%s, ' "${overflow[@]}")"
    tooltip+=$'\n'"${#overflow[@]} more: ${joined%, }"
  fi
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats test/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/wingroup-waybar test/waybar.bats test/fixtures/state-many.json
git commit -m "feat: add waybar slot module for the group strip"
```

---

### Task 5: Event daemon

**Files:**
- Create: `bin/wingroup-daemon`
- Create: `test/bin/refresh-stub`
- Test: `test/daemon.bats`

**Interfaces:**
- Consumes: `wg_window_row`, `wg_state_read`, `wg_hypr_dispatch`.
- Produces: the executable `wingroup-daemon`, plus these functions available when sourced with `WG_DAEMON_NO_MAIN=1`:
  - `wg_daemon_handle_line <line>` — process one event socket line
  - `wg_daemon_request_refresh` — debounced bar refresh
  - `wg_now_ms` — milliseconds since the epoch

- [ ] **Step 1: Write the refresh stub**

`test/bin/refresh-stub` (`chmod +x`):

```bash
#!/usr/bin/env bash
printf 'refresh\n' >>"$WG_REFRESH_LOG"
```

- [ ] **Step 2: Write the failing tests**

`test/daemon.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  export WG_REFRESH_LOG="$WG_TMP/refresh.log"
  : >"$WG_REFRESH_LOG"
  export WG_REFRESH_CMD="$WG_ROOT/test/bin/refresh-stub"
  export WG_RESOLVE_RETRIES=1
  export WG_RESOLVE_DELAY=0
  export WG_DAEMON_NO_MAIN=1
  source "$WG_ROOT/bin/wingroup-daemon"
  wg_stub_cwd
}

teardown() { wg_teardown_tmp; }

feed() {
  local line
  while IFS= read -r line; do
    wg_daemon_handle_line "$line"
  done <"$1"
}

@test "a project window is moved to its group exactly once" {
  export WG_REFRESH_DEBOUNCE_MS=5000
  feed "$WG_FIXTURES/events.txt"
  run bash -c "grep -c 'movetoworkspacesilent name:shop,address:0xaaa1' '$WG_DISPATCH_LOG'"
  [ "$output" -eq 1 ]
}

@test "no other window is moved" {
  export WG_REFRESH_DEBOUNCE_MS=5000
  feed "$WG_FIXTURES/events.txt"
  run bash -c "wc -l <'$WG_DISPATCH_LOG'"
  [ "$output" -eq 1 ]
}

@test "a floating window is never moved" {
  wg_daemon_handle_line "openwindow>>aaa7,1,org.gnome.Nautilus,Home"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "a window with no project is left alone under the default catchall" {
  wg_daemon_handle_line "openwindow>>aaa6,1,Alacritty,dev@host:~"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "auto=false disables all moves" {
  wg_state_write "$(jq '.auto = false' "$WG_STATE_DIR/state.json")"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "a window already on its group workspace is not moved again" {
  wg_state_write "$(jq '.groups[0].name = "1" | .groups[0].label = "one"' "$WG_STATE_DIR/state.json")"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "a burst of title events collapses to one refresh" {
  export WG_REFRESH_DEBOUNCE_MS=5000
  wg_daemon_handle_line "windowtitle>>aaa1"
  wg_daemon_handle_line "windowtitle>>aaa2"
  wg_daemon_handle_line "windowtitle>>aaa3"
  run bash -c "wc -l <'$WG_REFRESH_LOG'"
  [ "$output" -eq 1 ]
}

@test "with debouncing off every title event refreshes" {
  export WG_REFRESH_DEBOUNCE_MS=0
  wg_daemon_handle_line "windowtitle>>aaa1"
  wg_daemon_handle_line "windowtitle>>aaa2"
  wg_daemon_handle_line "windowtitle>>aaa3"
  run bash -c "wc -l <'$WG_REFRESH_LOG'"
  [ "$output" -eq 3 ]
}

@test "an unrecognised event line is ignored without error" {
  run wg_daemon_handle_line "somefutureevent>>whatever,1,2,3"
  [ "$status" -eq 0 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "closewindow prunes the override for that window" {
  wg_daemon_handle_line "closewindow>>aaa3"
  run bash -c "jq -r '.overrides[\"0xaaa3\"] // \"gone\"' '$WG_STATE_DIR/state.json'"
  [ "$output" = "gone" ]
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats test/daemon.bats`
Expected: FAIL — `bin/wingroup-daemon: No such file or directory`.

- [ ] **Step 4: Write the implementation**

`bin/wingroup-daemon` (`chmod +x`):

```bash
#!/usr/bin/env bash
set -euo pipefail

WG_LIB_DIR="${WG_LIB_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)}"
# shellcheck source=../lib/hypr.sh
source "$WG_LIB_DIR/hypr.sh"
# shellcheck source=../lib/state.sh
source "$WG_LIB_DIR/state.sh"
# shellcheck source=../lib/resolve.sh
source "$WG_LIB_DIR/resolve.sh"

: "${WG_RESOLVE_RETRIES:=10}"
: "${WG_RESOLVE_DELAY:=0.1}"
: "${WG_REFRESH_DEBOUNCE_MS:=150}"

declare -A WG_SEEN=()
WG_LAST_REFRESH_MS=0

wg_now_ms() {
  local t="${EPOCHREALTIME/,/.}"
  printf '%s\n' "$(( ${t%.*} * 1000 + 10#${t#*.} / 1000 ))"
}

wg_refresh_bar() {
  if [[ -n ${WG_REFRESH_CMD:-} ]]; then
    "$WG_REFRESH_CMD"
  else
    pkill -RTMIN+11 waybar || true
  fi
}

wg_daemon_request_refresh() {
  local now
  now="$(wg_now_ms)"
  if (( now - WG_LAST_REFRESH_MS < WG_REFRESH_DEBOUNCE_MS )); then
    return 0
  fi
  WG_LAST_REFRESH_MS="$now"
  wg_refresh_bar
}

# The compositor announces a window before its shell has spawned, so cwd
# resolution has to be retried for a moment before giving up.
wg_daemon_resolve_group() {
  local address="$1" attempt=0 row group
  while (( attempt < WG_RESOLVE_RETRIES )); do
    row="$(wg_window_row "$address")"
    if [[ -n $row ]]; then
      group="$(cut -f5 <<<"$row")"
      [[ -n $group ]] && { printf '%s\n' "$group"; return 0; }
    fi
    (( ++attempt < WG_RESOLVE_RETRIES )) || break
    [[ $WG_RESOLVE_DELAY == 0 ]] || sleep "$WG_RESOLVE_DELAY"
  done
  return 0
}

wg_daemon_open_window() {
  local address="$1" state row floating workspace group catchall

  state="$(wg_state_read)"
  [[ "$(jq -r '.auto' <<<"$state")" == "true" ]] || return 0
  [[ -z ${WG_SEEN[$address]:-} ]] || return 0
  WG_SEEN[$address]=1

  row="$(wg_window_row "$address")"
  [[ -n $row ]] || return 0
  floating="$(cut -f4 <<<"$row")"
  [[ $floating == "true" ]] && return 0
  workspace="$(cut -f3 <<<"$row")"

  group="$(wg_daemon_resolve_group "$address")"
  if [[ -z $group ]]; then
    catchall="$(jq -r '.catchall // empty' <<<"$state")"
    [[ -n $catchall ]] || return 0
    group="$catchall"
  fi

  [[ $workspace == "$group" ]] && return 0
  wg_hypr_dispatch movetoworkspacesilent "name:$group,address:$address"
  wg_daemon_request_refresh
}

wg_daemon_prune() {
  local live
  live="$(wg_hypr_query clients | jq -r '.[].address')"
  wg_state_write "$(printf '%s\n' "$live" | wg_state_prune_overrides)"
}

wg_daemon_handle_line() {
  local line="$1" event payload address
  event="${line%%>>*}"
  payload="${line#*>>}"

  case $event in
    openwindow)
      address="0x${payload%%,*}"
      wg_daemon_open_window "$address"
      ;;
    closewindow)
      address="0x${payload}"
      unset "WG_SEEN[$address]"
      # Targeted deletion, not a prune: the closing window is still listed by
      # hyprctl at this instant, so a live-address prune would keep its override.
      wg_state_write "$(jq --arg a "$address" 'del(.overrides[$a])' <<<"$(wg_state_read)")"
      wg_daemon_request_refresh
      ;;
    windowtitle | windowtitlev2 | workspace | workspacev2 | activewindow | activewindowv2 | movewindow | movewindowv2)
      wg_daemon_request_refresh
      ;;
    *) : ;;
  esac
  return 0
}

wg_daemon_main() {
  local lock="${XDG_RUNTIME_DIR:-/tmp}/wingroup-daemon.lock"
  exec 9>"$lock"
  if ! flock -n 9; then
    printf 'wingroup-daemon: already running\n' >&2
    exit 0
  fi

  # Overrides belonging to windows from a previous session are dead weight.
  wg_daemon_prune

  local sock="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"
  [[ -S $sock ]] || { printf 'wingroup-daemon: no event socket at %s\n' "$sock" >&2; exit 1; }

  local line
  while IFS= read -r line; do
    wg_daemon_handle_line "$line" || true
  done < <(socat -U - "UNIX-CONNECT:$sock")
}

if [[ "${BASH_SOURCE[0]}" == "$0" && -z ${WG_DAEMON_NO_MAIN:-} ]]; then
  wg_daemon_main
fi
```

Note: `closewindow` payload is the bare address with no trailing fields, so `0x${payload}` is correct there, while `openwindow` payload is comma-separated and needs `${payload%%,*}`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats test/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/wingroup-daemon test/daemon.bats test/bin/refresh-stub
git commit -m "feat: add event daemon that files new windows into their group"
```

---

### Task 6: Picker line building

The picker is split in two: this task builds the lines and the action they map to (pure, fully testable), and Task 7 wires them to walker and to the compositor.

**Files:**
- Create: `lib/menu.sh`
- Create: `test/bin/walker-stub`
- Test: `test/menu.bats`

**Interfaces:**
- Consumes: `wg_window_table`, `wg_state_group_names`, `wg_state_group_field`, `wg_title_text`, `wg_title_status`.
- Produces:
  - `wg_menu_build [state]` → TSV, one line per entry: `action<TAB>display`
  - `wg_group_menu_build [state]` → TSV of just the group entries plus `new`, for "send window to group"
  - `wg_menu_run <prompt>` → reads TSV on stdin, shows walker, prints the chosen action (empty if cancelled)

Action vocabulary: `group:<name>`, `window:<address>`, `new`, `tidy`, `toggle-auto`, `noop`.

- [ ] **Step 1: Write the walker stub**

`test/bin/walker-stub` (`chmod +x`). Walker in `-i` mode prints the index of the chosen line; the stub prints whatever index the test asks for, and consumes stdin so the pipeline does not break.

```bash
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "${WG_WALKER_PICK:-}"
```

- [ ] **Step 2: Write the failing tests**

`test/menu.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  source "$WG_ROOT/lib/hypr.sh"
  source "$WG_ROOT/lib/state.sh"
  source "$WG_ROOT/lib/resolve.sh"
  source "$WG_ROOT/lib/menu.sh"
  wg_stub_cwd
  export WG_WALKER="$WG_ROOT/test/bin/walker-stub"
}

teardown() { wg_teardown_tmp; }

@test "the menu opens with one entry per group, in state order" {
  run bash -c "wg_menu_build | grep -c '^group:'"
  [ "$output" -eq 3 ]
  run bash -c "wg_menu_build | head -n1 | cut -f1"
  [ "$output" = "group:shop" ]
}

@test "a group entry shows its window and busy counts" {
  run bash -c "wg_menu_build | head -n1 | cut -f2"
  [[ "$output" == *"shop"* ]]
  [[ "$output" == *"2 windows"* ]]
  [[ "$output" == *"1 busy"* ]]
}

@test "the menu lists every window" {
  run bash -c "wg_menu_build | grep -c '^window:'"
  [ "$output" -eq 7 ]
}

@test "a window entry uses the stripped title and names its group" {
  run bash -c "wg_menu_build | grep '^window:0xaaa1' | cut -f2"
  [[ "$output" == *"Everest-web full redesign"* ]]
  [[ "$output" != *"✳ ✳"* ]]
  [[ "$output" == *"shop"* ]]
}

@test "an ungrouped window says so" {
  run bash -c "wg_menu_build | grep '^window:0xaaa6' | cut -f2"
  [[ "$output" == *"ungrouped"* ]]
}

@test "the menu ends with the three action entries" {
  run bash -c "wg_menu_build | tail -n3 | cut -f1 | tr '\n' ' '"
  [ "$output" = "new tidy toggle-auto " ]
}

@test "the auto entry reflects the current setting" {
  run bash -c "wg_menu_build | grep '^toggle-auto' | cut -f2"
  [[ "$output" == *"on"* ]]
  wg_state_write "$(jq '.auto = false' "$WG_STATE_DIR/state.json")"
  run bash -c "wg_menu_build | grep '^toggle-auto' | cut -f2"
  [[ "$output" == *"off"* ]]
}

@test "wg_group_menu_build offers only groups and a way to make a new one" {
  run bash -c "wg_group_menu_build | cut -f1 | tr '\n' ' '"
  [ "$output" = "group:shop group:site group:fleet new " ]
}

@test "wg_menu_run returns the action at the index walker chose" {
  export WG_WALKER_PICK=1
  run bash -c "wg_group_menu_build | wg_menu_run 'Group'"
  [ "$output" = "group:site" ]
}

@test "wg_menu_run returns nothing when walker is cancelled" {
  export WG_WALKER_PICK=""
  run bash -c "wg_group_menu_build | wg_menu_run 'Group'"
  [ "$output" = "" ]
}

@test "wg_menu_run ignores an out-of-range index" {
  export WG_WALKER_PICK=99
  run bash -c "wg_group_menu_build | wg_menu_run 'Group'"
  [ "$output" = "" ]
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats test/menu.bats`
Expected: FAIL — `lib/menu.sh: No such file or directory`.

- [ ] **Step 4: Write the implementation**

`lib/menu.sh`:

```bash
# shellcheck shell=bash
# Requires lib/hypr.sh, lib/state.sh and lib/resolve.sh to be sourced first.

: "${WG_WALKER:=walker}"

wg_status_glyph() {
  case $1 in
    idle) printf '✳\n' ;;
    busy) printf '◐\n' ;;
    *)    printf '·\n' ;;
  esac
}

wg_menu_build() {
  local state="${1:-$(wg_state_read)}" table
  table="$(wg_window_table)"

  local name label total busy
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    label="$(wg_state_group_field "$name" label "$state")"
    [[ -n $label ]] || label="$name"
    total="$(awk -F'\t' -v g="$name" '$5 == g' <<<"$table" | wc -l)"
    busy="$(awk -F'\t' -v g="$name" '$5 == g && $6 == "busy"' <<<"$table" | wc -l)"
    printf 'group:%s\t▸ %-18s %d windows, %d busy\n' "$name" "$label" "$total" "$busy"
  done < <(wg_state_group_names "$state")

  printf 'noop\t%s\n' "──────────────────────────────"

  local address group status title glyph shown where
  while IFS=$'\t' read -r address _ _ _ group status _ _ title; do
    glyph="$(wg_status_glyph "$status")"
    shown="$(wg_title_text "$title")"
    where="${group:-ungrouped}"
    printf 'window:%s\t  %s %-44s %s\n' "$address" "$glyph" "$shown" "$where"
  done <<<"$table"

  local auto
  auto="$(jq -r 'if .auto then "on" else "off" end' <<<"$state")"
  printf 'new\t%s\n' "+ new group…"
  printf 'tidy\t%s\n' "⟳ tidy — file every window by its project"
  printf 'toggle-auto\t%s\n' "⏻ auto-assign: $auto"
}

wg_group_menu_build() {
  local state="${1:-$(wg_state_read)}" name label
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    label="$(wg_state_group_field "$name" label "$state")"
    [[ -n $label ]] || label="$name"
    printf 'group:%s\t%s\n' "$name" "$label"
  done < <(wg_state_group_names "$state")
  printf 'new\t%s\n' "+ new group…"
}

# Reads action<TAB>display on stdin, shows walker, prints the chosen action.
wg_menu_run() {
  local prompt="${1:-}" index
  local -a actions=() displays=()
  local action display

  while IFS=$'\t' read -r action display; do
    actions+=("$action")
    displays+=("$display")
  done

  index="$(printf '%s\n' "${displays[@]}" | "$WG_WALKER" -d -i -p "$prompt" || true)"
  [[ $index =~ ^[0-9]+$ ]] || return 0
  (( index < ${#actions[@]} )) || return 0
  [[ ${actions[index]} == noop ]] && return 0
  printf '%s\n' "${actions[index]}"
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats test/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/menu.sh test/menu.bats test/bin/walker-stub
git commit -m "feat: build picker entries for groups, windows and actions"
```

---

### Task 7: The `wingroup` command

**Files:**
- Create: `bin/wingroup`
- Test: `test/cli.bats`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: the executable `wingroup` with subcommands `menu`, `send`, `activate`, `next`, `prev`, `tidy`, `new`, `rename`, `dissolve`, `toggle-auto`, and the helper `wg_slug <label>`.

Non-interactive flags exist so the CLI is testable without walker: `send --address ADDR --group NAME`, `tidy --yes`.

- [ ] **Step 1: Write the failing tests**

`test/cli.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  export WG_TEST_STUB_CWD=1
  export WG_WALKER="$WG_ROOT/test/bin/walker-stub"
}

teardown() { wg_teardown_tmp; }

wingroup() { "$WG_ROOT/bin/wingroup" "$@"; }

@test "activate by name switches to the group workspace" {
  wingroup activate shop
  [ "$(dispatches)" = "workspace name:shop" ]
}

@test "activate by slot index switches to that group" {
  wingroup activate 1
  [ "$(dispatches)" = "workspace name:site" ]
}

@test "activate rejects an unknown group without dispatching" {
  run wingroup activate nosuch
  [ "$status" -ne 0 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "next moves to the first group when the focus is not on a group" {
  wingroup next
  [ "$(dispatches)" = "workspace name:shop" ]
}

@test "next advances from the focused group" {
  export WG_FIXTURE_ACTIVEWS="$WG_FIXTURES/activeworkspace-shop.json"
  wingroup next
  [ "$(dispatches)" = "workspace name:site" ]
}

@test "prev wraps around from the first group to the last" {
  export WG_FIXTURE_ACTIVEWS="$WG_FIXTURES/activeworkspace-shop.json"
  wingroup prev
  [ "$(dispatches)" = "workspace name:fleet" ]
}

@test "new creates a group with a slugified name and the given projects" {
  wingroup new "Niro 3D Print" acme-3d-app acme-3d-web
  run bash -c "jq -r '.groups[-1].name' '$WG_STATE_DIR/state.json'"
  [ "$output" = "niro-3d-print" ]
  run bash -c "jq -r '.groups[-1].label' '$WG_STATE_DIR/state.json'"
  [ "$output" = "Niro 3D Print" ]
  run bash -c "jq -r '.groups[-1].projects | join(\",\")' '$WG_STATE_DIR/state.json'"
  [ "$output" = "acme-3d-app,acme-3d-web" ]
}

@test "new refuses a duplicate group name" {
  run wingroup new shop
  [ "$status" -ne 0 ]
}

@test "rename changes the label and leaves the workspace name alone" {
  wingroup rename shop "EV stack"
  run bash -c "jq -r '.groups[0].label' '$WG_STATE_DIR/state.json'"
  [ "$output" = "EV stack" ]
  run bash -c "jq -r '.groups[0].name' '$WG_STATE_DIR/state.json'"
  [ "$output" = "shop" ]
}

@test "dissolve removes the group and never touches a window" {
  wingroup dissolve site
  run bash -c "jq -r '[.groups[].name] | join(\",\")' '$WG_STATE_DIR/state.json'"
  [ "$output" = "shop,fleet" ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "send writes an override and moves the window" {
  wingroup send --address 0xaaa1 --group site
  run bash -c "jq -r '.overrides[\"0xaaa1\"]' '$WG_STATE_DIR/state.json'"
  [ "$output" = "site" ]
  [ "$(dispatches)" = "movetoworkspacesilent name:site,address:0xaaa1" ]
}

@test "send refuses an unknown group" {
  run wingroup send --address 0xaaa1 --group nosuch
  [ "$status" -ne 0 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "tidy files every misplaced window and skips overrides, floats and strays" {
  wingroup tidy --yes
  run bash -c "wc -l <'$WG_DISPATCH_LOG'"
  [ "$output" -eq 4 ]
  run bash -c "grep -c '0xaaa3' '$WG_DISPATCH_LOG' || true"
  [ "$output" -eq 0 ]
  run bash -c "grep -c '0xaaa7' '$WG_DISPATCH_LOG' || true"
  [ "$output" -eq 0 ]
}

@test "tidy without --yes dispatches nothing when the confirmation is cancelled" {
  export WG_WALKER_PICK=""
  wingroup tidy
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "toggle-auto flips the setting" {
  wingroup toggle-auto
  run bash -c "jq -r '.auto' '$WG_STATE_DIR/state.json'"
  [ "$output" = "false" ]
  wingroup toggle-auto
  run bash -c "jq -r '.auto' '$WG_STATE_DIR/state.json'"
  [ "$output" = "true" ]
}

@test "menu activates the group the picker returned" {
  export WG_WALKER_PICK=1
  wingroup menu
  [ "$(dispatches)" = "workspace name:site" ]
}

@test "menu focuses the window the picker returned" {
  export WG_WALKER_PICK=5
  wingroup menu
  [[ "$(dispatches)" == focuswindow* ]]
}

@test "an unknown subcommand exits non-zero with usage" {
  run wingroup wat
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}
```

Index 5 in the second menu test lands on a window entry: three group lines occupy 0–2, the separator is 3, and window entries start at 4.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/cli.bats`
Expected: FAIL — `bin/wingroup: No such file or directory`.

- [ ] **Step 3: Write the implementation**

`bin/wingroup` (`chmod +x`):

```bash
#!/usr/bin/env bash
set -euo pipefail

WG_LIB_DIR="${WG_LIB_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)}"
# shellcheck source=../lib/hypr.sh
source "$WG_LIB_DIR/hypr.sh"
# shellcheck source=../lib/state.sh
source "$WG_LIB_DIR/state.sh"
# shellcheck source=../lib/resolve.sh
source "$WG_LIB_DIR/resolve.sh"
# shellcheck source=../lib/menu.sh
source "$WG_LIB_DIR/menu.sh"

if [[ -n ${WG_TEST_STUB_CWD:-} ]]; then
  wg_window_cwd() {
    local pid="$1" p c
    while IFS=$'\t' read -r p c; do
      [[ $p == "$pid" ]] && { printf '%s\n' "$c"; return 0; }
    done <"$WG_FIXTURES/cwd.map"
    return 0
  }
fi

wg_die() { printf 'wingroup: %s\n' "$1" >&2; exit 1; }

wg_usage() {
  cat >&2 <<'USAGE'
usage: wingroup <command>

  menu                          open the group and window picker
  send [--address A --group G]  send a window to a group
  activate <slot|name>          switch to a group
  next | prev                   cycle through groups
  tidy [--yes]                  file every window by its project
  new <label> [project...]      create a group
  rename <name> <label>         change a group's displayed label
  dissolve <name>               remove a group, leaving its windows alone
  toggle-auto                   turn automatic assignment on or off
USAGE
  exit 1
}

wg_slug() {
  local s="$1"
  s="${s,,}"
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s\n' "$s"
}

wg_group_exists() {
  local name="$1" state="${2:-$(wg_state_read)}"
  [[ -n "$(jq -r --arg n "$name" 'first(.groups[] | select(.name == $n) | .name) // empty' <<<"$state")" ]]
}

wg_refresh() {
  [[ -n ${WG_REFRESH_CMD:-} ]] && { "$WG_REFRESH_CMD"; return 0; }
  pkill -RTMIN+11 waybar || true
}

cmd_activate() {
  local target="${1:?}" state
  local -a names=()
  state="$(wg_state_read)"
  mapfile -t names < <(wg_state_group_names "$state")

  if [[ $target =~ ^[0-9]+$ ]] && (( target < ${#names[@]} )); then
    target="${names[target]}"
  fi
  wg_group_exists "$target" "$state" || wg_die "no such group: $target"
  wg_hypr_dispatch workspace "name:$target"
}

cmd_cycle() {
  local direction="$1" active index=-1 i
  local -a names=()
  mapfile -t names < <(wg_state_group_names)
  (( ${#names[@]} )) || wg_die "no groups defined"

  active="$(wg_hypr_query activeworkspace | jq -r '.name')"
  for (( i = 0; i < ${#names[@]}; i++ )); do
    [[ ${names[i]} == "$active" ]] && { index=$i; break; }
  done

  if (( index < 0 )); then
    (( index = direction == 1 ? -1 : 0 ))
  fi
  (( index = (index + direction + ${#names[@]}) % ${#names[@]} ))
  wg_hypr_dispatch workspace "name:${names[index]}"
}

cmd_new() {
  local label="${1:?usage: wingroup new <label> [project...]}"; shift
  local state name projects
  state="$(wg_state_read)"
  name="$(wg_slug "$label")"
  [[ -n $name ]] || wg_die "label produces an empty group name"
  wg_group_exists "$name" "$state" && wg_die "group already exists: $name"
  projects="$(printf '%s\n' ${@+"$@"} | jq -R -s 'split("\n") | map(select(length > 0))')"
  wg_state_write "$(jq --arg n "$name" --arg l "$label" --argjson p "$projects" \
    '.groups += [{name: $n, label: $l, projects: $p, monitor: null}]' <<<"$state")"
  wg_refresh
}

cmd_rename() {
  local name="${1:?}" label="${2:?}" state
  state="$(wg_state_read)"
  wg_group_exists "$name" "$state" || wg_die "no such group: $name"
  wg_state_write "$(jq --arg n "$name" --arg l "$label" \
    '(.groups[] | select(.name == $n) | .label) = $l' <<<"$state")"
  wg_refresh
}

cmd_dissolve() {
  local name="${1:?}" state
  state="$(wg_state_read)"
  wg_group_exists "$name" "$state" || wg_die "no such group: $name"
  wg_state_write "$(jq --arg n "$name" \
    '.groups |= map(select(.name != $n)) | .overrides |= with_entries(select(.value != $n))' <<<"$state")"
  wg_refresh
}

cmd_send() {
  local address="" group="" state
  while (( $# )); do
    case $1 in
      --address) address="$2"; shift 2 ;;
      --group)   group="$2";   shift 2 ;;
      *) wg_usage ;;
    esac
  done

  [[ -n $address ]] || address="$(wg_hypr_query activewindow | jq -r '.address')"
  [[ -n $address && $address != null ]] || wg_die "no window to send"

  if [[ -z $group ]]; then
    local action
    action="$(wg_group_menu_build | wg_menu_run 'Send to group')"
    [[ -n $action ]] || return 0
    if [[ $action == new ]]; then
      wg_die "create the group first: wingroup new <label> [project...]"
    fi
    group="${action#group:}"
  fi

  state="$(wg_state_read)"
  wg_group_exists "$group" "$state" || wg_die "no such group: $group"
  wg_state_write "$(jq --arg a "$address" --arg g "$group" '.overrides[$a] = $g' <<<"$state")"
  wg_hypr_dispatch movetoworkspacesilent "name:$group,address:$address"
  wg_refresh
}

# Prints one "address<TAB>group" line per window that is on the wrong workspace.
wg_tidy_moves() {
  local state
  state="$(wg_state_read)"
  local address workspace floating group
  while IFS=$'\t' read -r address _ workspace floating group _ _ _ _; do
    [[ $floating == "true" ]] && continue
    [[ -n $group ]] || continue
    [[ $workspace == "$group" ]] && continue
    [[ "$(jq -r --arg a "$address" '.overrides[$a] // empty' <<<"$state")" == "" ]] || continue
    printf '%s\t%s\n' "$address" "$group"
  done < <(wg_window_table)
}

cmd_tidy() {
  local assume_yes=0 moves count address group
  [[ ${1:-} == --yes ]] && assume_yes=1
  moves="$(wg_tidy_moves)"
  [[ -n $moves ]] || return 0
  count="$(wc -l <<<"$moves")"

  if (( ! assume_yes )); then
    local action
    action="$(printf 'tidy\tApply %s move(s)\nnoop\tCancel\n' "$count" | wg_menu_run 'Tidy')"
    [[ $action == tidy ]] || return 0
  fi

  while IFS=$'\t' read -r address group; do
    wg_hypr_dispatch movetoworkspacesilent "name:$group,address:$address"
  done <<<"$moves"
  wg_refresh
}

cmd_toggle_auto() {
  local state
  state="$(wg_state_read)"
  wg_state_write "$(jq '.auto = (.auto | not)' <<<"$state")"
  wg_refresh
}

cmd_menu() {
  local action
  action="$(wg_menu_build | wg_menu_run 'Groups')"
  case $action in
    "")            return 0 ;;
    group:*)       cmd_activate "${action#group:}" ;;
    window:*)      wg_hypr_dispatch focuswindow "address:${action#window:}" ;;
    new)           wg_die "create a group from the terminal: wingroup new <label> [project...]" ;;
    tidy)          cmd_tidy ;;
    toggle-auto)   cmd_toggle_auto ;;
  esac
}

main() {
  local command="${1:-}"
  [[ -n $command ]] || wg_usage
  shift || true
  case $command in
    menu)        cmd_menu "$@" ;;
    send)        cmd_send "$@" ;;
    activate)    cmd_activate "$@" ;;
    next)        cmd_cycle 1 ;;
    prev)        cmd_cycle -1 ;;
    tidy)        cmd_tidy "$@" ;;
    new)         cmd_new "$@" ;;
    rename)      cmd_rename "$@" ;;
    dissolve)    cmd_dissolve "$@" ;;
    toggle-auto) cmd_toggle_auto ;;
    *)           wg_usage ;;
  esac
}

main "$@"
```

Tests must not signal the real waybar, so `test/helper.bash` gains one line in `wg_setup_tmp`:

```bash
  export WG_REFRESH_CMD="$WG_ROOT/test/bin/refresh-stub"
  export WG_REFRESH_LOG="$WG_TMP/refresh.log"
  : >"$WG_REFRESH_LOG"
```

and `test/daemon.bats` can then drop its own copies of those two exports.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/wingroup test/cli.bats test/helper.bash test/daemon.bats
git commit -m "feat: add the wingroup command with picker, tidy and group management"
```

---

### Task 8: Install and uninstall

**Files:**
- Create: `install.sh`
- Create: `uninstall.sh`
- Create: `test/fixtures/waybar-config.jsonc`
- Create: `test/fixtures/waybar-style.css`
- Test: `test/install.bats`

**Interfaces:**
- Consumes: the executables from Tasks 4, 5 and 7.
- Produces: `install.sh` and `uninstall.sh`, both idempotent, both parameterised by environment so tests never touch real config:
  `WG_BIN_DIR` (default `$HOME/.local/bin`), `WG_WAYBAR_CONFIG`, `WG_WAYBAR_STYLE`, `WG_HYPR_BINDINGS`, `WG_HYPR_AUTOSTART`.

Every edit is delimited by markers so uninstall is an exact reversal: `// >>> wingroup` … `// <<< wingroup` in JSONC and CSS, `# >>> wingroup` … `# <<< wingroup` in Hyprland config.

- [ ] **Step 1: Write the config fixtures**

`test/fixtures/waybar-config.jsonc` — a trimmed copy of the real config, keeping the comment and the exact `modules-left` shape:

```jsonc
{
  "reload_style_on_change": true,
  "layer": "top",
  "position": "top",
  "height": 26,
  "modules-left": ["custom/omarchy", "hyprland/workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["battery"],
  // Omarchy menu button
  "custom/omarchy": {
    "format": "",
    "on-click": "omarchy-menu"
  }
}
```

`test/fixtures/waybar-style.css`:

```css
* {
  font-family: monospace;
}
```

- [ ] **Step 2: Write the failing tests**

`test/install.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  export WG_BIN_DIR="$WG_TMP/bin"
  export WG_WAYBAR_CONFIG="$WG_TMP/config.jsonc"
  export WG_WAYBAR_STYLE="$WG_TMP/style.css"
  export WG_HYPR_BINDINGS="$WG_TMP/bindings.conf"
  export WG_HYPR_AUTOSTART="$WG_TMP/autostart.conf"
  cp "$WG_FIXTURES/waybar-config.jsonc" "$WG_WAYBAR_CONFIG"
  cp "$WG_FIXTURES/waybar-style.css" "$WG_WAYBAR_STYLE"
  printf '# my bindings\n' >"$WG_HYPR_BINDINGS"
  printf '# my autostart\n' >"$WG_HYPR_AUTOSTART"
  cp "$WG_WAYBAR_CONFIG" "$WG_TMP/config.orig"
  cp "$WG_WAYBAR_STYLE" "$WG_TMP/style.orig"
  cp "$WG_HYPR_BINDINGS" "$WG_TMP/bindings.orig"
  cp "$WG_HYPR_AUTOSTART" "$WG_TMP/autostart.orig"
}

teardown() { wg_teardown_tmp; }

@test "install links all three executables" {
  "$WG_ROOT/install.sh"
  [ -L "$WG_BIN_DIR/wingroup" ]
  [ -L "$WG_BIN_DIR/wingroup-daemon" ]
  [ -L "$WG_BIN_DIR/wingroup-waybar" ]
}

@test "install adds eight slots to modules-left and eight module definitions" {
  "$WG_ROOT/install.sh"
  run bash -c "grep -o 'custom/wingroup[0-9]' '$WG_WAYBAR_CONFIG' | sort -u | wc -l"
  [ "$output" -eq 8 ]
  run bash -c "grep -c '\"custom/wingroup[0-9]\": {' '$WG_WAYBAR_CONFIG'"
  [ "$output" -eq 8 ]
}

@test "the installed waybar config is still valid JSONC that waybar can read" {
  "$WG_ROOT/install.sh"
  run bash -c "sed 's|//.*||' '$WG_WAYBAR_CONFIG' | jq -e . >/dev/null"
  [ "$status" -eq 0 ]
}

@test "install uses signal 11, not one Omarchy already claims" {
  "$WG_ROOT/install.sh"
  run bash -c "grep -c '\"signal\": 11' '$WG_WAYBAR_CONFIG'"
  [ "$output" -eq 8 ]
  run bash -c "grep -cE '\"signal\": (7|8|9|10),' '$WG_WAYBAR_CONFIG' || true"
  [ "$output" -eq 0 ]
}

@test "install adds the keybinds and the daemon autostart" {
  "$WG_ROOT/install.sh"
  grep -q 'bindd = SUPER, G, Window groups, exec, wingroup menu' "$WG_HYPR_BINDINGS"
  grep -q 'unbind = SUPER, G' "$WG_HYPR_BINDINGS"
  grep -q 'exec-once = wingroup-daemon' "$WG_HYPR_AUTOSTART"
}

@test "install backs up every file it edits" {
  "$WG_ROOT/install.sh"
  run bash -c "ls $WG_TMP/config.jsonc.bak.* | wc -l"
  [ "$output" -eq 1 ]
}

@test "install is idempotent" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/install.sh"
  run bash -c "grep -o 'custom/wingroup0' '$WG_WAYBAR_CONFIG' | wc -l"
  [ "$output" -eq 2 ]
  run bash -c "grep -c 'exec-once = wingroup-daemon' '$WG_HYPR_AUTOSTART'"
  [ "$output" -eq 1 ]
  run bash -c "grep -c 'bindd = SUPER, G, Window groups' '$WG_HYPR_BINDINGS'"
  [ "$output" -eq 1 ]
}

@test "install seeds the state file only when it is absent" {
  "$WG_ROOT/install.sh"
  [ -f "$WG_STATE_DIR/state.json" ]
  wg_state_marker="$(jq -r '.auto' "$WG_STATE_DIR/state.json")"
  [ "$wg_state_marker" = "true" ]
  jq '.auto = false' "$WG_STATE_DIR/state.json" >"$WG_TMP/s" && mv "$WG_TMP/s" "$WG_STATE_DIR/state.json"
  "$WG_ROOT/install.sh"
  run bash -c "jq -r '.auto' '$WG_STATE_DIR/state.json'"
  [ "$output" = "false" ]
}

@test "uninstall restores every file byte for byte" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
  run diff "$WG_TMP/config.orig" "$WG_WAYBAR_CONFIG"
  [ "$status" -eq 0 ]
  run diff "$WG_TMP/style.orig" "$WG_WAYBAR_STYLE"
  [ "$status" -eq 0 ]
  run diff "$WG_TMP/bindings.orig" "$WG_HYPR_BINDINGS"
  [ "$status" -eq 0 ]
  run diff "$WG_TMP/autostart.orig" "$WG_HYPR_AUTOSTART"
  [ "$status" -eq 0 ]
}

@test "uninstall removes the symlinks but leaves the state file" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
  [ ! -e "$WG_BIN_DIR/wingroup" ]
  [ -f "$WG_STATE_DIR/state.json" ]
}

@test "uninstall on a machine that was never installed does nothing and succeeds" {
  run "$WG_ROOT/uninstall.sh"
  [ "$status" -eq 0 ]
  run diff "$WG_TMP/config.orig" "$WG_WAYBAR_CONFIG"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats test/install.bats`
Expected: FAIL — `install.sh: No such file or directory`.

- [ ] **Step 4: Write the implementation**

`install.sh` (`chmod +x`):

```bash
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
WG_SIGNAL=11

backup() {
  [[ -f $1 ]] || return 0
  cp -p "$1" "$1.bak.$(date +%s)"
}

link_binaries() {
  mkdir -p "$WG_BIN_DIR"
  local f
  for f in "$WG_ROOT"/bin/*; do
    ln -sfn "$f" "$WG_BIN_DIR/$(basename "$f")"
  done
}

waybar_modules_block() {
  local i
  printf '  // >>> wingroup\n'
  for (( i = 0; i < WG_SLOTS; i++ )); do
    printf '  "custom/wingroup%d": {\n' "$i"
    printf '    "exec": "wingroup-waybar %d",\n' "$i"
    printf '    "return-type": "json",\n'
    printf '    "interval": "once",\n'
    printf '    "signal": %d,\n' "$WG_SIGNAL"
    printf '    "on-click": "wingroup activate %d",\n' "$i"
    printf '    "on-click-right": "wingroup menu",\n'
    printf '    "tooltip": true\n'
    printf '  },\n'
  done
  printf '  // <<< wingroup\n'
}

install_waybar_config() {
  grep -q 'custom/wingroup0' "$WG_WAYBAR_CONFIG" && return 0
  backup "$WG_WAYBAR_CONFIG"

  local slots i tmp
  slots=""
  for (( i = 0; i < WG_SLOTS; i++ )); do
    slots+=", \"custom/wingroup$i\""
  done

  tmp="$(mktemp)"
  awk -v slots="$slots" -v block="$(waybar_modules_block)" '
    NR == 1 && $0 ~ /^\{/ { print; print block; next }
    /"modules-left"[[:space:]]*:/ { sub(/\][[:space:]]*,[[:space:]]*$/, slots "],"); print; next }
    { print }
  ' "$WG_WAYBAR_CONFIG" >"$tmp"
  mv -f "$tmp" "$WG_WAYBAR_CONFIG"
}

install_waybar_style() {
  grep -q '>>> wingroup' "$WG_WAYBAR_STYLE" && return 0
  backup "$WG_WAYBAR_STYLE"

  local i base="" busy="" active=""
  for (( i = 0; i < WG_SLOTS; i++ )); do
    base+="${base:+, }#custom-wingroup$i"
    busy+="${busy:+, }#custom-wingroup$i.busy"
    active+="${active:+, }#custom-wingroup$i.active"
  done

  {
    printf '\n/* >>> wingroup */\n'
    printf '%s { padding: 0 6px; opacity: 0.55; }\n' "$base"
    printf '%s { opacity: 1; }\n' "$busy"
    printf '%s { opacity: 1; font-weight: bold; }\n' "$active"
    printf '/* <<< wingroup */\n'
  } >>"$WG_WAYBAR_STYLE"
}

install_bindings() {
  grep -q '>>> wingroup' "$WG_HYPR_BINDINGS" && return 0
  backup "$WG_HYPR_BINDINGS"
  cat >>"$WG_HYPR_BINDINGS" <<'EOF'

# >>> wingroup
unbind = SUPER, G
bindd = SUPER, G, Window groups, exec, wingroup menu
bindd = SUPER CTRL, G, Send window to group, exec, wingroup send
# <<< wingroup
EOF
}

install_autostart() {
  grep -q '>>> wingroup' "$WG_HYPR_AUTOSTART" && return 0
  backup "$WG_HYPR_AUTOSTART"
  cat >>"$WG_HYPR_AUTOSTART" <<'EOF'

# >>> wingroup
exec-once = wingroup-daemon
# <<< wingroup
EOF
}

seed_state() {
  mkdir -p "$WG_STATE_DIR"
  [[ -f "$WG_STATE_DIR/state.json" ]] && return 0
  printf '%s\n' '{"auto":true,"catchall":null,"groups":[],"overrides":{}}' >"$WG_STATE_DIR/state.json"
}

link_binaries
install_waybar_config
install_waybar_style
install_bindings
install_autostart
seed_state

printf 'wingroup installed. Reload with: hyprctl reload && pkill -SIGUSR2 waybar\n'
printf 'Then create your first group, e.g.: wingroup new shop shop-web shop-core\n'
printf 'and file the windows you already have open: wingroup tidy\n'
```

`uninstall.sh` (`chmod +x`):

```bash
#!/usr/bin/env bash
set -euo pipefail

WG_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

: "${WG_BIN_DIR:=$HOME/.local/bin}"
: "${WG_WAYBAR_CONFIG:=$HOME/.config/waybar/config.jsonc}"
: "${WG_WAYBAR_STYLE:=$HOME/.config/waybar/style.css}"
: "${WG_HYPR_BINDINGS:=$HOME/.config/hypr/bindings.conf}"
: "${WG_HYPR_AUTOSTART:=$HOME/.config/hypr/autostart.conf}"

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
  local file="$1" open="$2" close="$3" tmp
  [[ -f $file ]] || return 0
  grep -qF -- "$open" "$file" || return 0
  tmp="$(mktemp)"
  awk -v open="$open" -v close="$close" '''
    index($0, open) { skip = 1; pending = 0; next }
    skip            { if (index($0, close)) skip = 0; next }
    /^$/            { if (pending) print ""; pending = 1; next }
                    { if (pending) { print ""; pending = 0 } print }
    END             { if (pending) print "" }
  ''' "$file" >"$tmp"
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

printf 'wingroup uninstalled. Your groups are kept in %s\n' "${WG_STATE_DIR:-$HOME/.local/state/omarchy/wingroup}"
```

The blank line matters: `install.sh` writes one before each appended block so the
user's config stays readable, and `strip_block` is the only thing that knows to
take it back. If the byte-exact uninstall test fails, the bug is in this pairing —
fix the pairing, do not relax the test.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats test/`
Expected: PASS, every file.

- [ ] **Step 6: Commit**

```bash
git add install.sh uninstall.sh test/install.bats test/fixtures/waybar-config.jsonc test/fixtures/waybar-style.css
git commit -m "feat: add idempotent, reversible install and uninstall"
```

---

### Task 9: Startup integration with restore-claude.sh, and docs

`~/restore-claude.sh` respawns the Claude terminals that were open at shutdown, each with `xdg-terminal-exec --dir="$cwd"`. Because the cwd is set at spawn time, the daemon's resolution already files those windows correctly — but only if the daemon is running first, and only if the shell wins the retry race. A `tidy` pass afterwards makes the outcome deterministic regardless of timing, which is what this task adds.

**Files:**
- Create: `bin/wingroup-restore`
- Create: `test/bin/restore-stub`
- Modify: `README.md`
- Modify: `install.sh` — autostart block gains the restore line
- Test: `test/restore.bats`

**Interfaces:**
- Consumes: `wingroup tidy --yes` (Task 7).
- Produces: the executable `wingroup-restore`, honouring `WG_RESTORE_SCRIPT` (default `$HOME/restore-claude.sh`) and `WG_RESTORE_SETTLE` (default `5`, seconds to wait for spawned shells before tidying). Arguments are passed through to the restore script, so `wingroup-restore --dry-run` stays a dry run and tidies nothing.

- [ ] **Step 1: Write the restore stub**

`test/bin/restore-stub` (`chmod +x`):

```bash
#!/usr/bin/env bash
printf 'restore %s\n' "$*" >>"$WG_RESTORE_LOG"
```

- [ ] **Step 2: Write the failing tests**

`test/restore.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  export WG_TEST_STUB_CWD=1
  export WG_RESTORE_LOG="$WG_TMP/restore.log"
  : >"$WG_RESTORE_LOG"
  export WG_RESTORE_SCRIPT="$WG_ROOT/test/bin/restore-stub"
  export WG_RESTORE_SETTLE=0
  export PATH="$WG_ROOT/bin:$PATH"
}

teardown() { wg_teardown_tmp; }

@test "restore runs the session restore script" {
  "$WG_ROOT/bin/wingroup-restore"
  run cat "$WG_RESTORE_LOG"
  [[ "$output" == restore* ]]
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats test/restore.bats`
Expected: FAIL — `bin/wingroup-restore: No such file or directory`.

- [ ] **Step 4: Write the implementation**

`bin/wingroup-restore` (`chmod +x`):

```bash
#!/usr/bin/env bash
# Restore the Claude sessions that were open at shutdown, then make sure every
# restored terminal ends up in its project's group. The daemon files them as
# they open; this tidy pass makes the result independent of that race.
set -euo pipefail

: "${WG_RESTORE_SCRIPT:=$HOME/restore-claude.sh}"
: "${WG_RESTORE_SETTLE:=5}"

if [[ ! -x $WG_RESTORE_SCRIPT ]]; then
  printf 'wingroup-restore: no restore script at %s, nothing to do\n' "$WG_RESTORE_SCRIPT" >&2
  exit 0
fi

"$WG_RESTORE_SCRIPT" "$@"

# A dry run spawns nothing, so there is nothing to file.
for arg in ${@+"$@"}; do
  [[ $arg == --dry-run || $arg == -n ]] && exit 0
done

# Terminals need a moment to spawn their shells before cwd resolution works.
[[ $WG_RESTORE_SETTLE == 0 ]] || sleep "$WG_RESTORE_SETTLE"

wingroup tidy --yes
```

- [ ] **Step 5: Add the restore line to the autostart block**

In `install.sh`, `install_autostart` becomes:

```bash
install_autostart() {
  grep -q '>>> wingroup' "$WG_HYPR_AUTOSTART" && return 0
  backup "$WG_HYPR_AUTOSTART"
  cat >>"$WG_HYPR_AUTOSTART" <<'EOF'
# >>> wingroup
exec-once = wingroup-daemon
exec-once = wingroup-restore
# <<< wingroup
EOF
}
```

and `test/install.bats` gains one assertion inside the existing keybinds-and-autostart test:

```bash
  grep -q 'exec-once = wingroup-restore' "$WG_HYPR_AUTOSTART"
```

The daemon line comes first so the daemon is listening before the restore script spawns anything.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats test/`
Expected: PASS, every file.

- [ ] **Step 7: Write the README**

Replace `README.md` with real usage documentation: what a group is, the waybar strip and what its superscript and highlighting mean, the two keybinds, every `wingroup` subcommand with an example, the shape of `state.json` with a worked example of a group owning three projects, how automatic assignment decides (and that a window with no project is left alone), the startup integration with `restore-claude.sh` including `WG_RESTORE_SCRIPT` and `WG_RESTORE_SETTLE`, install and uninstall instructions, and a troubleshooting section covering: the bar not updating (waybar must be reloaded once after install, and the daemon must be running), a window not being filed (its shell's cwd is outside `~/projects`), and how to check what the resolver sees (`wingroup tidy` shows its planned moves before applying them).

Remove the "Status: design approved, implementation in progress" line.

- [ ] **Step 8: Run the full suite and shellcheck one last time**

Run: `bats test/ && shellcheck -x lib/*.sh bin/* install.sh uninstall.sh`
Expected: PASS, no shellcheck output.

- [ ] **Step 9: Commit and open the pull request**

```bash
git add bin/wingroup-restore test/restore.bats test/bin/restore-stub test/install.bats install.sh README.md
git commit -m "feat: restore Claude sessions into their groups on startup, and document usage"
git push -u origin feat/wingroup-implementation
gh pr create --title "Project-based window grouping for Omarchy" --fill
```

---

## Manual verification

The suite never touches the live compositor, so these are done by hand once, after `./install.sh` and `hyprctl reload && pkill -SIGUSR2 waybar`:

1. `wingroup new shop shop-web shop-core shop-api` — the strip gains an `shop` button.
   Look at the numbered workspace indicators at the same time. The spec flags this as an
   open question: waybar's `hyprland/workspaces` module may now render the named group
   workspace as an anonymous icon next to `1 2 3`, because the Omarchy config maps
   `format-icons` by number and everything else falls through to `default`. If it does,
   add `"ignore-workspaces": ["^[^0-9]"]` to that module in `~/.config/waybar/config.jsonc`.
   Confirm what waybar 0.15.0 actually does before changing anything — do not add the
   option pre-emptively.
2. `wingroup tidy` — preview lists the shop windows; confirm; they move to the `shop` workspace.
3. Click the `shop` button — the workspace activates.
4. `SUPER+G` — the picker lists groups and windows with correct busy counts.
5. Open a new terminal inside `~/projects/shop-web` — it lands on the `shop` workspace by itself.
6. `SUPER+CTRL+G` on that window, pick another group — it moves, and stays put on subsequent events.
7. Give a Claude session a task and watch its group's superscript busy count go up, then back down when it finishes.

## Future work (not in scope)

- **Remote agents.** The existing remote agent setup could surface as its own group whose "windows" are remote sessions rather than local ones. That means an entry source that is not `hyprctl clients`, which the current design does not have — it would be its own spec.
- **A GTK layer-shell overlay** replacing the walker picker, with drag-and-drop between groups. The backend is already CLI-shaped, so the UI is replaceable without touching resolution, state or the daemon.
- **Per-group monitor binding.** `state.json` already carries a `monitor` field; nothing reads it yet.
