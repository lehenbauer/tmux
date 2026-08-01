Result: PASS — same-size pane resizes now heal external PTY winsize drift without disturbing a pending resize queue or signaling an already-matching pane (`window.c:1248-1261`; both-binary output under “Both-binary probe table”).

# PTY same-size reassert

## Scope and base

The implementation was made only on `whisp-pty-reconcile`, whose HEAD and merge base with `whisp-3.7b` were the requested `251e304b` before the commit (`git rev-parse`, `git branch --show-current`, and `git merge-base` output):

```text
BASE_HEAD=251e304bec5461198fc8d47eee71ba3ab48f75d8
BRANCH=whisp-pty-reconcile
MERGE_BASE_WITH_WHISP_3_7B=251e304bec5461198fc8d47eee71ba3ab48f75d8
```

The clean-stock binary was copied before changing `window.c`; the stock build identified itself and hashed as follows (verbatim build-wrapper output):

```text
STOCK_AUTOGEN_EXIT=0
STOCK_CONFIGURE_COMMAND=./configure --enable-utf8proc
STOCK_CONFIGURE_EXIT=0
STOCK_MAKE_COMMAND=make
STOCK_MAKE_EXIT=0
tmux 3.7b
STOCK_BINARY_SHA256=c484f03bc23a7472bca7c78eeac0163d9bc32a6c8047e6559c11130d72a688ee
```

## Diff summary

- `window_pane_resize()` now declares a winsize readback, preserves the early return for `fd == -1` and for a non-empty `resize_queue`, then performs `TIOCGWINSZ` and calls the existing `window_pane_send_resize()` only when kernel columns or rows differ (`window.c:1248-1261`).
- The ordinary different-size branch remains after the new same-size block and still enqueues before updating the logical pane dimensions (`window.c:1264-1274`).
- `regress/pty-reassert.sh` uses one PID-unique private socket, removes only its own server in its trap, and exercises drift/reassert, different-size lockstep, queue settling, and matching-size SIGWINCH absence (`regress/pty-reassert.sh:14-30`, `regress/pty-reassert.sh:61-129`).
- The existing resize-queue consumer was not changed. Its empty-queue return remains at `server-client.c:1598-1599`, and its start=end burst rule still sends the penultimate size, retains the last queue entry, and schedules the follow-up at 10 ms (`server-client.c:1612-1657`). Exact diff-scope output:

```text
SERVER_CLIENT_DIFF=none
```

## Build evidence

The successful fixed build followed `sh autogen.sh`, `./configure --enable-utf8proc`, and `make`; a subsequent `make clean && make` rebuilt every object. Verbatim wrapper output:

```text
FIXED_AUTOGEN_COMMAND=sh autogen.sh
FIXED_AUTOGEN_EXIT=0
FIXED_CONFIGURE_COMMAND=./configure --enable-utf8proc
FIXED_CONFIGURE_EXIT=0
FIXED_MAKE_COMMAND=make
FIXED_MAKE_EXIT=0
FIXED_MAKE_CLEAN_EXIT=0
FIXED_FULL_MAKE_EXIT=0
STOCK_WARNING_COUNT=216
FIXED_WARNING_COUNT=216
BUILD_WARNING_PARITY=PASS exact warning lines match stock
CHANGED_FILE_DIAGNOSTICS=none
tmux 3.7b
FIXED_FULL_BINARY_SHA256=3e4ce9ddc153d0a44c22aa663a7a504df4af755e84d1832edf14f770a665764b
```

The macOS full build therefore completed successfully and introduced no new compiler diagnostic; the 216 existing warnings were byte-for-byte identical to the clean stock build’s warning lines (verbatim comparison output above).

## Both-binary probe table

The harness assertions and output fields are at `regress/pty-reassert.sh:61-129`. `EXPECT_REASSERT=0` is used only to let the stock baseline continue through every probe; the normal fixed-behavior assertion is the default at `regress/pty-reassert.sh:12`, and that normal mode exits 1 against stock as shown below.

| Probe | Stock `251e304b` | Fixed build |
| --- | --- | --- |
| External `stty rows 50 cols 100`, then same-size 53x26 | **FAIL as required:** PTY stays `50 100`; grid `53x26` | **PASS:** PTY heals to `26 53`; grid `53x26` |
| Different size 54x27 | **PASS:** grid `54x27`, PTY `27 54` | **PASS:** grid `54x27`, PTY `27 54` |
| One command batch 53x26 → 100x50 → 53x26 | **PASS:** final grid `53x26`, PTY `26 53` | **PASS:** final grid `53x26`, PTY `26 53` |
| Matching PTY, same-size 53x26 | **PASS:** `SIGWINCH=0` | **PASS:** `SIGWINCH=0` |

### Stock all-probe output

Command shape: `TEST_TMUX=/tmp/whisp-pty-reassert-251e304b/tmux-stock-251e304b EXPECT_REASSERT=0 PROBE_LABEL=stock sh regress/pty-reassert.sh`. Verbatim output:

