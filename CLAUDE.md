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
