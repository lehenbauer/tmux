#!/bin/sh

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
SOCKET=test-whisp-kill-pane-atomic-$$
SERVER_CREATED=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/whisp-kill-pane.XXXXXX") || exit 1
WINCH="$WORK/winch"
HOOK="$WORK/hook"
BEFORE="$WORK/before"
AFTER="$WORK/after"
OUT="$WORK/out"

cleanup()
{
	if [ "$SERVER_CREATED" -eq 1 ]; then
		"$TEST_TMUX" -L"$SOCKET" kill-server 2>/dev/null
	fi
	rm -f "$WINCH" "$HOOK" "$BEFORE" "$AFTER" "$OUT"
	rmdir "$WORK"
}
trap cleanup 0 1 15

tmux()
{
	"$TEST_TMUX" -L"$SOCKET" "$@"
}

reset_server()
{
	if [ "$SERVER_CREATED" -eq 1 ]; then
		tmux kill-server 2>/dev/null
	fi
	SERVER_CREATED=0
	: >"$WINCH"
	: >"$HOOK"
	: >"$BEFORE"
	: >"$AFTER"
	: >"$OUT"
}

probe()
{
	printf '%s' "trap 'printf \"%s\\n\" \"\$TMUX_PANE\" >> \"$WINCH\"' WINCH; while :; do sleep 1; done"
}

layout()
{
	body=$1
	csum=0
	for byte in $(printf '%s' "$body" | od -An -tu1); do
		csum=$(((csum >> 1) + ((csum & 1) << 15) + byte))
		csum=$((csum & 65535))
	done
	printf '%04x,%s' "$csum" "$body"
}

winch_count()
{
	pane=$1
	awk -v pane="$pane" '$0 == pane { count++ } END { print count + 0 }' \
	    "$WINCH"
}

snapshot()
{
	tmux display-message -p \
	    '#{window_layout}|#{window_width}x#{window_height}|#{window_zoomed_flag}'
	tmux list-panes -F \
	    '#{pane_id}|#{pane_index}|#{pane_left},#{pane_top}|#{pane_width}x#{pane_height}|#{pane_z}|#{pane_floating}'
}

refuses_without_mutation()
{
	description=$1
	shift
	snapshot >"$BEFORE" || exit 1
	if tmux "$@" >"$OUT" 2>&1; then
		echo "FAIL: $description unexpectedly succeeded" >&2
		exit 1
	fi
	snapshot >"$AFTER" || exit 1
	if ! cmp -s "$BEFORE" "$AFTER"; then
		echo "FAIL: $description mutated the window" >&2
		diff -u "$BEFORE" "$AFTER" >&2
		exit 1
	fi
}

# Shrink-close: the pane that existed before the full-size split must not
# receive a resize. The hook must observe the final layout exactly once.
reset_server
tmux -f/dev/null new -d -x120 -y40 "$(probe)" || exit 1
SERVER_CREATED=1
survivor=$(tmux display-message -p '#{pane_id}') || exit 1
target=$(tmux whisp-split-window -d -P -F '#{pane_id}' -h -f -l120 \
    -x241 -y40 -t"$survivor" 'sleep 30') || exit 1
sleep 1
: >"$WINCH"
body="120x40,0,0,${survivor#%}"
final_layout=$(layout "$body") || exit 1
tmux set-hook -g after-kill-pane \
    "run-shell 'printf \"%s\\n\" \"#{window_layout}\" >> \"$HOOK\"'" || exit 1
tmux whisp-kill-pane -t"$target" "$final_layout" || exit 1
sleep 2
test "$(winch_count "$survivor")" -eq 0 || {
	echo "FAIL: shrink survivor received SIGWINCH" >&2
	exit 1
}
test "$(tmux display-message -p '#{window_layout}')" = "$final_layout" ||
	exit 1
test "$(tmux display-message -p '#{window_width}x#{window_height}')" = \
    120x40 || exit 1
test "$(tmux list-panes -F '#{pane_id}:#{pane_left},#{pane_top}:#{pane_width}x#{pane_height}')" = \
    "$survivor:0,0:120x40" || exit 1
test "$(wc -l <"$HOOK" | tr -d ' ')" -eq 1 || exit 1
test "$(sed -n '1p' "$HOOK")" = "$final_layout" || exit 1

# A second mutation catches z-index queue damage. All tiled panes have z=1 in
# this fork; an empty/duplicated traversal or a different value is corruption.
tmux whisp-split-window -d -h -f -l40 -x161 -y40 -t"$survivor" \
    'sleep 30' >/dev/null || exit 1
test "$(tmux list-panes -F '#{pane_id}:#{pane_z}' | wc -l | tr -d ' ')" -eq 2 ||
	exit 1
tmux list-panes -F '#{pane_id}:#{pane_z}' >"$OUT" || exit 1
if grep -Ev '^%[0-9]+:1$' "$OUT" >/dev/null; then
	echo "FAIL: pane z-index is not sane after second mutation" >&2
	exit 1
fi
echo "PASS shrink-close survivor=$survivor SIGWINCH=0 hook=1 second-mutation=ok"

# Divergent absorb topology: the left column contains top, middle, bottom panes
# beside one full-height right pane. Closing the middle with policy=down selects
# bottom as absorber, while tmux's natural TAILQ_PREV merge selects top. Both
# top and right must therefore stay untouched.
reset_server
tmux -f/dev/null new -d -x241 -y41 "$(probe)" || exit 1
SERVER_CREATED=1
top=$(tmux display-message -p '#{pane_id}') || exit 1
right=$(tmux split-window -d -P -F '#{pane_id}' -h -l120 -t"$top" \
    "$(probe)") || exit 1
