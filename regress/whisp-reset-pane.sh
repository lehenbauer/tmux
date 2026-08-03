#!/bin/sh

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest-whisp-reset-pane"

TMP=$(mktemp)
TMP2=$(mktemp)
trap 'rm -f "$TMP" "$TMP2"; $TMUX kill-server 2>/dev/null' 0 1 15

run_wedge()
{
    setting=$1
    $TMUX kill-server 2>/dev/null
    $TMUX new -d -x40 -y8 \
        "printf 'before-reset-1\\nbefore-reset-2\\nbefore-reset-3\\nbefore-reset-4\\nbefore-reset-5\\nbefore-reset-6\\nbefore-reset-7\\nbefore-reset-8\\nbefore-reset-9\\nbefore-reset-10\\n'; \
         printf '\\033[?1h\\033[4h\\033[?6h\\033[?7l\\033[?25l\\033[?1003h\\033[?1004h\\033[?2004h\\033[?2026h'; \
        vim -u NONE -N -c 'set mouse=a'; exec sh" ||
        exit 1
    $TMUX set-option -g scroll-on-clear "$setting" || exit 1
    $TMUX set-option -g history-limit 100 || exit 1
    sleep 1
    pane=$($TMUX display-message -p '#{pane_id}') || exit 1
    pane_pid=$($TMUX display-message -p '#{pane_pid}') || exit 1
    vim_pid=$(pgrep -P "$pane_pid") || exit 1

    state=$($TMUX display-message -p -t"$pane" \
        '#{alternate_on} #{mouse_any_flag}') || exit 1
    test "$state" = '1 1' || exit 1
    echo "PASS wedge scroll-on-clear=$setting alternate_on=1 mouse_any_flag=1"

    history_before=$($TMUX display-message -p -t"$pane" '#{history_size}') ||
        exit 1
    test "$history_before" -gt 0 || exit 1
    $TMUX whisp-capture-pane -t"$pane" -L \
        "-S-$history_before" -E-1 >"$TMP" || exit 1
    test -s "$TMP" || exit 1

    kill -KILL "$vim_pid" || exit 1
    sleep 1
    $TMUX whisp-reset-pane -t"$pane" || exit 1
    state=$($TMUX display-message -p -t"$pane" \
        '#{alternate_on} #{mouse_any_flag} #{mouse_standard_flag} #{mouse_button_flag} #{bracket_paste_flag} #{cursor_flag} #{origin_flag} #{insert_flag} #{wrap_flag} #{keypad_cursor_flag} #{keypad_flag} #{synchronized_output_flag} #{scroll_region_upper} #{scroll_region_lower} #{cursor_x},#{cursor_y} #{alternate_saved_x} #{alternate_saved_y}') || exit 1
    test "$state" = '0 0 0 0 0 1 0 0 1 0 0 0 0 7 0,0 4294967295 4294967295' || {
        echo "FAIL: soft reset state: $state" >&2
        exit 1
    }
    history_after=$($TMUX display-message -p -t"$pane" '#{history_size}') ||
        exit 1
    test "$history_after" = "$history_before" || exit 1
    $TMUX whisp-capture-pane -t"$pane" -L \
        "-S-$history_after" -E-1 >"$TMP2" || exit 1
    cmp -s "$TMP" "$TMP2" || exit 1
    echo "PASS soft-reset scroll-on-clear=$setting state=$state history_size=$history_after history_rows_identical=1"

    $TMUX kill-server 2>/dev/null
}

# The wedge must heal without growing history with either scroll-on-clear value.
run_wedge 1
run_wedge 0

# A copy-mode pane is reset out of its window mode on both soft and hard paths.
$TMUX new -d -x40 -y8 'printf "copy-mode-history-1\\ncopy-mode-history-2\\ncopy-mode-history-3\\n"; exec sh' || exit 1
$TMUX set-option -g history-limit 100 || exit 1
sleep 1
PANE=$($TMUX display-message -p '#{pane_id}') || exit 1
$TMUX copy-mode -t"$PANE" || exit 1
mode=$($TMUX display-message -p -t"$PANE" '#{pane_in_mode} #{pane_mode}') || exit 1
test "$mode" != '0 ' || exit 1
$TMUX whisp-reset-pane -t"$PANE" || exit 1
mode=$($TMUX display-message -p -t"$PANE" '#{pane_in_mode} #{pane_mode}') || exit 1
test "$mode" = '0 ' || exit 1
$TMUX copy-mode -t"$PANE" || exit 1
$TMUX whisp-reset-pane -H -t"$PANE" || exit 1
mode=$($TMUX display-message -p -t"$PANE" '#{pane_in_mode} #{pane_mode}') || exit 1
history_size=$($TMUX display-message -p -t"$PANE" '#{history_size}') || exit 1
test "$mode" = '0 ' -a "$history_size" -eq 0 || exit 1
echo 'PASS copy-mode soft-and-hard-exit history_size=0'

# A reset of a healthy shell remains usable.
$TMUX send-keys -t"$PANE" -l 'healthy-after-reset' || exit 1
$TMUX send-keys -t"$PANE" Enter || exit 1
sleep 1
$TMUX capture-pane -p -t"$PANE" -S- -E- >"$TMP" || exit 1
grep 'healthy-after-reset' "$TMP" >/dev/null || exit 1
echo 'PASS healthy-shell usable'

# remain-on-exit panes are reset best-effort and remain addressable.
$TMUX set-option -g remain-on-exit on || exit 1
DEAD=$($TMUX new -d -P -F '#{pane_id}' -x40 -y8 'exit 42') || exit 1
sleep 1
dead_state=$($TMUX display-message -p -t"$DEAD" '#{pane_dead}') || exit 1
test "$dead_state" = 1 || exit 1
$TMUX whisp-reset-pane -t"$DEAD" || exit 1
dead_state=$($TMUX display-message -p -t"$DEAD" \
    '#{pane_dead} #{alternate_on} #{mouse_any_flag} #{pane_in_mode}') || exit 1
test "$dead_state" = '1 0 0 0' || exit 1
echo 'PASS dead-pane remain-on-exit reset pane_dead=1'

# Hard reset clears the retained history.
$TMUX whisp-reset-pane -H -t"$PANE" || exit 1
history_size=$($TMUX display-message -p -t"$PANE" '#{history_size}') || exit 1
test "$history_size" -eq 0 || exit 1
echo 'PASS hard-reset history_size=0'

# Resetting a pane while a process is producing output must not crash the server.
LIVE=$($TMUX split-window -d -P -F '#{pane_id}' -t"$PANE" \
    'i=0; while :; do printf "live-%s\\n" "$i"; i=$((i + 1)); done') || exit 1
sleep 1
$TMUX whisp-reset-pane -t"$LIVE" || exit 1
$TMUX has || exit 1
$TMUX kill-pane -t"$LIVE" || exit 1
echo 'PASS live-output reset server-alive'

version=$($TMUX display-message -p '#{whisp_tmux_protocol_version}') || exit 1
test "$version" = 8 || exit 1
echo 'PASS protocol_version=8'

$TMUX kill-server 2>/dev/null
exit 0
