#!/usr/bin/env python3
"""whisp-pane-planner: minimal-disturbance pane creation and deletion for tmux.

Philosophy: splitting should not shrink existing panes, and closing should not
grow them. When the geometry allows it, this tool grows or shrinks the tmux
*window* instead:

  split  - if the target pane spans the full window height (for a side-by-side
           split) or width (for a stacked split), the window grows by the new
           pane's size and every existing pane keeps its exact geometry.
           Otherwise falls back to a plain tmux split of the target pane.
  close  - if the doomed pane spans the full window height or width, the
           window shrinks and every survivor keeps its exact geometry.
           Otherwise the hole is absorbed by the panes along one edge
           (or both, with --policy balanced); only those panes change.

Mechanism (no tmux patches required): batched stock commands. tmux's
select-layout applies an exact computed layout string and resizes the window
to it (layout-custom.c); resize-window pins window-size=manual so the size
sticks; pane SIGWINCHes are coalesced by the server's resize queue
(server-client.c). Because select-layout assigns panes to layout cells in
pane-LIST order (ignoring the ids embedded in the string), a snap that
restructures the tree is followed by swap-pane fixups computed here.

Refusals: zoomed windows and windows containing whisp floating panes are not
snapped (a select-layout round-trip would flatten floating panes); the tool
performs the plain tmux operation instead and says so.

Usage:
  whisp-pane-planner.py split h [-l 80] [-t %3] [--dry-run] [--no-grow]
  whisp-pane-planner.py split v [-l 24] [-t %3]
  whisp-pane-planner.py close [-t %3] [--policy auto|balanced|left|right|up|down]
  whisp-pane-planner.py check [-t @1]
  whisp-pane-planner.py fuzz [--ops 200] [--seed N] [--tmux /path/to/tmux]

Example daily-driver bindings (~/.tmux.conf):
  bind '"' run-shell "whisp-pane-planner.py split v -t '#{pane_id}'"
  bind %   run-shell "whisp-pane-planner.py split h -t '#{pane_id}'"
  bind x   run-shell "whisp-pane-planner.py close -t '#{pane_id}'"

Standalone snapshot kept in the tmux fork for rebase smoke-testing
(see WHISP_UPSTREAM.md). The canonical copy ships with whisp:
ai-whisperer/mirror-backend/whisp_pane_planner.py — fix bugs there first.
"""

import argparse
import contextlib
import fcntl
import hashlib
import io
import os
import random
import re
import subprocess
import sys
from dataclasses import dataclass, field, replace

PANE_MINIMUM = 1
WINDOW_MAXIMUM = 10000


class TmuxError(RuntimeError):
    pass


class PlanError(RuntimeError):
    pass


# ---------------------------------------------------------------- tmux plumbing

class Tmux:
    def __init__(self, binary="tmux", socket_name=None, socket_path=None,
                 no_user_config=False):
        self.binary = binary
        self.socket_name = socket_name
        self.socket_path = socket_path
        self.no_user_config = no_user_config

    def _argv(self):
        argv = [self.binary]
        if self.socket_name:
            argv += ["-L", self.socket_name]
        if self.socket_path:
            argv += ["-S", self.socket_path]
        if self.no_user_config:
            argv += ["-f", "/dev/null"]
        return argv

    def batch(self, cmds, check=True):
        """Run a list of commands as ONE tmux invocation, ';'-separated so all
        layout mutations land in a single server dispatch."""
        argv = self._argv()
        for i, cmd in enumerate(cmds):
            if i:
                argv.append(";")
            argv += cmd
        proc = subprocess.run(argv, capture_output=True, text=True)
        if check and proc.returncode != 0:
            raise TmuxError("tmux %s failed: %s"
                            % (" ".join(cmd[0] for cmd in cmds), proc.stderr.strip()))
        return proc.stdout

    def run(self, *cmd, check=True):
        return self.batch([list(cmd)], check=check)


@dataclass
class Rect:
    id: str          # '%3', or 'NEW' for a planned but not yet created pane
    x: int
    y: int
    w: int
    h: int
    floating: bool = False


@dataclass
class WinState:
    window: str      # '@1'
    width: int
    height: int
    zoomed: bool
    layout: str
    panes: list      # Rect, in w->panes list order (list-panes order)


