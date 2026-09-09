# shellcheck shell=bash
# The two numbers the bar module and the installer have to agree on.
#
# They live here because neither half works alone: bin/wingroup-waybar emits a
# class and answers for a slot, install.sh writes the rule and defines the
# module. A slot the installer does not define is a group with no button; a
# class the installer writes no rule for styles nothing. Both numbers used to be
# written twice and kept in step by a comment, which is not a mechanism.
#
# Nothing here uses what it defines -- that is the point of the file -- so
# "appears unused" (SC2034) is expected.
# shellcheck disable=SC2034

# How many "custom/wingroupN" modules the bar has. Groups past the last one stay
# fully usable from the picker and the CLI; the last slot's tooltip says how
# many more there are.
WG_SLOTS=8

# Top step of the idle heat ramp: idle4 means "four idle sessions or more".
# A ceiling, because past a handful the exact number stops changing what you do
# about it -- and every step needs a rule of its own in style.css.
WG_IDLE_HEAT_MAX=4
