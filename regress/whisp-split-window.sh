#!/bin/sh

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest-whisp-split"
$TMUX kill-server 2>/dev/null

TMP=$(mktemp)
TMP2=$(mktemp)
trap "rm -f $TMP $TMP2; $TMUX kill-server 2>/dev/null" 0 1 15

$TMUX -f/dev/null new -d -x80 -y48 \
	"trap 'echo winch >> $TMP' WINCH; while :; do sleep 1; done" || exit 1
sleep 1
$TMUX whisp-split-window -d -h -f -l80 -x161 -y48 'sleep 5' || exit 1
sleep 2
test ! -s "$TMP" || exit 1
$TMUX display-message -p '#{window_width}x#{window_height}' >"$TMP2" || exit 1
printf '161x48\n' | cmp -s - "$TMP2" || exit 1
$TMUX list-panes -F '#{pane_width}x#{pane_height}' | sort >"$TMP2" || exit 1
printf '80x48\n80x48\n' | cmp -s - "$TMP2" || exit 1

$TMUX kill-server 2>/dev/null
$TMUX -f/dev/null new -d -x80 -y48 \
	"trap 'echo winch >> $TMP' WINCH; while :; do sleep 1; done" || exit 1
sleep 1
$TMUX whisp-split-window -d -v -f -l48 -x80 -y97 'sleep 5' || exit 1
sleep 2
test ! -s "$TMP" || exit 1
$TMUX display-message -p '#{window_width}x#{window_height}' >"$TMP2" || exit 1
printf '80x97\n' | cmp -s - "$TMP2" || exit 1
$TMUX list-panes -F '#{pane_width}x#{pane_height}' | sort >"$TMP2" || exit 1
printf '80x48\n80x48\n' | cmp -s - "$TMP2" || exit 1

$TMUX kill-server 2>/dev/null
: >"$TMP"
: >"$TMP2"
$TMUX -f/dev/null new -d -x80 -y48 \
	"trap 'echo winch >> $TMP' WINCH; while :; do sleep 1; done" || exit 1
$TMUX split-window -d -h -l39 \
	"trap 'echo winch >> $TMP2' WINCH; while :; do sleep 1; done" || exit 1
sleep 2
: >"$TMP"
: >"$TMP2"
$TMUX whisp-split-window -d -h -f -l40 -x121 -y48 -t%0 'sleep 5' || exit 1
sleep 2
test ! -s "$TMP" || exit 1
test ! -s "$TMP2" || exit 1
$TMUX list-panes -F '#{pane_width}x#{pane_height}' | sort >"$TMP2" || exit 1
printf '39x48\n40x48\n40x48\n' | cmp -s - "$TMP2" || exit 1

$TMUX kill-server 2>/dev/null
: >"$TMP"
: >"$TMP2"
$TMUX -f/dev/null new -d -x80 -y48 \
	"trap 'echo winch >> $TMP' WINCH; while :; do sleep 1; done" || exit 1
$TMUX split-window -d -h -l69 \
	"trap 'echo winch >> $TMP2' WINCH; while :; do sleep 1; done" || exit 1
sleep 2
: >"$TMP"
: >"$TMP2"
$TMUX whisp-split-window -d -h -f -l10 -x91 -y48 -t%0 'sleep 5' || exit 1
sleep 2
test ! -s "$TMP" || exit 1
test ! -s "$TMP2" || exit 1
$TMUX list-panes -F '#{pane_width}x#{pane_height}' | sort >"$TMP2" || exit 1
printf '10x48\n10x48\n69x48\n' | cmp -s - "$TMP2" || exit 1

$TMUX whisp-split-window -d -h -f -l40 -x122 -y48 -t%0 'sleep 5' >"$TMP2" 2>&1 &&
	exit 1
grep 'geometry must preserve existing space' "$TMP2" >/dev/null || exit 1

$TMUX kill-server 2>/dev/null
exit 0
