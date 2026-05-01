#!/bin/sh

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
$TMUX kill-server 2>/dev/null

TMP=$(mktemp)
TMP2=$(mktemp)
trap "rm -f $TMP $TMP2; $TMUX kill-server 2>/dev/null" 0 1 15

$TMUX -f/dev/null new -d -x20 -y5 'printf "one\n"; printf "two\n"; sleep 5' ||
	exit 1
sleep 1

$TMUX capturep -pL -S0 -E1 >$TMP || exit 1
awk -F '	' '
	NR == 1 { if ($1 != 1 || $2 != "one") exit 1 }
	NR == 2 { if ($1 != 2 || $2 != "two") exit 1 }
	END { if (NR != 2) exit 1 }
' $TMP || exit 1

$TMUX capturep -p -S0 -E1 >$TMP || exit 1
printf 'one\ntwo\n' | cmp -s - $TMP || exit 1

$TMUX kill-server 2>/dev/null
$TMUX -f/dev/null new -d -x20 -y5 'printf "left\n"; sleep 5' || exit 1
$TMUX splitw -d 'printf "right\n"; sleep 5' || exit 1
sleep 1

$TMUX capturep -pL -t%0 -S0 -E0 >$TMP || exit 1
$TMUX capturep -pL -t%1 -S0 -E0 >$TMP2 || exit 1
awk -F '	' 'NR == 1 { if ($1 != 1 || $2 != "left") exit 1 }' $TMP ||
	exit 1
awk -F '	' 'NR == 1 { if ($1 != 1 || $2 != "right") exit 1 }' $TMP2 ||
	exit 1

$TMUX kill-server 2>/dev/null
$TMUX -f/dev/null new -d -x5 -y5 'printf "abcdef"; sleep 5' || exit 1
sleep 1

$TMUX capturep -pL -S0 -E1 >$TMP || exit 1
awk -F '	' '
	NR == 1 { first = $1; if ($2 != "abcde") exit 1 }
	NR == 2 { if ($1 <= first || $2 != "f") exit 1 }
	END { if (NR != 2) exit 1 }
' $TMP || exit 1

$TMUX capturep -pLJ >$TMP 2>&1 && exit 1
grep -- '-L and -J are incompatible' $TMP >/dev/null || exit 1

$TMUX capturep -pLP >$TMP 2>&1 && exit 1
grep -- '-L and -P are incompatible' $TMP >/dev/null || exit 1

$TMUX kill-server 2>/dev/null
$TMUX -f/dev/null start-server \; set -g history-limit 3 \; \
	new -d -x20 -y3 'i=1; while [ $i -le 12 ]; do printf "l%02d\n" $i; i=$((i + 1)); done; sleep 5' ||
	exit 1
sleep 1

$TMUX capturep -pL -S- -E- >$TMP || exit 1
awk -F '	' '
	$1 == 0 { next }
	previous != "" && $1 <= previous { exit 1 }
	{ previous = $1; count++ }
	END { if (count < 3) exit 1 }
' $TMP || exit 1

$TMUX kill-server 2>/dev/null
exit 0
