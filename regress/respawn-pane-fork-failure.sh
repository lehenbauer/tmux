#!/bin/sh

# respawn-pane after a failed fork must leave a usable dead pane.
#
# A respawn releases the pane's pty, event and input parser before forking.
# If the fork fails, the pane is kept, so a second respawn (or any command
# that reads the parser) must not find a freed or NULL parser. Failure is
# injected only into this test's own server: an interposed forkpty() fails
# with EAGAIN while a trigger file exists. Nothing touches host limits, and
# the server uses an absolute socket in a private directory.

PATH=/bin:/usr/bin
TERM=screen
unset TMUX TMUX_PANE

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
DIR=$(mktemp -d "${TMPDIR:-/tmp}/tmux-respawn-fail.XXXXXX") || exit 1
SOCKET=$DIR/s
TRIGGER=$DIR/fail-forkpty
TMUX="$TEST_TMUX -S$SOCKET -f/dev/null"
SERVER_PID=

cleanup()
{
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        $TMUX kill-server 2>/dev/null
    fi
    rm -rf "$DIR"
}
trap cleanup 0 1 15

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

unsupported()
{
    echo "UNSUPPORTED: $* (fork failure cannot be injected; not a pass)" >&2
    exit 2
}

# -- child-only fault injector --------------------------------------------
cat >"$DIR/failpty.c" <<'EOF'
#include <sys/types.h>
#include <errno.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <dlfcn.h>
#include <pty.h>
#endif

static int
should_fail(void)
{
	const char *path = getenv("TMUX_TEST_FORKPTY_FAIL");

	return (path != NULL && access(path, F_OK) == 0);
}

#ifdef __APPLE__
static pid_t
failing_forkpty(int *m, char *n, struct termios *t, struct winsize *w)
{
	if (should_fail()) {
		errno = EAGAIN;
		return (-1);
	}
	return (forkpty(m, n, t, w));
}
__attribute__((used)) static struct {
	const void *replacement;
	const void *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
	{ (const void *)failing_forkpty, (const void *)forkpty },
};
#else
pid_t
forkpty(int *m, char *n, const struct termios *t, const struct winsize *w)
{
	pid_t (*next)(int *, char *, const struct termios *,
	    const struct winsize *) = dlsym(RTLD_NEXT, "forkpty");

	if (should_fail()) {
		errno = EAGAIN;
		return (-1);
	}
	return (next(m, n, t, w));
}
#endif
EOF
case $(uname -s) in
Darwin)
    cc -dynamiclib -o "$DIR/failpty.so" "$DIR/failpty.c" 2>"$DIR/cc.log" ||
        unsupported "cannot build interposer: $(cat "$DIR/cc.log")"
    PRELOAD="DYLD_INSERT_LIBRARIES=$DIR/failpty.so"
    ;;
Linux)
    cc -shared -fPIC -o "$DIR/failpty.so" "$DIR/failpty.c" -ldl \
        2>"$DIR/cc.log" ||
        unsupported "cannot build interposer: $(cat "$DIR/cc.log")"
    PRELOAD="LD_PRELOAD=$DIR/failpty.so"
    ;;
*)
    unsupported "no interposer for $(uname -s)"
    ;;
esac

# -- server with one target pane and one unrelated pane --------------------
env "$PRELOAD" TMUX_TEST_FORKPTY_FAIL="$TRIGGER" $TMUX new -d -x80 -y24 \
    'sleep 1000' || fail "server start"
SERVER_PID=$($TMUX display-message -p '#{pid}') || fail "server pid"
$TMUX new-window -d 'sleep 1000' || fail "unrelated window"
TARGET=$($TMUX display-message -p -t:0 '#{pane_id}') || fail "target pane"
OTHER=$($TMUX display-message -p -t:1 '#{pane_id}') || fail "other pane"
OTHER_PID=$($TMUX display-message -p -t"$OTHER" '#{pane_pid}') ||
    fail "other pid"

alive()
{
    kill -0 "$SERVER_PID" 2>/dev/null &&
        [ "$($TMUX display-message -p '#{pid}' 2>/dev/null)" = "$SERVER_PID" ]
}

# Prove injection is active: a new window must fail and leave no window.
: >"$TRIGGER"
if out=$($TMUX new-window -d 'sleep 1000' 2>&1); then
    unsupported "forkpty interposer did not take effect"
fi
case $out in *"fork failed"*) ;; *) unsupported "unexpected error: $out" ;; esac
[ "$($TMUX list-windows | wc -l | tr -d ' ')" = 2 ] ||
    fail "failed new-window left a window behind"
echo "PASS injection new-window: $out"