def read_state(t, target):
    out = t.run("display-message", "-p", "-t", target,
                "#{window_id} #{window_width} #{window_height} "
                "#{window_zoomed_flag} #{window_layout}").split()
    window, width, height, zoomed, layout = out
    panes = []
    fmt = "#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{pane_floating_flag}"
    for line in t.run("list-panes", "-t", window, "-F", fmt).splitlines():
        pid, x, y, w, h, fl = line.split()
        panes.append(Rect(pid, int(x), int(y), int(w), int(h), fl == "1"))
    return WinState(window, int(width), int(height), zoomed == "1", layout, panes)


def resolve_pane(t, spec):
    """Resolve a pane spec to (pane_id, window_id)."""
    out = t.run("display-message", "-p", "-t", spec,
                "#{pane_id} #{window_id}").split()
    return out[0], out[1]


@contextlib.contextmanager
def server_lock(t):
    """Serialize planner mutations per tmux server. Concurrent pane-died
    hooks (two agents exiting at once) would otherwise interleave phase 1
    and phase 2 and force both snaps to degrade; under remain-on-exit the
    later death just waits here and plans from fresh state. flock is
    released by the OS even if we crash."""
    key = t.socket_path or t.socket_name \
        or os.environ.get("TMUX", "").split(",")[0] or "default"
    path = "/tmp/whisp-pane-planner-%s.lock" \
        % hashlib.sha1(key.encode()).hexdigest()[:12]
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


# ---------------------------------------------------------------- layout strings

def layout_checksum(body):
    csum = 0
    for ch in body:
        csum = ((csum >> 1) + ((csum & 1) << 15) + ord(ch)) & 0xFFFF
    return "%04x" % csum


@dataclass
class Cell:
    x: int
    y: int
    w: int
    h: int
    kind: str                    # 'leaf' | 'lr' | 'tb'
    pane: str = None             # leaf only: '%N'
    children: list = field(default_factory=list)


_GEOM = re.compile(r"(\d+)x(\d+),(\d+),(\d+)")
_ID = re.compile(r",(\d+)")


def parse_layout(s):
    csum, body = s.split(",", 1)
    if layout_checksum(body) != csum:
        raise PlanError("layout checksum mismatch")
    cell, rest = _parse_cell(body)
    if rest:
        raise PlanError("trailing garbage in layout: %r" % rest)
    return cell


def _parse_cell(s):
    m = _GEOM.match(s)
    if not m:
        raise PlanError("bad layout cell at %r" % s[:24])
    w, h, x, y = (int(g) for g in m.groups())
    s = s[m.end():]
    if s[:1] in "{[":
        opener = s[0]
        closer, kind = ("}", "lr") if opener == "{" else ("]", "tb")
        children = []
        s = s[1:]
        while True:
            child, s = _parse_cell(s)
            children.append(child)
            if s[:1] == ",":
                s = s[1:]
                continue
            if s[:1] == closer:
                s = s[1:]
                break
            raise PlanError("bad layout container near %r" % s[:24])
        return Cell(x, y, w, h, kind, children=children), s
    m = _ID.match(s)
    if not m:
        raise PlanError("leaf without pane id at %r" % s[:24])
    return Cell(x, y, w, h, "leaf", pane="%" + m.group(1)), s[m.end():]


def serialize_cell(c):
    s = "%ux%u,%u,%u" % (c.w, c.h, c.x, c.y)
    if c.kind == "leaf":
        return s + "," + c.pane[1:]
    opener, closer = ("{", "}") if c.kind == "lr" else ("[", "]")
    return s + opener + ",".join(serialize_cell(ch) for ch in c.children) + closer


def layout_string(root):
    body = serialize_cell(root)
    return layout_checksum(body) + "," + body


def leaves(c):
    if c.kind == "leaf":
        return [c]
    out = []
    for ch in c.children:
        out += leaves(ch)
    return out


# ---------------------------------------------------------------- tree building
#
# Build a layout tree from a set of pane rectangles by recursive guillotine
# cuts. Separators are 1 cell wide: a pane at x..x+w-1 is followed by a
# separator column at x+w. A valid vertical cut c has every rect entirely
# left (end <= c) or entirely right (start >= c+1). Taking ALL cuts at once
# yields n-ary nodes and automatic lr/tb alternation.

