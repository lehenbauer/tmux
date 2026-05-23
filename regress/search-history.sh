#!/bin/sh

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
$TMUX kill-server 2>/dev/null

TMP=$(mktemp)
trap "rm -f $TMP; $TMUX kill-server 2>/dev/null" 0 1 15

$TMUX -f/dev/null new -d -x40 -y5 \
	'printf "alpha alpha\nbeta\nneedle\n"; sleep 5' || exit 1
$TMUX splitw -d 'printf "nomatch\nneedle needle\n"; sleep 5' || exit 1
sleep 1

$TMUX search-history -F '#{pane_id}	#{match_count}	#{matching_line_count}	#{first_match_line}	#{last_match_line}' needle >$TMP ||
	exit 1
awk -F '	' '
	$1 == "%0" {
		if ($2 != 1 || $3 != 1 || $4 != 3 || $5 != 3) exit 1
		seen0 = 1
	}
	$1 == "%1" {
		if ($2 != 2 || $3 != 1 || $4 != 2 || $5 != 2) exit 1
		seen1 = 1
	}
	END { if (!seen0 || !seen1 || NR != 2) exit 1 }
' $TMP || exit 1

$TMUX search-history -i -F '#{pane_id}	#{match_count}' NEEDLE >$TMP ||
	exit 1
awk -F '	' '
	$1 == "%0" { if ($2 != 1) exit 1; seen0 = 1 }
	$1 == "%1" { if ($2 != 2) exit 1; seen1 = 1 }
	END { if (!seen0 || !seen1 || NR != 2) exit 1 }
' $TMP || exit 1

$TMUX search-history -r -F '#{pane_id}	#{match_count}' 'n[e]+dle' >$TMP ||
	exit 1
awk -F '	' '
	$1 == "%0" { if ($2 != 1) exit 1; seen0 = 1 }
	$1 == "%1" { if ($2 != 2) exit 1; seen1 = 1 }
	END { if (!seen0 || !seen1 || NR != 2) exit 1 }
' $TMP || exit 1

$TMUX search-history -F '#{pane_id}' absent >$TMP || exit 1
test ! -s $TMP || exit 1

$TMUX kill-server 2>/dev/null
$TMUX -f/dev/null new -d -x40 -y5 'printf "needle\n"; sleep 5' ||
	exit 1
sleep 1
cat <<EOF|$TMUX -C a >$TMP
search-history -F '#{pane_id} #{match_count}' needle
EOF
grep '^%0 1$' $TMP >/dev/null || exit 1

$TMUX kill-server 2>/dev/null
$TMUX -f/dev/null new-session -d -s one -x40 -y5 \
	'printf "sharedtoken\n"; sleep 5' || exit 1
$TMUX new-session -d -s two -x40 -y5 'sleep 5' || exit 1
$TMUX link-window -s one:0 -t two:1 || exit 1
sleep 1

$TMUX search-history -F '#{pane_id}' sharedtoken >$TMP || exit 1
awk 'END { if (NR != 1) exit 1 }' $TMP || exit 1

$TMUX kill-server 2>/dev/null
$TMUX -f/dev/null start-server \; set -g history-limit 10 \; \
	new -d -x40 -y3 \
	'printf "oldtoken\nl2\nl3\nl4\nl5\n"; sleep 5' || exit 1
sleep 1

$TMUX display-message -p '#{C:oldtoken}' >$TMP || exit 1
printf '0\n' | cmp -s - $TMP || exit 1

$TMUX search-history -F '#{match_count}	#{matching_line_count}	#{first_match_line}	#{last_match_line}	#{retained_first_line}	#{retained_last_line}' oldtoken >$TMP ||
	exit 1
awk -F '	' '
	NR == 1 {
		if ($1 != 1 || $2 != 1 || $3 != 1 || $4 != 1) exit 1
		if ($5 > $3 || $6 < $4) exit 1
	}
	END { if (NR != 1) exit 1 }
' $TMP || exit 1

$TMUX search-history '' >$TMP 2>&1 && exit 1
grep -- 'empty search pattern' $TMP >/dev/null || exit 1

$TMUX search-history -r '[' >$TMP 2>&1 && exit 1
grep -- 'invalid regular expression' $TMP >/dev/null || exit 1

$TMUX kill-server 2>/dev/null
exit 0
