# Round 5 — idle heat ramp on the waybar strip

## What was asked

*"if inactive window in group make the group more and more red, more inactive ->
more red, bright"* — the group's waybar label warms and brightens with its idle
count, as CSS classes rather than inline pango colour.

## What was built

**`bin/wingroup-waybar`** — a second class beside the state class:

- `WG_IDLE_HEAT_MAX=4`. Idle count 0 emits no idle class at all; 1..3 emit
  `idle1`..`idle3`; 4 and above emit `idle4`. The cap is on the class only —
  the label's superscript still says `⁵` or `¹²`.
- The existing `active` / `visible` / `busy` decision is untouched. The heat
  class is appended to a `classes` array after it, never in place of it.
- `wg_emit` now takes the classes as trailing arguments and emits `class` as a
  plain string when there is one (or none) and as a **JSON array** when there
  are several. `waybar-custom(5)` states: *"The class parameter also accepts an
  array of strings."* The array is the only mechanism that puts two classes on
  one widget — a string `"busy idle4"` becomes a single GTK class of that
  literal name, which `.busy` does not match — so `#custom-wingroup0.active.idle3`
  works only via the array. Single-class output is byte-identical to before.

**`install.sh`** — `WG_IDLE_HEAT_RAMP`, four declaration blocks, written by
`install_waybar_style` as one rule per step, each naming all 8 slots:

```css
#custom-wingroup0.idle1, … { color: #e0a458; opacity: 0.75; }
#custom-wingroup0.idle2, … { color: #ef8354; opacity: 0.85; }
#custom-wingroup0.idle3, … { color: #f45d48; opacity: 0.95; font-weight: 600; }
#custom-wingroup0.idle4, … { color: #ff3b30; opacity: 1; font-weight: bold; }
```

Amber → orange → red-orange → bright red, with opacity and weight climbing
alongside the hue so it reads at a glance on a dark bar. Literal colours, not
`@foreground`: leaving the palette the rest of the bar sits in is the point.

**Rule order is load-bearing.** The ramp is written *between* the base rule and
the three state rules. A group carries a state class and a heat class at the
same time and both selectors are one id plus one class — equal specificity, so
the later rule wins whatever they share. Before the states, the ramp lifts the
dimmed 0.55 default for a group with work waiting in it while `active` keeps
the last word on opacity and weight: an active group stays fully bright and
bold and merely takes the ramp's colour. After the states, it would have dimmed
and un-bolded the group being looked at — the one thing it must never do. A
test asserts the ordering.

Everything stays inside the existing `/* >>> wingroup */` block, so the
marker / `wg_ends_with_newline` / `eof_flag` machinery reverses it unchanged.

**`README.md`** — an "Idle heat" bullet in the waybar strip section, and a new
"The CSS classes, and recolouring the idle ramp" subsection: the class names,
that both classes land on the widget at once, and that an override goes *after*
the marker block (last rule of equal specificity wins) rather than inside it.

## Tests

`bats test/` — **223 passing, 0 failing** (was 208). `shellcheck -x lib/*.sh
bin/* install.sh uninstall.sh` clean.

New, in `test/waybar.bats` (helper `wg_group_windows <group> <idle> <busy>`
builds a client list of N idle / M busy windows owned by an override):

- idle 0 → no class; 1 → `idle1`; 2 → `idle2`; 3 → `idle3`; 5 and 12 → `idle4`
  (and the superscript still shows the true count).
- combines with `busy` (`busy idle4`), with `active` (`active idle3`) and with
  `visible` (`visible idle2`).
- one class goes out as a string, several as the array waybar needs.

New, in `test/install.bats` / `test/install-edgecases.bats`:

- one rule per step for slots 0 and 7; warm at 1 and `#ff3b30` + bold at 4;
  the ramp precedes the `active` rule; uninstall removes it and the style file
  diffs clean; the whole round trip on the no-trailing-newline style fixture,
  with the `<<< wingroup no-eof-nl` flag still on the closing marker.

## Revert observation

With `bin/wingroup-waybar` and `install.sh` reverted to HEAD (tests left in
place), the new tests fail exactly where the feature is missing:

- `waybar.bats`: `one idle session warms the group…` (`idle1`), `two…`
  (`idle2`), `three…` (`idle3`), `five idle sessions cap…` and `a wildly idle
  group still caps…` (`idle4`), plus the three combination tests and the
  string/array shape test — all fail. `a group with no idle sessions emits no
  idle class at all` **passes** while reverted, which is what it is for: it
  pins the unchanged zero-idle behaviour.
- `install.bats`: `install writes the idle heat ramp…`, `the ramp runs from
  warm to bright red…`, `the ramp is written before the state rules…`,
  `uninstall takes the idle ramp back out` fail.
- `install-edgecases.bats`: `install/uninstall round-trips the idle ramp in a
  style with no trailing newline` fails.

Restoring the two files returns the suite to 223/223.

## Concern: one requirement could not hold literally

*"The existing waybar tests must keep passing unchanged"* is not satisfiable
together with *"the idle class combines with `active`, `visible` and `busy`"*,
given the fixtures:

- `test/fixtures/state.json`'s `everest` group (slot 0) holds one idle and one
  busy window — the superscript and tooltip tests depend on exactly that — so
  the group in `a group with busy windows gets the busy class` necessarily
  carries `idle1` too.
- `test/fixtures/state-template.json`'s `template` group likewise holds one
  idle and one busy window, and every `active` / `visible` test uses it.

Eight assertions therefore compared the whole class field against a single
state name. They were changed mechanically: `jq -r '.class'` → a new
`wg_class_list` helper (which flattens the string-or-array field to a
space-separated list), and the expected value gained the ` idle1` it now
carries. No test name, fixture, or intent was changed, and no fixture was
weakened to dodge the conflict — bending a fixture so the old assertions still
read true would have been test-fudging. Tests whose group has no idle window
(`a group on no monitor at all is not visible`, and the empty-slot cases) are
untouched and still use `jq -r '.class'`.

The alternative — leaving `class` a bare string so those assertions survived —
would have shipped a feature that does nothing in waybar, since a
space-separated class string matches no selector.

## Smells noticed, not fixed (out of scope)

- `WG_IDLE_HEAT_MAX` exists in both `bin/wingroup-waybar` and `install.sh` and
  must agree: the module emits the top class, the installer writes the rule for
  it. A comment in each ties them together, but nothing enforces it. If a third
  consumer of that number appears it belongs in `lib/`.
