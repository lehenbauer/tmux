#!/bin/sh

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=../tmux
if [ ! -x "$TEST_TMUX" ]; then
	echo "TEST_TMUX must name an executable tmux binary" >&2
	exit 1
fi

EXPECT_REASSERT=${EXPECT_REASSERT:-1}
PROBE_LABEL=${PROBE_LABEL:-fixed}
SOCKET=whisp_fix_probe_${PROBE_LABEL}_$$
WORK=$(mktemp -d "/tmp/whisp-pty-reassert.XXXXXX") || exit 1
SERVER_CREATED=0

cleanup()
{
	if [ "$SERVER_CREATED" -eq 1 ]; then
		"$TEST_TMUX" -L"$SOCKET" kill-server 2>/dev/null
	fi
	rm -f "$WORK"/*
	rmdir "$WORK"
}
trap cleanup 0 1 2 15

tmux()
{
	"$TEST_TMUX" -L"$SOCKET" -f/dev/null "$@"
}

wait_for_file()
{
	file=$1
	n=0
	while [ ! -s "$file" ]; do
		if [ "$n" -eq 100 ]; then
			echo "timed out waiting for $file" >&2
			exit 1
		fi
		sleep 0.05
		n=$((n + 1))
	done
}

pane_size()
{
	session=$1
	file=$2
	tmux send-keys -t"$session:0.0" "stty size > $file" Enter || exit 1
	wait_for_file "$file"
	tr -d '\r\n' <"$file"
}

grid_size()
{
	tmux display-message -p -t"$1:0.0" '#{pane_width}x#{pane_height}'
}

tmux new-session -d -s same -x53 -y26 /bin/sh || exit 1
SERVER_CREATED=1
sleep 0.2
tmux send-keys -t same:0.0 \
	"stty rows 50 cols 100; stty size > $WORK/same-before" Enter || exit 1
wait_for_file "$WORK/same-before"
same_before=$(tr -d '\r\n' <"$WORK/same-before")
same_grid_before=$(grid_size same) || exit 1
tmux resize-window -t same:0 -x53 -y26 || exit 1
same_after=$(pane_size same "$WORK/same-after") || exit 1
same_grid_after=$(grid_size same) || exit 1
printf 'SAME_BEFORE grid=%s pty=%s\n' "$same_grid_before" "$same_before"
printf 'SAME_AFTER grid=%s pty=%s\n' "$same_grid_after" "$same_after"
test "$same_grid_before" = 53x26 || exit 1
test "$same_before" = "50 100" || exit 1
test "$same_grid_after" = 53x26 || exit 1
if [ "$EXPECT_REASSERT" -eq 1 ]; then
	test "$same_after" = "26 53" || exit 1
	echo "SAME_SIZE_REASSERT=PASS"
else
	test "$same_after" = "50 100" || exit 1
	echo "SAME_SIZE_REASSERT=FAIL_EXPECTED_STOCK"
fi

tmux resize-window -t same:0 -x54 -y27 || exit 1
different_pty=$(pane_size same "$WORK/different") || exit 1
different_grid=$(grid_size same) || exit 1
printf 'DIFFERENT_AFTER grid=%s pty=%s\n' "$different_grid" "$different_pty"
test "$different_grid" = 54x27 || exit 1
test "$different_pty" = "27 54" || exit 1
echo "DIFFERENT_SIZE_LOCKSTEP=PASS"

tmux new-session -d -s queue -x53 -y26 /bin/sh || exit 1
sleep 0.2
queue_before=$(pane_size queue "$WORK/queue-before") || exit 1
tmux resize-window -t queue:0 -x100 -y50 \; \
	resize-window -t queue:0 -x53 -y26 || exit 1
sleep 0.5
queue_after=$(pane_size queue "$WORK/queue-after") || exit 1
queue_grid=$(grid_size queue) || exit 1
printf 'QUEUE_BEFORE grid=53x26 pty=%s\n' "$queue_before"
printf 'QUEUE_FINAL grid=%s pty=%s\n' "$queue_grid" "$queue_after"
test "$queue_before" = "26 53" || exit 1
test "$queue_grid" = 53x26 || exit 1
test "$queue_after" = "26 53" || exit 1
echo "QUEUE_BURST_SETTLE=PASS"

tmux new-session -d -s matching -x53 -y26 /bin/sh || exit 1
sleep 0.2
matching_before=$(pane_size matching "$WORK/matching-before") || exit 1
tmux send-keys -t matching:0.0 \
	"trap 'echo WINCH >> $WORK/winch' WINCH; echo READY > $WORK/ready; sleep 3" \
	Enter || exit 1
wait_for_file "$WORK/ready"
tmux resize-window -t matching:0 -x53 -y26 || exit 1
sleep 0.5
matching_grid=$(grid_size matching) || exit 1
if [ -s "$WORK/winch" ]; then
	matching_winch=$(wc -l <"$WORK/winch" | tr -d ' ')
else
	matching_winch=0
fi
printf 'MATCHING_BEFORE grid=53x26 pty=%s\n' "$matching_before"
printf 'MATCHING_AFTER grid=%s SIGWINCH=%s\n' "$matching_grid" "$matching_winch"
test "$matching_before" = "26 53" || exit 1
test "$matching_grid" = 53x26 || exit 1
test "$matching_winch" -eq 0 || exit 1
echo "MATCHING_SAME_SIZE_SIGNAL_FREE=PASS"
echo "PROBE_COMPLETE label=$PROBE_LABEL socket=$SOCKET"