def build_tree(rects, x, y, w, h):
    if not rects:
        raise PlanError("empty region")
    if len(rects) == 1:
        r = rects[0]
        if (r.x, r.y, r.w, r.h) != (x, y, w, h):
            raise PlanError("pane %s does not fill its region" % r.id)
        return Cell(x, y, w, h, "leaf", pane=r.id)
    for axis, kind in (("x", "lr"), ("y", "tb")):
        cuts = _find_cuts(rects, axis, x if axis == "x" else y,
                          w if axis == "x" else h)
        if cuts:
            children = []
            for (lo, extent), sub in _partition(rects, axis, cuts,
                                                x if axis == "x" else y,
                                                w if axis == "x" else h):
                if axis == "x":
                    children.append(build_tree(sub, lo, y, extent, h))
                else:
                    children.append(build_tree(sub, x, lo, w, extent))
            return Cell(x, y, w, h, kind, children=children)
    raise PlanError("geometry is not guillotine-partitionable")


def _span(r, axis):
    return (r.x, r.x + r.w) if axis == "x" else (r.y, r.y + r.h)


def _find_cuts(rects, axis, lo, extent):
    candidates = set()
    for r in rects:
        _, end = _span(r, axis)
        if lo < end < lo + extent:
            candidates.add(end)
    cuts = []
    for c in sorted(candidates):
        ok = all(end <= c or start >= c + 1
                 for start, end in (_span(r, axis) for r in rects))
        if ok:
            cuts.append(c)
    return cuts


def _partition(rects, axis, cuts, lo, extent):
    bounds = [lo] + [c + 1 for c in cuts]
    ends = cuts + [lo + extent]
    out = []
    for seg_lo, seg_end in zip(bounds, ends):
        sub = [r for r in rects
               if _span(r, axis)[0] >= seg_lo and _span(r, axis)[1] <= seg_end]
        if not sub:
            raise PlanError("empty segment in partition")
        out.append(((seg_lo, seg_end - seg_lo), sub))
    return out


# ---------------------------------------------------------------- planning

@dataclass
class Plan:
    kind: str        # 'grow-split' | 'shrink-close' | 'absorb-close'
                     # | 'local-split' | 'plain-kill'
    width: int = 0   # final window size (snap plans only)
    height: int = 0
    rects: list = None   # final Rects incl. 'NEW' (snap plans only)
    note: str = ""
    problems: list = None    # post-op verification failures, filled by do_*


def _transpose(r):
    return replace(r, x=r.y, y=r.x, w=r.h, h=r.w)


def plan_split(rects, width, height, target_id, direction, size):
    if direction == "v":
        plan = plan_split([_transpose(r) for r in rects], height, width,
                          target_id, "h", size)
        if plan.rects is not None:
            plan = replace(plan, width=plan.height, height=plan.width,
                           rects=[_transpose(r) for r in plan.rects])
        else:
            plan = replace(plan, note=plan.note.replace("height", "width"))
        return plan

    t = _find(rects, target_id)
    if t.y == 0 and t.h == height:
        new_width = width + size + 1
        if new_width > WINDOW_MAXIMUM:
            return Plan("local-split", note="would exceed WINDOW_MAXIMUM")
        line = t.x + t.w + 1
        out = [replace(r, x=r.x + size + 1) if r.x >= line else replace(r)
               for r in rects]
        out.append(Rect("NEW", line, 0, size, height))
        plan = Plan("grow-split", new_width, height, out)
        if not _snappable(plan):
            return Plan("local-split", note="grow plan not expressible")
        return plan
    return Plan("local-split",
                note="target does not span full %s"
                     % ("height" if direction == "h" else "width"))