bottom=$(tmux split-window -d -P -F '#{pane_id}' -v -l13 -t"$top" \
    "$(probe)") || exit 1
victim=$(tmux split-window -d -P -F '#{pane_id}' -v -l13 -t"$top" \
    "$(probe)") || exit 1
sleep 1
test "$(tmux display-message -p -t"$top" '#{pane_top}')" -eq 0 || exit 1
test "$(tmux display-message -p -t"$victim" '#{pane_top}')" -eq 14 || exit 1
test "$(tmux display-message -p -t"$bottom" '#{pane_top}')" -eq 28 || exit 1
test "$(tmux display-message -p -t"$right" '#{pane_left}')" -eq 121 || exit 1
: >"$WINCH"
body="241x41,0,0{120x41,0,0[120x13,0,0,${top#%},120x27,0,14,${bottom#%}],120x41,121,0,${right#%}}"
final_layout=$(layout "$body") || exit 1
tmux whisp-kill-pane -t"$victim" "$final_layout" || exit 1
sleep 2
test "$(winch_count "$top")" -eq 0 || {
	echo "FAIL: divergent absorb untouched pane received SIGWINCH" >&2
	exit 1
}
test "$(winch_count "$right")" -eq 0 || {
	echo "FAIL: divergent absorb right pane received SIGWINCH" >&2
	exit 1
}
test "$(winch_count "$bottom")" -eq 1 || {
	echo "FAIL: divergent absorb absorber did not receive exactly one SIGWINCH" >&2
	exit 1
}
test "$(tmux display-message -p '#{window_layout}')" = "$final_layout" ||
	exit 1
test "$(tmux list-panes -F '#{pane_id}:#{pane_left},#{pane_top}:#{pane_width}x#{pane_height}')" = \
    "$top:0,0:120x13
$bottom:0,14:120x27
$right:121,0:120x41" || exit 1
echo "PASS divergent-absorb untouched=$top,$right SIGWINCH=0 absorber=$bottom SIGWINCH=1"

# Refusals: each command must fail without changing layout, pane order,
# geometry, z-index, zoom state, or floating state.
reset_server
tmux -f/dev/null new -d -x80 -y24 'sleep 30' || exit 1
SERVER_CREATED=1
first=$(tmux display-message -p '#{pane_id}') || exit 1
second=$(tmux split-window -d -P -F '#{pane_id}' -h -l40 -t"$first" \
    'sleep 30') || exit 1
body="80x24,0,0,${first#%}"
refuses_without_mutation "bad checksum" whisp-kill-pane -t"$second" \
    "0000,$body"
echo "PASS refusal bad-checksum"

fake_id=4294967294
final_layout=$(layout "80x24,0,0,$fake_id") || exit 1
refuses_without_mutation "survivor ID mismatch" whisp-kill-pane -t"$second" \
    "$final_layout"
echo "PASS refusal survivor-id-mismatch"

reset_server
tmux -f/dev/null new -d -x80 -y24 'sleep 30' || exit 1
SERVER_CREATED=1
first=$(tmux display-message -p '#{pane_id}') || exit 1
second=$(tmux split-window -d -P -F '#{pane_id}' -h -l26 -t"$first" \
    'sleep 30') || exit 1
third=$(tmux split-window -d -P -F '#{pane_id}' -h -l26 -t"$second" \
    'sleep 30') || exit 1
body="80x24,0,0{39x24,0,0,${first#%},40x24,40,0,${first#%}}"
final_layout=$(layout "$body") || exit 1
refuses_without_mutation "duplicate pane IDs" whisp-kill-pane -t"$third" \
    "$final_layout"
echo "PASS refusal duplicate-pane-ids"

reset_server
tmux -f/dev/null new -d -x80 -y24 'sleep 30' || exit 1
SERVER_CREATED=1
first=$(tmux display-message -p '#{pane_id}') || exit 1
second=$(tmux split-window -d -P -F '#{pane_id}' -h -l40 -t"$first" \
    'sleep 30') || exit 1
tmux resize-pane -Z -t"$first" || exit 1
final_layout=$(layout "80x24,0,0,${first#%}") || exit 1
refuses_without_mutation "zoomed window" whisp-kill-pane -t"$second" \
    "$final_layout"
echo "PASS refusal zoomed-window"

reset_server
tmux -f/dev/null new -d -x80 -y24 'sleep 30' || exit 1
SERVER_CREATED=1
first=$(tmux display-message -p '#{pane_id}') || exit 1
floating=$(tmux new-pane -d -P -F '#{pane_id}' -x20 -y10 -X5 -Y5 \
    -t"$first" 'sleep 30') || exit 1
refuses_without_mutation "floating pane present" whisp-kill-pane -t"$first" \
    invalid-layout
echo "PASS refusal floating-pane-present pane=$floating"

reset_server
tmux -f/dev/null new -d -x80 -y24 'sleep 30' || exit 1
SERVER_CREATED=1
only=$(tmux display-message -p '#{pane_id}') || exit 1
refuses_without_mutation "last pane" whisp-kill-pane -t"$only" invalid-layout
echo "PASS refusal last-pane"

exit 0
