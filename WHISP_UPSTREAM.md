# Whisp tmux Upstream Updates

This fork uses `master` as the Whisp shipping branch: upstream tmux plus
Whisp-specific protocol, capture, search, and telemetry changes. Keep
`upstream/master` as the untouched tmux source of truth, and bring it forward
through short-lived merge branches.

## Branch Flow

Use a dated branch for each update:

```sh
git fetch --prune origin upstream
git switch master
git pull --ff-only origin master
git switch -c merge/upstream-YYYY-MM-DD
git merge upstream/master
```

Use merge commits, not rebases. The merge commit records exactly when Whisp
picked up upstream tmux. Do not push to `upstream`.

If the merge has conflicts, preserve Whisp-specific public surfaces unless the
user explicitly decides to change them:

- `#{whisp_tmux_protocol_version}`
- `whisp-capture-pane`
- `whisp-search-history`
- Whisp control-mode and `%output` compatibility
- immutable pane-local line numbering and Whisp activity formats

Accept upstream changes where they do not weaken those surfaces. If upstream
changes touch grid, screen write, control mode, formats, or capture/search
commands, validate the Whisp behavior with runtime probes before committing any
manual conflict resolution.

## Pre-Merge Inspection

Before merging, check the shape of the update:

```sh
git rev-list --left-right --count upstream/master...master
git log --oneline --decorate --max-count=20 master..upstream/master
git merge-tree --write-tree --messages master upstream/master
```

`git merge-tree --write-tree` is non-mutating and should exit 0 for a conflict
free forecast. If it reports conflicts, inspect those paths before starting the
real merge.

After merging, inspect the resulting branch:

```sh
git status --short --branch
git diff --stat master..HEAD
git diff --check
```

Keep agent-local untracked files such as `.claude/`, `.gemini/`, and `scripts/`
out of commits unless the user explicitly asks to track them.

## tmux Validation

Build from the merged tree:

```sh
sh autogen.sh
./configure --enable-utf8proc
make
```

Run focused regressions:

```sh
TEST_TMUX=$PWD/tmux sh regress/capture-pane-line-numbers.sh
TEST_TMUX=$PWD/tmux sh regress/search-history.sh
TEST_TMUX=$PWD/tmux sh regress/capture-pane-hyperlink.sh
TEST_TMUX=$PWD/tmux sh regress/decrqm-sync.sh
TEST_TMUX=$PWD/tmux sh regress/control-client-sanity.sh
```

Also run a private-socket smoke test that verifies:

- `#{whisp_tmux_protocol_version}` reports the expected protocol.
- `capture-pane -p -L` still returns upstream line-numbered output.
- `whisp-capture-pane -L` returns immutable Whisp line IDs.
- `whisp-search-history` finds retained pane content and reports line IDs.
- a basic control-mode attach still emits escaped `%output`.

Always kill the private test server when the probe exits.

## Whisp Validation

Whisp lives at `../ai-whisperer`. Do not touch unrelated Whisp working tree
changes. When validating this tmux binary, pass it explicitly:

```sh
cd ../ai-whisperer/mirror-backend
AIWHISPERER_TMUX=/Users/karl/src/tmux/tmux ../.venv/bin/python -m unittest \
    tests.test_tmux_server \
    tests.test_tmux_bridge_main_session \
    tests.test_whisp_host_cli
../.venv/bin/python -m py_compile \
    tmux_bridge.py \
    whisp_host/tmux.py \
    whisp_host/doctor.py \
    whisp_host/cli.py
```

For dev dogfooding without restarting the primary Whisp tmux server, use
Whisp's additional dev source:

```sh
cd ../ai-whisperer
make mac-combined-run-tmux-dev
```

Use `make mac-combined-run-tmux-dev-restart` only when intentionally restarting
the separate `whisp-tmux-dev` socket.

## Commit, Push, and Cleanup

Before committing or pushing, run:

```sh
git diff --check
npx gitnexus detect-changes -r tmux --scope unstaged
```

If validation passes, commit any documentation or conflict-resolution changes on
the merge branch, push it, and open a draft PR to `master` unless the user asks
to merge directly:

```sh
git push -u origin merge/upstream-YYYY-MM-DD
```

After the branch is merged into `master` and pushed, delete the merged update
branch locally and remotely:

```sh
git branch -d merge/upstream-YYYY-MM-DD
git push origin --delete merge/upstream-YYYY-MM-DD
```