def plan_close(rects, width, height, target_id, policy):
    t = _find(rects, target_id)
    others = [replace(r) for r in rects if r.id != target_id]
    if not others:
        return Plan("plain-kill", note="last pane; window will close")

    if t.y == 0 and t.h == height:            # full-height column: shrink
        for r in others:
            if r.x > t.x:
                r.x -= t.w + 1
        plan = Plan("shrink-close", width - t.w - 1, height, others)
    elif t.x == 0 and t.w == width:           # full-width row: shrink
        for r in others:
            if r.y > t.y:
                r.y -= t.h + 1
        plan = Plan("shrink-close", width, height - t.h - 1, others)
    else:
        return _plan_absorb(others, width, height, t, policy)
    if not _snappable(plan):
        return Plan("plain-kill", note="shrink plan not expressible")
    return plan


def _find(rects, target_id):
    for r in rects:
        if r.id == target_id:
            return r
    raise PlanError("pane %s not found in window" % target_id)


def _edge_set(others, hole, side):
    """Panes that exactly tile one edge of the hole, or None."""
    if side == "left":
        cand = [r for r in others if r.x + r.w == hole.x - 1]
    elif side == "right":
        cand = [r for r in others if r.x == hole.x + hole.w + 1]
    elif side == "up":
        cand = [r for r in others if r.y + r.h == hole.y - 1]
    else:
        cand = [r for r in others if r.y == hole.y + hole.h + 1]
    if side in ("left", "right"):
        lo, hi = hole.y, hole.y + hole.h
        cand = [r for r in cand if r.y >= lo and r.y + r.h <= hi]
        spans = sorted((r.y, r.y + r.h) for r in cand)
    else:
        lo, hi = hole.x, hole.x + hole.w
        cand = [r for r in cand if r.x >= lo and r.x + r.w <= hi]
        spans = sorted((r.x, r.x + r.w) for r in cand)
    cur = lo
    for s, e in spans:
        if s != cur:
            return None
        cur = e + 1
    if cur != hi + 1:
        return None
    return cand


def _stretch(rset, hole, side, amount, offset=0):
    """Stretch every pane in rset into the hole from the given side.
    amount is the thickness absorbed (including one separator); offset is
    where the absorbed strip begins, for balanced two-sided absorption."""
    for r in rset:
        if side == "left":
            r.w += amount
        elif side == "right":
            r.x = hole.x + offset
            r.w += amount
        elif side == "up":
            r.h += amount
        else:
            r.y = hole.y + offset
            r.h += amount


def _snappable(plan):
    """A plan is only executable if its geometry is guillotine-partitionable
    (i.e. expressible as a tmux layout tree). Absorbing across a column/row
    boundary can produce a partial-height/width edge that no layout tree can
    represent, so every plan is checked BEFORE the destructive phase 1."""
    try:
        build_tree(sorted(plan.rects, key=lambda r: (r.y, r.x)),
                   0, 0, plan.width, plan.height)
        return True
    except PlanError:
        return False


def _plan_absorb(others, width, height, hole, policy):
    def attempt(side):
        rects = [replace(r) for r in others]
        rset = _edge_set(rects, hole, side)
        if not rset:
            return None
        amount = hole.w + 1 if side in ("left", "right") else hole.h + 1
        _stretch(rset, hole, side, amount)
        return (len(rset),
                Plan("absorb-close", width, height, rects,
                     note="absorb from %s (%d pane%s)"
                          % (side, len(rset), "" if len(rset) == 1 else "s")))

    def attempt_balanced(sides, amount):
        rects = [replace(r) for r in others]
        a = _edge_set(rects, hole, sides[0])
        b = _edge_set(rects, hole, sides[1])
        if not (a and b):
            return None
        k = amount // 2
        _stretch(a, hole, sides[0], k)
        _stretch(b, hole, sides[1], amount - k, offset=k)
        return (len(a) + len(b),
                Plan("absorb-close", width, height, rects,
                     note="balanced %s+%s" % sides))

    if policy in ("left", "right", "up", "down"):
        got = attempt(policy)
        if got is None:
            raise PlanError("cannot absorb from side %r: edge does not tile"
                            % policy)
        if not _snappable(got[1]):
            raise PlanError("absorbing from side %r yields a layout tmux "
                            "cannot express" % policy)
        return got[1]

    candidates = []
    if policy == "balanced":
        for got in (attempt_balanced(("left", "right"), hole.w + 1),
                    attempt_balanced(("up", "down"), hole.h + 1)):
            if got is not None:
                candidates.append(got[1])
    # auto (and balanced fallback): fewest panes disturbed;
    # ties broken left, up, right, down
    sided = []
    for i, side in enumerate(("left", "up", "right", "down")):
        got = attempt(side)
        if got is not None:
            sided.append((got[0], i, got[1]))
    candidates += [plan for _, _, plan in sorted(sided, key=lambda c: c[:2])]
    for plan in candidates:
        if _snappable(plan):
            return plan
    return Plan("plain-kill",
                note="no absorbable edge yields an expressible layout")


