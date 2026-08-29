# Agents

# Core Engineering Mandates

- **Simplicity & Verifiable Steps:** Write the simplest code that solves the problem. Do not optimize prematurely. Work in reversible, verifiable increments at the largest step size you can still fully verify; drop to small iterations when behavior is unstable or your model of the system is in doubt — especially in terminal state handling.
- **Empirical Validation:** Code that has not been executed is assumed broken. For tmux behavior, validate with a built `tmux` binary, targeted shell/control-mode sessions, and focused regressions rather than relying only on inspection.
- **Root Cause Proof:** Never claim a bug is fixed without identifying the exact root cause. If a change merely makes behavior disappear, treat that as unresolved until the controlling mechanism is isolated.
- **Honesty Over Agreement:** Report the actual technical state. If a requested direction conflicts with tmux invariants or Whisp's integration model, say so clearly and propose a safer path.
- **Circuit Breaker:** If a fix fails repeatedly, or creates a nearby regression, stop and reassess the model of pane input, screen write state, grid history, and control-mode output before stacking speculative changes.

## Commit and Branch Policy

Autonomy ladder — each rung has its own gate:

1. **Feature-branch commits — autonomous.** Commit early and often once the
   change builds and its targeted regressions pass. Checkpoint commits of
   unverified work are fine; flag them in the message
   (`[unverified: needs live X]`). Keep unrelated local files out of commits:
   this checkout may contain agent-local files such as `.claude/`, `.gemini/`,
   and helper scripts — stage explicitly, never sweep with `git add -A`, and
   do not clean up or revert files unrelated to the task.
2. **Merge to the fork integration branch (currently `whisp-3.7c`) —
   autonomous when gated.** Gates: a clean build
   (`sh autogen.sh && ./configure && make`), the targeted `regress/` scripts
   for the touched area, and a live exercise of the changed behavior against a
   private-socket server (`./tmux -Ltest -f/dev/null`). Behavior only
   verifiable inside Whisp is recorded as owed validation, not a merge
   blocker.
3. **Push / tag / upstream merges — ask first.** `origin` is what Whisp
   releases pin, so pushing publishes for the next pin. Upstream refreshes
   follow `WHISP_UPSTREAM.md` (ship our changes atop upstream's tagged
   release); release tagging (`whisp-mac-<ver>-<build>-<channel>`) rides the
   Whisp release process.

- Remotes should be: `origin` as `git@github.com:lehenbauer/tmux.git` and `upstream` as `https://github.com/tmux/tmux.git`.

## Validation Is Proportional

Match validation to the diff's power to change behavior. Comment and man-page
wording changes need a build at most, not a regress sweep. A localized
behavior change needs its targeted `regress/` script plus one live
private-socket exercise. Grid, screen-write, reflow, capture, or control-mode
changes get the full relevant regress set plus the Whisp integration checks
below — those paths are load-bearing for every Whisp client. Judge eligibility
by the shape of the diff, not by confidence: a one-line change to a format, a
notification, or command syntax is behavior, never "small".

## Session memory

This fork keeps no local `docs/agent_memory/`; durable memory for tmux-fork
work lives in the Whisp repo. Before changing fork behavior, grep
`../ai-whisperer/docs/agent_memory/decisions.md` for the relevant topics
("Tmux runtime & protocol" and neighbors) — it is a grep-by-topic reference,
not a start-of-session read. Record fork decisions and upstream-merge notes
there (per `WHISP_UPSTREAM.md`): decisions as one dated ≤2-sentence bullet,
long-form records as a dated file under its `handoffs/`.

## Build and Validation

- Normal build from a clean checkout is:
  - `sh autogen.sh`
  - `./configure`
  - `make`
- Binaries destined for Whisp releases (ai-whisperer bundles `./tmux` from this
  checkout) must configure with `--enable-utf8proc --enable-jemalloc`: macOS
  26.x ARM libmalloc can return non-zeroed memory from calloc under pane-churn
  workloads (tmux issue 5385, crashed stock 3.7b), and upstream 3.7c+ requires
  an explicit jemalloc choice. Verify with
  `MALLOC_CONF=stats_print:true ./tmux -V` (prints jemalloc stats when active).
- Release tarballs may already have generated configure files, but this repo checkout may need `autogen.sh`.
- Targeted regressions live in `regress/`. The scripts expect `TEST_TMUX` or default to `../tmux`; examples:
  - `TEST_TMUX=$PWD/tmux sh regress/control-client-sanity.sh`
  - `TEST_TMUX=$PWD/tmux sh regress/capture-pane-sgr0.sh`
  - `cd regress && make` for the full shell regression set when the local make supports this BSD-style Makefile.
- For control-mode or pane-output changes, always exercise a real tmux server with a private socket name, for example `./tmux -Ltest -f/dev/null ...`, and kill the test server afterward.
- For scrollback/grid changes, include runtime checks for wrap, explicit linefeed, clear/reset, resize/reflow, alternate screen, and pane isolation when those paths are in scope.
- Grid consistency asserts (`grid_check_*`) are gated behind `TMUX_GRID_DEBUG` (fork commit `72d0982d`): they are O((history+screen)²) per scrolled linefeed and `assert()`-abort the whole server on failure, so customer builds must never ship them enabled. Never let an upstream merge silently restore always-on `#ifdef __APPLE__` gating; re-enable deliberately with `make CPPFLAGS='-DTMUX_GRID_DEBUG'` when hunting grid corruption.

## tmux Architecture Notes

