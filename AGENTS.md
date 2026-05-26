# Agents

# Core Engineering Mandates

- **Simplicity & Iteration:** Write the simplest code that solves the problem. Do not optimize prematurely. Work in small, reversible, verifiable iterations rather than attempting massive, single-pass changes, especially in terminal state handling.
- **Empirical Validation:** Code that has not been executed is assumed broken. For tmux behavior, validate with a built `tmux` binary, targeted shell/control-mode sessions, and focused regressions rather than relying only on inspection.
- **Root Cause Proof:** Never claim a bug is fixed without identifying the exact root cause. If a change merely makes behavior disappear, treat that as unresolved until the controlling mechanism is isolated.
- **Honesty Over Agreement:** Report the actual technical state. If a requested direction conflicts with tmux invariants or Whisp's integration model, say so clearly and propose a safer path.
- **Circuit Breaker:** If a fix fails repeatedly, or creates a nearby regression, stop and reassess the model of pane input, screen write state, grid history, and control-mode output before stacking speculative changes.

## Commit and Branch Policy

- Do not commit or push until builds/checks pass and the user explicitly approves.
- For behavior changes, passing builds is not enough: reproduce or exercise the changed behavior with a targeted runtime validation before committing. If validation cannot be done from the agent environment, ask for explicit approval before any checkpoint commit.
- For substantial work, use a feature branch.
- Keep unrelated local files out of commits. This worktree may contain agent-local files such as `.claude/`, `.gemini/`, `CLAUDE.md`, `TMUX.md`, and scripts; do not clean up or revert files unrelated to the task.
- Remotes should be: `origin` as `git@github.com:lehenbauer/tmux.git` and `upstream` as `https://github.com/tmux/tmux.git`.

## Build and Validation

- Normal build from a clean checkout is:
  - `sh autogen.sh`
  - `./configure`
  - `make`
- Release tarballs may already have generated configure files, but this repo checkout may need `autogen.sh`.
- Targeted regressions live in `regress/`. The scripts expect `TEST_TMUX` or default to `../tmux`; examples:
  - `TEST_TMUX=$PWD/tmux sh regress/control-client-sanity.sh`
  - `TEST_TMUX=$PWD/tmux sh regress/capture-pane-sgr0.sh`
  - `cd regress && make` for the full shell regression set when the local make supports this BSD-style Makefile.
- For control-mode or pane-output changes, always exercise a real tmux server with a private socket name, for example `./tmux -Ltest -f/dev/null ...`, and kill the test server afterward.
- For scrollback/grid changes, include runtime checks for wrap, explicit linefeed, clear/reset, resize/reflow, alternate screen, and pane isolation when those paths are in scope.

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

Do not break existing `%output`, `capture-pane`, target syntax, client sizing, or attached-control-client semantics. New line identity features should be additive and opt-in unless the user explicitly decides otherwise.

## Current Mission: Immutable Pane-Local Line Numbers

The first planned tmux change is to add an immutable line number to each line of terminal text received, distinct per terminal pane/PTY.

Constraints:

- Do not redefine `hsize`, visible row coordinates, copy-mode coordinates, or `capture-pane -S/-E` semantics. The newest visible line may remain coordinate `0` in existing APIs.
- Line numbers must be per `struct window_pane`, not global across the server and not shared across panes.
- Preserve existing behavior for normal tmux users unless a new command, format, or control-mode extension explicitly exposes the new IDs.
- Treat `wp->base` as the primary terminal screen. Status screens, mode screens, and callback-only screens should not silently consume pane line numbers.
- Decide and document semantics for initial blank visible lines, CR overwrites, wrapped lines, alternate screen, clear/reset, history trimming, resize/reflow, and panes created from non-PTY input before coding.

Likely implementation shape to investigate:

- Add a monotonically increasing counter to `struct window_pane`, for example `next_line_number`, because pane identity owns the sequence.
- Add a line ID field to `struct grid_line` so identity moves with the line when grid lines are copied or moved into history.
- Assign IDs only through pane-aware paths or explicit helper calls. Avoid hiding pane-specific numbering inside generic grid helpers unless ownership is passed in deliberately.
- Audit `screen_write_start_pane`, `screen_write_linefeed`, `screen_write_scrollup`, `screen_write_cell`, `screen_write_clear*`, `screen_write_reset`, `grid_scroll_history`, `grid_scroll_history_region`, `grid_empty_line`, `grid_clear_lines`, `grid_move_lines`, `screen_resize_y`, `screen_reflow`, `grid_reflow`, `screen_alternate_on`, and `screen_alternate_off`.
- Expose IDs later through a dedicated format, capture option, or new command path rather than changing existing `capture-pane -p` text output.

Minimum future validation for line numbering:

- Two panes receive output; each pane gets an independent monotonic sequence.
- Lines retain IDs after scrollback movement and history trimming.
- Wrapping, explicit LF, CR overwrite, and clear/reset produce documented ID behavior.
- Resize/reflow preserves or remaps IDs according to documented semantics.
- Alternate-screen applications do not corrupt the normal-screen sequence.
- Existing `capture-pane`, copy mode, and control-mode `%output` behavior remain compatible.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **tmux**. Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.
- Before editing a symbol that looks load-bearing (exported API, called from many places, referenced in a hot execution flow), run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and surface HIGH/CRITICAL findings to the user. Skip this for cosmetic/local edits (copy, styling, single-file refactors, layout) where the blast radius is obvious.
- Use `gitnexus_rename` instead of find-and-replace for renames — it understands the call graph and avoids missed references.

## Never Do

- NEVER rename symbols with find-and-replace across the repo — use `gitnexus_rename`.
- NEVER ignore a HIGH or CRITICAL impact finding silently — at minimum, mention it to the user before proceeding.

## Optional diagnostics

- `gitnexus_detect_changes()` can show which symbols and flows your edits touched. Useful when you're unsure of the scope of your changes; `git diff` covers the common case.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/tmux/context` | Codebase overview, check index freshness |
| `gitnexus://repo/tmux/clusters` | All functional areas |
| `gitnexus://repo/tmux/processes` | All execution flows |
| `gitnexus://repo/tmux/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