# -- initial and repeated failed respawns ----------------------------------
for attempt in 1 2 3; do
    out=$($TMUX respawn-pane -k -t"$TARGET" 'sleep 1000' 2>&1) &&
        fail "respawn $attempt unexpectedly succeeded"
    case $out in
    *"fork failed"*) ;;
    *) alive || fail "server died on failed respawn $attempt"
       fail "respawn $attempt: unexpected error: $out" ;;
    esac
    alive || fail "server died on failed respawn $attempt"
    # The pane is kept (upstream respawn semantics); it has no process.
    state=$($TMUX display-message -p -t"$TARGET" '#{pane_id} #{pane_dead}') ||
        fail "pane missing after failed respawn $attempt"
    [ "${state% *}" = "$TARGET" ] || fail "wrong pane after failed respawn"
    echo "PASS failed respawn $attempt: server $SERVER_PID alive, pane kept ($state)"
done
# Without -k: a dead pane may be respawned, and may fail again.
$TMUX respawn-pane -t"$TARGET" 'sleep 1000' 2>/dev/null &&
    fail "respawn without -k unexpectedly succeeded"
alive || fail "server died on failed respawn without -k"
echo "PASS failed respawn without -k"

# -- commands that read the pane parser or pty state -----------------------
$TMUX capture-pane -p -t"$TARGET" >/dev/null || fail "capture-pane"
$TMUX capture-pane -p -e -t"$TARGET" >/dev/null || fail "capture-pane -e"
$TMUX capture-pane -p -P -t"$TARGET" >/dev/null || fail "capture-pane -P"
$TMUX whisp-reset-pane -t"$TARGET" || fail "whisp-reset-pane"
$TMUX whisp-reset-pane -H -t"$TARGET" || fail "whisp-reset-pane -H"
$TMUX whisp-capture-pane -R -t"$TARGET" >/dev/null ||
    fail "whisp-capture-pane -R"
$TMUX send-keys -R -t"$TARGET" || fail "send-keys -R"
$TMUX send-keys -t"$TARGET" x Enter || fail "send-keys"
$TMUX resize-pane -t"$TARGET" -x 60 2>/dev/null
$TMUX display-message -p -t"$TARGET" '#{pane_pid} #{pane_dead} #{pane_tty}' \
    >/dev/null || fail "display-message"
alive || fail "server died on commands against the failed pane"
echo "PASS capture (-e, -P)/whisp-reset-pane (soft, -H)/send-keys/display on failed pane"

# The unrelated pane was never disturbed.
[ "$($TMUX display-message -p -t"$OTHER" '#{pane_dead} #{pane_pid}')" = \
    "0 $OTHER_PID" ] || fail "unrelated pane changed"
kill -0 "$OTHER_PID" || fail "unrelated pane process died"
echo "PASS unrelated pane $OTHER intact"

# -- recovery: a later respawn succeeds normally --------------------------
rm -f "$TRIGGER"
$TMUX respawn-pane -t"$TARGET" \
    "printf 'respawn-recovered\\n'; exec sleep 1000" ||
    fail "recovery respawn"
sleep 1
[ "$($TMUX display-message -p -t"$TARGET" '#{pane_dead}')" = 0 ] ||
    fail "pane still dead after recovery"
$TMUX capture-pane -p -t"$TARGET" | grep -q respawn-recovered ||
    fail "recovered pane has no output"
$TMUX send-keys -R -t"$TARGET" || fail "send-keys -R after recovery"
# A normal successful respawn -k of a live pane still works.
$TMUX respawn-pane -k -t"$TARGET" 'sleep 1000' || fail "normal respawn -k"
[ "$($TMUX display-message -p -t"$TARGET" '#{pane_dead}')" = 0 ] ||
    fail "normal respawn -k left pane dead"
echo "PASS recovery respawn and normal respawn -k"

# -- destroy after failure -------------------------------------------------
: >"$TRIGGER"
$TMUX respawn-pane -k -t"$TARGET" 'sleep 1000' 2>/dev/null &&
    fail "respawn before kill unexpectedly succeeded"
$TMUX kill-pane -t"$TARGET" || fail "kill-pane after failed respawn"
alive || fail "server died destroying the failed pane"
# (display-message -t on a missing pane prints nothing and succeeds.)
$TMUX list-panes -a -F '#{pane_id}' | grep -qx "$TARGET" &&
    fail "failed pane still exists after kill-pane"
[ "$($TMUX display-message -p -t"$OTHER" '#{pane_dead}')" = 0 ] ||
    fail "unrelated pane died"
rm -f "$TRIGGER"
echo "PASS kill-pane after failed respawn"

$TMUX kill-server || fail "kill-server"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.2
done
kill -0 "$SERVER_PID" 2>/dev/null && fail "server $SERVER_PID survived kill-server"
SERVER_PID=
echo "PASS respawn-pane-fork-failure"
exit 0