- `window.c` owns panes and PTY I/O. The important path for terminal output is `window_pane_read_callback` -> `control_write_output` for control clients -> `input_parse_pane`.
- `window_pane_get_new_data` and `window_pane_update_used_data` track offsets into the pane input evbuffer. Control-mode `%output` and the terminal parser each maintain their own offsets.
- `input.c` parses bytes from the pane. Key symbols are `input_parse_pane`, `input_parse_buffer`, `input_parse`, `input_print`, and `input_c0_dispatch`.
- `screen-write.c` mutates the virtual screen. Start with `screen_write_start_pane`, `screen_write_cell`, `screen_write_linefeed`, `screen_write_scrollup`, `screen_write_clear*`, and `screen_write_reset`.
- `grid.c` and `grid-view.c` are the storage core. `grid-view.c` translates visible rows through `grid_view_y(gd, y) == gd->hsize + y`; `grid.c` works in absolute grid coordinates.
- `struct grid` splits lines into history rows `0..hsize-1` and visible rows `hsize..hsize+sy-1`. Do not change this indexing model casually; much of capture, copy mode, resize, and formatting relies on it.
- `struct grid_line` is the natural storage unit for per-line metadata because lines are moved through history with `memmove`/`memcpy` in helpers such as `grid_scroll_history`, `grid_scroll_history_region`, and `grid_move_lines`.
- `cmd-capture-pane.c` interprets `-S` and `-E` relative to `gd->hsize`, then reads with `grid_string_cells` and `grid_peek_line`. Existing `capture-pane` output has no stable line identity.
- `control.c` emits `%output` and `%extended-output` from pane evbuffer data, not from the grid. `cmd-refresh-client.c` handles `refresh-client -A '%pane:on|off|pause|continue'`.
- `tmux.1` is the protocol contract. Check it before changing command syntax, formats, or control-mode notifications.

## Whisp Integration Context

Whisp lives at `../ai-whisperer` and depends heavily on tmux control mode. Before changing tmux behavior for Whisp, read:

- `../ai-whisperer/AGENTS.md`
- `../ai-whisperer/.claude/skills/whisp/whisp-tmux-integration/SKILL.md`
- `../ai-whisperer/.claude/skills/whisp/whisp-tmux-integration/references/whisp-bridge.md`
- `../ai-whisperer/.claude/skills/whisp/whisp-tmux-integration/references/control-mode.md`
- `../ai-whisperer/mirror-backend/tmux_bridge.py`
- `../ai-whisperer/mirror-backend/tmux_server.py`
- `../ai-whisperer/mirror-backend/remote_tmux.py`
- `../ai-whisperer/mirror-backend/tmux_decode.py`

Current Whisp model:

- Hidden attached control-mode client for queries and notifications.
- Separate hidden control-mode client for input.
- `read-only,ignore-size` on the query/control channel; `ignore-size` on the input channel.
- Live pane bytes arrive through `%output`, enabled per pane with `refresh-client -A '%<pane>:on'`.
- Pane snapshots are built with `capture-pane -p -e`, sometimes with `-S -<lines> -E -` to seed client scrollback.
- Pane input is sent with `send-keys -H -t <pane>`.
- Whisp assumes notifications do not appear inside `%begin/%end/%error` response blocks and that `%output` data remains octal-escaped as documented.

Do not break existing `%output`, `capture-pane`, target syntax, client sizing, or attached-control-client semantics. Fork extensions are additive and opt-in unless the user explicitly decides otherwise.

The fork advertises its compatibility surface through
`#{whisp_tmux_protocol_version}`; bump it whenever the control-mode or format
surface Whisp depends on changes, and update Whisp's paired compatibility gate
in the same change set.

## Line Identity (shipped)

Pane-local immutable line IDs are implemented and load-bearing: Whisp
scrollback hydration anchors on them (`whisp-capture-pane`, the line-id
capture/format paths). When touching grid, screen-write, or reflow code,
preserve these invariants:

- IDs are per `struct window_pane`, monotonic, never global and never shared
  across panes; identity lives on `struct grid_line` and moves with the line
  into history.
- `hsize`, visible row coordinates, copy-mode coordinates, and
  `capture-pane -S/-E` semantics are unchanged; line identity is exposed only
  through the dedicated capture/format paths, never by altering existing
  `capture-pane -p` output.
- `wp->base` is the primary terminal screen; status screens, mode screens, and
  callback-only screens do not consume pane line numbers.
- Regression sweep when these paths change: two panes get independent
  monotonic sequences; IDs survive scrollback movement and history trimming;
  wrap, explicit LF, CR overwrite, clear/reset, resize/reflow, and alternate
  screen behave as documented; existing `capture-pane`, copy mode, and
  `%output` remain compatible.

<!-- gitnexus:start -->
## GitNexus — Code Intelligence

This repo is indexed as **tmux**. Optional MCP tools over the call/import graph — not a default step for every edit.

**Useful when** the hard part is multi-file structure a single grep or file read will not show:
- Who calls / depends on a symbol across modules → `gitnexus_impact` / `gitnexus_context`
- How a concept is wired end-to-end → `gitnexus_query`
- Multi-file rename of a symbol with many graph refs → `gitnexus_rename`

**Skip for** local or non-graph work: known path or string, single-file edits, HTML/CSS/markup, copy, configs, fixtures, generated files, tests you already have open. Prefer normal editor tools there. One graph query that answers the question is enough — do not chain impact/context by habit.

If a tool says the index is stale *and* you still need graph answers, run `npx gitnexus analyze`. Otherwise ignore staleness.

Deeper guides (exploring, impact analysis, debugging, refactoring, tools reference, CLI): `.claude/skills/gitnexus/`.

<!-- gitnexus:end -->