# ---------------------------------------------------------------- execution

def compute_swaps(list_order, want):
    """After select-layout, layout cell i holds list_order[i]. Return
    swap-pane (src, dst) pairs so cell i ends up holding want[i]."""
    if sorted(list_order) != sorted(want):
        raise PlanError("pane sets differ: %s vs %s" % (list_order, want))
    arr = list(list_order)
    swaps = []
    for i, wanted in enumerate(want):
        if arr[i] == wanted:
            continue
        j = arr.index(wanted, i + 1)
        swaps.append((arr[i], arr[j]))
        arr[i], arr[j] = arr[j], arr[i]
    return swaps


def snap_commands(t, window, plan):
    """Compute the phase-2 command batch from the CURRENT observed state."""
    state = read_state(t, window)
    root = build_tree(sorted(plan.rects, key=lambda r: (r.y, r.x)),
                      0, 0, plan.width, plan.height)
    want = [leaf.pane for leaf in leaves(root)]
    list_order = [p.id for p in state.panes]
    cmds = [["resize-window", "-t", window,
             "-x", str(plan.width), "-y", str(plan.height)],
            ["select-layout", "-t", window, layout_string(root)]]
    for src, dst in compute_swaps(list_order, want):
        cmds.append(["swap-pane", "-d", "-s", src, "-t", dst])
    return cmds


def guard_snap(state):
    """Return a reason string if this window must not be snapped."""
    if state.zoomed:
        return "window is zoomed"
    if any(p.floating for p in state.panes):
        return "window has floating panes (select-layout would flatten them)"
    return None


def verify_plan(t, window, plan):
    """Read back the window and compare against the plan. tmux can accept our
    commands and still not end up where we planned: a control client's
    refresh-client -C per-window size clamps even manual window sizes
    (resize.c), and after-command hooks or concurrent clients can mutate the
    layout. Never claim success without looking."""
    state = read_state(t, window)
    problems = []
    if (state.width, state.height) != (plan.width, plan.height):
        problems.append("window is %ux%u, planned %ux%u"
                        % (state.width, state.height, plan.width, plan.height))
    planned = {r.id: (r.x, r.y, r.w, r.h) for r in plan.rects}
    actual = {p.id: (p.x, p.y, p.w, p.h) for p in state.panes}
    for pid in sorted(planned.keys() | actual.keys()):
        if planned.get(pid) != actual.get(pid):
            problems.append("pane %s: planned %s, actual %s"
                            % (pid, planned.get(pid), actual.get(pid)))
    return problems


def _snap_and_verify(t, window, plan, did_what):
    """Phase 2: snap, then verify. Returns the plan with .problems filled.
    Phase 1 already happened and cannot be rolled back, so a failed or
    refused snap degrades gracefully to tmux's default result."""
    try:
        t.batch(snap_commands(t, window, plan))
    except (PlanError, TmuxError) as e:
        plan.problems = ["snap skipped: %s" % e]
        print("WARNING: %s, but the snap was skipped (%s); "
              "tmux's default layout stands" % (did_what, e))
        return plan
    plan.problems = verify_plan(t, window, plan)
    if plan.problems:
        print("WARNING: %s, but the result does not match the plan "
              "(a control client's refresh-client -C size pin, a hook, "
              "or a concurrent change?):" % did_what)
        for p in plan.problems:
            print("  - " + p)
    return plan


def do_split(t, args):
    with server_lock(t):
        return _do_split(t, args)


