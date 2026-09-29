# shellcheck shell=bash
# Reading a recorded arrangement back as the sequence of splits that built it.
#
# The problem this solves: Hyprland's dwindle layout has no notion of "put this
# window at these coordinates". It splits the tile of whichever window has
# focus, in a direction it picks from that tile's shape, and the arrangement
# that results is a consequence of the order windows arrived in. A restore that
# only moves and resizes finished windows is therefore arguing with the layout:
# it can put the right sessions in the tiles that happen to exist, but it cannot
# make different tiles exist. Measured on one real restore, that left three of
# five groups wrong, two windows six and ten pixels wide among them -- the size
# pass pushing against a tree that could not give it the shape it wanted.
#
# What makes it solvable is that every dwindle arrangement is a guillotine
# partition: each split cuts one tile clean across, so the finished rectangles
# can always be separated by a straight line, and each half again, down to
# single windows. That recursion is the tree, and the tree is the order.
#
# `hyprctl dispatch layoutmsg preselect <dir>` then says which way the next
# window entering a tile should split it -- verified against Hyprland 0.56.2,
# including for a window moved in from another workspace rather than newly
# opened, which is what lets a restore bulk-launch as it always has and fix the
# arrangement afterwards.

# How far apart two edges may be and still count as the same line.
#
# Tiles do not touch: Hyprland leaves a gap between them, and the record holds
# the gapped rectangles. On this desktop the gap measures 14 pixels, so the
# right edge of one window sits 14 short of the next window's left edge and an
# exact comparison finds no cut anywhere. The tolerance is well above that and
# well below any real window, which is what keeps it from joining two columns
# that genuinely are separate.
: "${WG_TREE_TOL:=40}"

# The tree, as parallel arrays indexed by node id. A leaf carries a key and no
# children; a split carries both children, its direction, and the key of the
# window that owns its whole region until the split is made -- always the
# top-left one, since that is the tile every later cut is taken out of.
declare -a WG_TREE_LEFT=() WG_TREE_RIGHT=() WG_TREE_DIR=() WG_TREE_FIRST=()
WG_TREE_N=0
WG_TREE_NODE=0

# The rectangles being read, also as parallel arrays.
declare -a WG_TREE_RX=() WG_TREE_RY=() WG_TREE_RW=() WG_TREE_RH=() WG_TREE_RKEY=()

# Is every rectangle in $1 (a space separated list of indices) on one side or
# the other of the line at $3, along the axis $2 ("x" or "y")? Sets
# WG_TREE_NEAR and WG_TREE_FAR to the two groups, and fails if either is empty
# or if any rectangle straddles the line.
wg_tree_cut() {
  local set="$1" axis="$2" at="$3" i start extent
  WG_TREE_NEAR=""
  WG_TREE_FAR=""
  for i in $set; do
    if [[ $axis == x ]]; then
      start="${WG_TREE_RX[i]}"; extent="${WG_TREE_RW[i]}"
    else
      start="${WG_TREE_RY[i]}"; extent="${WG_TREE_RH[i]}"
    fi
    if (( start + extent <= at + WG_TREE_TOL )); then
      WG_TREE_NEAR+="$i "
    elif (( start + WG_TREE_TOL >= at )); then
      WG_TREE_FAR+="$i "
    else
      return 1
    fi
  done
  [[ -n $WG_TREE_NEAR && -n $WG_TREE_FAR ]]
}

# Builds the tree for the rectangles in $1 and leaves its node id in
# WG_TREE_NODE. Fails if the rectangles are not a guillotine partition, which
# means the record cannot be replayed and the caller must leave the group alone.
wg_tree_build() {
  local set="$1" id i n=0 axis at found=0
  local -a candidates=()
  for i in $set; do n=$(( n + 1 )); done

  id=$(( WG_TREE_N++ ))
  WG_TREE_LEFT[id]=-1
  WG_TREE_RIGHT[id]=-1

  if (( n == 1 )); then
    set="${set% }"

    WG_TREE_FIRST[id]="${WG_TREE_RKEY[$set]}"
    WG_TREE_NODE=$id
    return 0
  fi

  # Vertical before horizontal, and it is a real choice rather than an arbitrary
  # one only in a grid, where both cuts are available and either rebuilds the
  # same rectangles. Fixing the order keeps the plan the same from one run to
  # the next, which is what makes it testable.
  for axis in x y; do
    candidates=()
    for i in $set; do
      if [[ $axis == x ]]; then candidates+=("${WG_TREE_RX[i]}"); else candidates+=("${WG_TREE_RY[i]}"); fi
    done
    while IFS= read -r at; do
      wg_tree_cut "$set" "$axis" "$at" || continue
      found=1
      break
    done < <(printf '%s\n' "${candidates[@]}" | sort -n -u)
    (( found )) && break
  done

  if (( ! found )); then
    # No line separates them: either the record holds an arrangement dwindle
    # could not have built, or two of its rectangles overlap. Either way there
    # is nothing honest to do with it.
    return 1
  fi

  local near="$WG_TREE_NEAR" far="$WG_TREE_FAR" left right
  wg_tree_build "$near" || return 1
  left=$WG_TREE_NODE
  wg_tree_build "$far" || return 1
  right=$WG_TREE_NODE

  WG_TREE_LEFT[id]=$left
  WG_TREE_RIGHT[id]=$right
  [[ $axis == x ]] && WG_TREE_DIR[id]=r || WG_TREE_DIR[id]=d
  WG_TREE_FIRST[id]="${WG_TREE_FIRST[$left]}"
  WG_TREE_NODE=$id
  return 0
}

# Walks the tree parents first, which is the order the moves have to be made in:
# a split takes its region out of the tile the seed owns, so the seed must still
# own the whole of it -- undivided -- at that moment.
wg_tree_emit() {
  local id="$1" left="${WG_TREE_LEFT[$1]}" right="${WG_TREE_RIGHT[$1]}"
  (( left >= 0 )) || return 0
  printf 'split %s %s %s\n' "${WG_TREE_FIRST[$id]}" "${WG_TREE_DIR[$id]}" "${WG_TREE_FIRST[$right]}"
  wg_tree_emit "$left"
  wg_tree_emit "$right"
}

# Reads "key x y w h" rows on stdin and writes the plan. Empty input plans
# nothing and is not an error: a group with no recorded windows is simply a
# group there is nothing to do to.
wg_tree_plan() {
  local key x y w h set="" i=0
  WG_TREE_RX=(); WG_TREE_RY=(); WG_TREE_RW=(); WG_TREE_RH=(); WG_TREE_RKEY=()
  WG_TREE_LEFT=(); WG_TREE_RIGHT=(); WG_TREE_DIR=(); WG_TREE_FIRST=()
  WG_TREE_N=0

  while read -r key x y w h; do
    [[ -n $key ]] || continue
    [[ $x =~ ^-?[0-9]+$ && $y =~ ^-?[0-9]+$ ]] || return 1
    [[ $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] || return 1
    WG_TREE_RKEY[i]="$key"; WG_TREE_RX[i]="$x"; WG_TREE_RY[i]="$y"
    WG_TREE_RW[i]="$w"; WG_TREE_RH[i]="$h"
    set+="$i "
    i=$(( i + 1 ))
  done

  (( i )) || return 0
  wg_tree_build "$set" || return 1
  printf 'root %s\n' "${WG_TREE_FIRST[$WG_TREE_NODE]}"
  wg_tree_emit "$WG_TREE_NODE"
}