```text
STOCK_PROBE_EXIT=0
SAME_BEFORE grid=53x26 pty=50 100
SAME_AFTER grid=53x26 pty=50 100
SAME_SIZE_REASSERT=FAIL_EXPECTED_STOCK
DIFFERENT_AFTER grid=54x27 pty=27 54
DIFFERENT_SIZE_LOCKSTEP=PASS
QUEUE_BEFORE grid=53x26 pty=26 53
QUEUE_FINAL grid=53x26 pty=26 53
QUEUE_BURST_SETTLE=PASS
MATCHING_BEFORE grid=53x26 pty=26 53
MATCHING_AFTER grid=53x26 SIGWINCH=0
MATCHING_SAME_SIZE_SIGNAL_FREE=PASS
PROBE_COMPLETE label=stock socket=whisp_fix_probe_stock_74542
```

The same stock binary run under the regression’s normal fixed-behavior expectation failed with exit 1 (verbatim output):

```text
STOCK_RED_REGRESSION_EXIT=1
SAME_BEFORE grid=53x26 pty=50 100
SAME_AFTER grid=53x26 pty=50 100
```

### Fixed all-probe output

Command shape: `TEST_TMUX=$PWD/tmux EXPECT_REASSERT=1 PROBE_LABEL=fixed_final sh regress/pty-reassert.sh`. Verbatim output from the final full-build binary:

```text
FIXED_FINAL_PROBE_EXIT=0
SAME_BEFORE grid=53x26 pty=50 100
SAME_AFTER grid=53x26 pty=26 53
SAME_SIZE_REASSERT=PASS
DIFFERENT_AFTER grid=54x27 pty=27 54
DIFFERENT_SIZE_LOCKSTEP=PASS
QUEUE_BEFORE grid=53x26 pty=26 53
QUEUE_FINAL grid=53x26 pty=26 53
QUEUE_BURST_SETTLE=PASS
MATCHING_BEFORE grid=53x26 pty=26 53
MATCHING_AFTER grid=53x26 SIGWINCH=0
MATCHING_SAME_SIZE_SIGNAL_FREE=PASS
PROBE_COMPLETE label=fixed_final socket=whisp_fix_probe_fixed_final_78991
FIXED_FINAL_SOCKET_AUDIT=PASS
```

The existing atomic close/resize regression also passed against the fixed binary; its output demonstrates that its deliberate resize/SIGWINCH behavior was retained (`regress/whisp-kill-pane.sh:1-240`):

```text
WHISP_KILL_PANE_REGRESSION_EXIT=0
PASS shrink-close survivor=%0 SIGWINCH=0 hook=1 second-mutation=ok
PASS divergent-absorb untouched=%0,%1 SIGWINCH=0 absorber=%2 SIGWINCH=1
PASS zindex-drain leaf-order=%1,%0 z=1,1
PASS refusal bad-checksum
PASS refusal survivor-id-mismatch
PASS refusal duplicate-pane-ids
PASS refusal zoomed-window
PASS refusal floating-pane-present pane=%1
PASS refusal last-pane
PRIVATE_SOCKET_SERVER_AUDIT=PASS no probe servers remain
```

## `server_client_check_pane_resize()` consideration

No broader empty-queue reconciliation was added to `server_client_check_pane_resize()`: that function is the recurring queue consumer and currently returns whenever the queue is empty (`server-client.c:1588-1599`). Adding `TIOCGWINSZ` there would change an idle/periodic server path from no work to kernel inspection and would heal drift without an explicit client resize request. The requested phone recovery does not require that wider ownership change because the fixed seam heals on the next same-size request (`window.c:1254-1261`; fixed output `SAME_AFTER grid=53x26 pty=26 53`). The broader reconcile remains a possible separate design if healing must occur without any later client request; it is intentionally not implemented here (`SERVER_CLIENT_DIFF=none` output above).

## Protocol reasoning

This change adds no command, option, format, control-mode notification, response-order change, or output encoding change: the source diff is confined to the internal same-size branch in `window_pane_resize()` plus its regression (`window.c:1248-1261`; `regress/pty-reassert.sh:1-129`). The protocol define remains 7 and the protocol-bearing files have no diff, so `whisp_tmux_protocol_version` needs no bump. Verbatim audit output:

```text
PROTOCOL_DEFINE=#define WHISP_TMUX_PROTOCOL_VERSION 7
PROTOCOL_SURFACE_DIFF=none
```

## Deviations

- Bare `./configure` stopped on this macOS host with the following verbatim output, so both successful builds used the fork-documented `./configure --enable-utf8proc` path (`WHISP_UPSTREAM.md:96-101`):

```text
configure: error: must give --enable-utf8proc or --disable-utf8proc
```

- The full build is not warning-free: it emits 216 existing warnings. The exact stock/fixed warning-line comparison passed and `window.c` emitted no diagnostic (`BUILD_WARNING_PARITY=PASS exact warning lines match stock`; `CHANGED_FILE_DIAGNOSTICS=none`). No warning cleanup was attempted because it is outside this change.
- No code-scope deviation: `server-client.c` and the protocol-bearing files remained unchanged (`SERVER_CLIENT_DIFF=none`; `PROTOCOL_SURFACE_DIFF=none`), and warning cleanup was intentionally left outside this fix (warning-parity output above).