def _do_split(t, args):
    pane, window = resolve_pane(t, args.target)
    state = read_state(t, window)
    size = args.size if args.size is not None \
        else (80 if args.direction == "h" else 24)
    if size < PANE_MINIMUM:
        raise PlanError("size %d is below PANE_MINIMUM (%d)"
                        % (size, PANE_MINIMUM))

    reason = guard_snap(state)
    if reason or args.no_grow:
        plan = Plan("local-split", note=reason or "--no-grow")
    else:
        plan = plan_split(state.panes, state.width, state.height,
                          pane, args.direction, size)

    if plan.kind == "local-split":
        cmd = ["split-window", "-" + args.direction, "-l", str(size),
               "-t", pane]
        if args.dry_run:
            print("local-split (%s): %s" % (plan.note, " ".join(cmd)))
            return
        t.run(*cmd)
        print("local-split: plain tmux split (%s)" % plan.note)
        return

    phase1 = [["resize-window", "-t", window,
               "-x", str(plan.width), "-y", str(plan.height)],
              ["split-window", "-" + args.direction, "-f", "-l", str(size),
               "-t", pane, "-P", "-F", "#{pane_id}"]]
    if args.dry_run:
        print("grow-split: window %ux%u -> %ux%u, new pane %ux%u; phase 1:"
              % (state.width, state.height, plan.width, plan.height,
                 size if args.direction == "h" else plan.width,
                 plan.height if args.direction == "h" else size))
        for cmd in phase1:
            print("  " + " ".join(cmd))
        print("  (phase 2 snap computed after the split exists)")
        return

    new_id = t.batch(phase1).strip().splitlines()[-1]
    plan = replace(plan, rects=[replace(r, id=new_id) if r.id == "NEW" else r
                                for r in plan.rects])
    plan = _snap_and_verify(t, window, plan, "new pane %s created" % new_id)
    if not plan.problems:
        print("grow-split: window %ux%u -> %ux%u; new pane %s; "
              "existing panes undisturbed"
              % (state.width, state.height, plan.width, plan.height, new_id))
    return plan


def do_close(t, args):
    with server_lock(t):
        return _do_close(t, args)


def _do_close(t, args):
    pane, window = resolve_pane(t, args.target)
    state = read_state(t, window)

    reason = guard_snap(state)
    plan = (Plan("plain-kill", note=reason) if reason
            else plan_close(state.panes, state.width, state.height,
                            pane, args.policy))

    if plan.kind == "plain-kill":
        if args.dry_run:
            print("plain-kill (%s): kill-pane -t %s" % (plan.note, pane))
            return
        t.run("kill-pane", "-t", pane)
        print("plain-kill: plain tmux kill-pane (%s)" % plan.note)
        return

    if args.dry_run:
        print("%s: window %ux%u -> %ux%u (%s); planned survivors:"
              % (plan.kind, state.width, state.height,
                 plan.width, plan.height, plan.note or "exact"))
        for r in plan.rects:
            print("  %s %ux%u at %u,%u" % (r.id, r.w, r.h, r.x, r.y))
        return

    t.run("kill-pane", "-t", pane)
    plan = _snap_and_verify(t, window, plan, "pane %s closed" % pane)
    if plan.problems:
        return plan
    if plan.kind == "shrink-close":
        print("shrink-close: window %ux%u -> %ux%u; survivors undisturbed"
              % (state.width, state.height, plan.width, plan.height))
    else:
        touched = _describe_touched(state, plan)
        print("absorb-close (%s): window unchanged; stretched %s"
              % (plan.note, touched or "nothing"))
    return plan


def _describe_touched(state, plan):
    before = {p.id: (p.x, p.y, p.w, p.h) for p in state.panes}
    return ",".join(r.id for r in plan.rects
                    if before.get(r.id) != (r.x, r.y, r.w, r.h))


def do_check(t, args):
    state = read_state(t, args.target)
    window = state.window
    problems = []

    try:
        root = parse_layout(state.layout)
        body = state.layout.split(",", 1)[1]
        if serialize_cell(root) != body:
            problems.append("re-serialization differs from tmux's layout string")
        by_id = {leaf.pane: leaf for leaf in leaves(root)}
        for p in state.panes:
            if p.floating:
                continue
            leaf = by_id.get(p.id)
            if leaf is None:
                problems.append("pane %s missing from layout" % p.id)
            elif (leaf.x, leaf.y, leaf.w, leaf.h) != (p.x, p.y, p.w, p.h):
                problems.append("pane %s: layout says %ux%u@%u,%u, list-panes says %ux%u@%u,%u"
                                % (p.id, leaf.w, leaf.h, leaf.x, leaf.y,
                                   p.w, p.h, p.x, p.y))
        tiled = [p for p in state.panes if not p.floating]
        rebuilt = build_tree(sorted(tiled, key=lambda r: (r.y, r.x)),
                             0, 0, state.width, state.height)
        for leaf in leaves(rebuilt):
            orig = by_id.get(leaf.pane)
            if orig and (leaf.x, leaf.y, leaf.w, leaf.h) != (orig.x, orig.y, orig.w, orig.h):
                problems.append("rebuild mismatch for %s" % leaf.pane)
        traversal = [leaf.pane for leaf in leaves(root)]
        list_order = [p.id for p in state.panes if not p.floating]
        if traversal != list_order:
            print("note: traversal order %s != list order %s (snaps will need swaps)"
                  % (traversal, list_order))
    except PlanError as e:
        problems.append(str(e))

    if problems:
        print("check FAILED for %s:" % window)
        for p in problems:
            print("  - " + p)
        sys.exit(1)
    print("check OK: %s %ux%u, %d panes, layout parses/rebuilds cleanly"
          % (window, state.width, state.height, len(state.panes)))


# ---------------------------------------------------------------- fuzz

def do_fuzz(args):
    seed = args.seed if args.seed is not None else random.randrange(1 << 30)
    rng = random.Random(seed)
    socket = "whisp-planner-fuzz-%d" % os.getpid()
    t = Tmux(args.tmux, socket, no_user_config=True)
    t.run("kill-server", check=False)
    t.run("new-session", "-d", "-s", "fuzz", "-x", "120", "-y", "40")
    print("fuzz: seed=%d ops=%d socket=%s tmux=%s"
          % (seed, args.ops, socket, args.tmux))

    log = []
    stats = {"grow-split": 0, "shrink-close": 0, "absorb-close": 0,
             "local-split": 0, "plain-kill": 0, "shake": 0, "refused": 0}
    try:
        for opno in range(args.ops):
            state = read_state(t, "fuzz")
            npanes = len(state.panes)
            big = state.width > 500 or state.height > 200
            wants_split = npanes == 1 or (not big and npanes < 14
                                          and rng.random() < 0.55)

            if not wants_split and npanes > 1 and rng.random() < 0.15:
                # shake: plain tmux ops that scramble list-vs-traversal order
                victim = rng.choice(state.panes).id
                if rng.random() < 0.5:
                    cmd = ["split-window", "-b",
                           rng.choice(["-h", "-v"]), "-l",
                           str(rng.randint(3, 10)), "-t", victim, "-d"]
                else:
                    other = rng.choice(state.panes).id
                    cmd = ["swap-pane", "-d", "-s", victim, "-t", other]
                log.append("shake: " + " ".join(cmd))
                try:
                    t.run(*cmd)
                    stats["shake"] += 1
                except TmuxError:
                    stats["refused"] += 1
                continue

            if wants_split:
                target = rng.choice(state.panes).id
                direction = rng.choice(["h", "v"])
                size = rng.randint(4, 40)
                ns = argparse.Namespace(target=target, direction=direction,
                                        size=size, dry_run=False,
                                        no_grow=False)
                log.append("split %s %s -l %d" % (direction, target, size))
                try:
                    with contextlib.redirect_stdout(io.StringIO()):
                        plan = do_split(t, ns)
                except TmuxError as e:
                    if "too small" in str(e) or "size" in str(e):
                        stats["refused"] += 1
                        continue
                    raise
            else:
                target = rng.choice(state.panes).id
                policy = rng.choice(["auto", "auto", "balanced",
                                     "left", "right", "up", "down"])
                ns = argparse.Namespace(target=target, policy=policy,
                                        dry_run=False)
                log.append("close %s --policy %s" % (target, policy))
                try:
                    with contextlib.redirect_stdout(io.StringIO()):
                        plan = do_close(t, ns)
                except PlanError as e:
                    stats["refused"] += 1
                    log.append("  refused: %s" % e)
                    continue

            if plan is None or plan.rects is None:
                stats[plan.kind if plan else "local-split"] = \
                    stats.get(plan.kind if plan else "local-split", 0) + 1
                continue
            stats[plan.kind] += 1

            if plan.problems:
                print("fuzz FAILED at op %d (seed %d): post-op verify: %s"
                      % (opno, seed, plan.problems))
                for line in log[-12:]:
                    print("  " + line)
                sys.exit(1)
            after = read_state(t, "fuzz")
            _verify(after, plan, log, opno, seed)
            _verify_layout_roundtrip(after, log, opno, seed)
    finally:
        if args.keep:
            print("fuzz server kept: tmux -L %s attach" % socket)
        else:
            t.run("kill-server", check=False)

    print("fuzz PASSED: %d ops  %s" % (args.ops,
          "  ".join("%s=%d" % kv for kv in sorted(stats.items()))))


def _verify(after, plan, log, opno, seed):
    planned = {r.id: (r.x, r.y, r.w, r.h) for r in plan.rects}
    actual = {p.id: (p.x, p.y, p.w, p.h) for p in after.panes}
    ok = (planned == actual
          and (after.width, after.height) == (plan.width, plan.height))
    if not ok:
        print("fuzz FAILED at op %d (seed %d)" % (opno, seed))
        for line in log[-12:]:
            print("  " + line)
        print("planned window %ux%u panes %s" % (plan.width, plan.height, planned))
        print("actual  window %ux%u panes %s" % (after.width, after.height, actual))
        sys.exit(1)


def _verify_layout_roundtrip(after, log, opno, seed):
    try:
        root = parse_layout(after.layout)
        body = after.layout.split(",", 1)[1]
        assert serialize_cell(root) == body
    except (PlanError, AssertionError) as e:
        print("fuzz FAILED (layout round-trip) at op %d (seed %d): %s"
              % (opno, seed, e))
        for line in log[-12:]:
            print("  " + line)
        sys.exit(1)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tmux", default="tmux", help="tmux binary to use")
    ap.add_argument("-L", dest="socket", default=None,
                    help="tmux socket name (default: $TMUX)")
    ap.add_argument("-S", dest="socket_path", default=None,
                    help="tmux socket path (useful in hooks: -S '#{socket_path}')")
    sub = ap.add_subparsers(dest="cmd", required=True)

    default_pane = os.environ.get("TMUX_PANE", "")

    sp = sub.add_parser("split", help="split without shrinking other panes")
    sp.add_argument("direction", choices=["h", "v"],
                    help="h: side-by-side (grow width); v: stacked (grow height)")
    sp.add_argument("-l", dest="size", type=int, default=None,
                    help="new pane size (default: 80 cols / 24 rows)")
    sp.add_argument("-t", dest="target", default=default_pane)
    sp.add_argument("--no-grow", action="store_true",
                    help="force plain local split")
    sp.add_argument("--dry-run", action="store_true")

    cp = sub.add_parser("close", help="close without growing other panes")
    cp.add_argument("-t", dest="target", default=default_pane)
    cp.add_argument("--policy", default="auto",
                    choices=["auto", "balanced", "left", "right", "up", "down"],
                    help="who absorbs an interior hole (default: auto)")
    cp.add_argument("--dry-run", action="store_true")

    kp = sub.add_parser("check", help="validate parser/geometry for a window")
    kp.add_argument("-t", dest="target", default=default_pane)

    fp = sub.add_parser("fuzz", help="randomized self-test on a private server")
    fp.add_argument("--ops", type=int, default=200)
    fp.add_argument("--seed", type=int, default=None)
    fp.add_argument("--keep", action="store_true",
                    help="leave the fuzz server running")

    args = ap.parse_args()
    t = Tmux(args.tmux, args.socket, args.socket_path)

    try:
        if args.cmd == "split":
            plan = do_split(t, args)
        elif args.cmd == "close":
            plan = do_close(t, args)
        elif args.cmd == "check":
            do_check(t, args)
            plan = None
        elif args.cmd == "fuzz":
            do_fuzz(args)
            plan = None
    except (TmuxError, PlanError) as e:
        print("error: %s" % e, file=sys.stderr)
        sys.exit(1)
    if plan is not None and plan.problems:
        sys.exit(3)


if __name__ == "__main__":
    main()
