"""Grades a Futoshiki solver built from TASK.md, through its --json command line.

    python3 -I grade.py WORKSPACE [--puzzles DIR] [--out result.json]

The puzzles are the owner's solved set (futoshiki-puzzle-solver/tests by
default); the agent never sees them. Each solution is checked by an
independent validator, and the basic solver's node count must match this
file's reference count, under either reading of "attempts an assignment":
every value tried, or only the consistent ones.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

DEFAULT_PUZZLES = os.path.expanduser("~/cosc-projects/futoshiki-puzzle-solver/tests")

# One file per validation rule in the task. Each must come back "invalid".
MALFORMED = {
    "missing-inequalities-heading": "SIZE\n4\nGIVENS\n1,1,2\n",
    "bad-integer": "SIZE\n4\nGIVENS\n1,x,2\nINEQUALITIES\n",
    "value-out-of-range": "SIZE\n4\nGIVENS\n1,1,5\nINEQUALITIES\n",
    "cell-out-of-range": "SIZE\n4\nGIVENS\n5,1,1\nINEQUALITIES\n",
    "duplicate-in-row": "SIZE\n4\nGIVENS\n1,1,2\n1,3,2\nINEQUALITIES\n",
    "duplicate-in-column": "SIZE\n4\nGIVENS\n1,1,3\n4,1,3\nINEQUALITIES\n",
    "repeated-cell": "SIZE\n4\nGIVENS\n2,2,1\n2,2,1\nINEQUALITIES\n",
    "not-adjacent": "SIZE\n4\nGIVENS\nINEQUALITIES\n1,1,<,1,3\n",
    "diagonal": "SIZE\n4\nGIVENS\nINEQUALITIES\n1,1,<,2,2\n",
    "bad-operator": "SIZE\n4\nGIVENS\nINEQUALITIES\n1,1,=,1,2\n",
    "bad-size": "SIZE\nfour\nGIVENS\nINEQUALITIES\n",
}

# Comments, blank lines and an empty GIVENS section are all legal.
EMPTY_GIVENS = "# no givens\n\nSIZE\n3\n\nGIVENS\nINEQUALITIES\n1,1,<,1,2\n1,2,<,1,3\n"

BASIC_CAP = 2_000_000  # beyond this the reference count is skipped (timeouts allowed)


def parse(text):
    """Lenient reference parser for the known-good puzzle files."""
    n, givens, ineq, section = None, {}, [], None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line in ("SIZE", "GIVENS", "INEQUALITIES"):
            section = line
            continue
        parts = [p.strip() for p in line.split(",")]
        if section == "SIZE":
            n = int(line)
        elif section == "GIVENS":
            r, c, v = map(int, parts)
            givens[(r - 1, c - 1)] = v
        elif section == "INEQUALITIES":
            ineq.append(((int(parts[0]) - 1, int(parts[1]) - 1), parts[2], (int(parts[3]) - 1, int(parts[4]) - 1)))
    return n, givens, ineq


def valid_solution(puzzle, grid):
    n, givens, ineq = puzzle
    if not isinstance(grid, list) or len(grid) != n or any(not isinstance(row, list) or len(row) != n for row in grid):
        return False, "grid is not N×N"
    want = set(range(1, n + 1))
    for i in range(n):
        if set(grid[i]) != want:
            return False, f"row {i + 1} is not a permutation of 1..{n}"
        if {grid[r][i] for r in range(n)} != want:
            return False, f"column {i + 1} is not a permutation of 1..{n}"
    for (r, c), v in givens.items():
        if grid[r][c] != v:
            return False, f"given ({r + 1},{c + 1})={v} changed"
    for (a, op, b) in ineq:
        x, y = grid[a[0]][a[1]], grid[b[0]][b[1]]
        if not (x < y if op == "<" else x > y):
            return False, f"clue {a} {op} {b} broken"
    return True, ""


def reference_basic(puzzle, cap=BASIC_CAP):
    """Row-major, ascending basic backtracking. Returns (tried, assigned, solved) or None past the cap."""
    n, givens, ineq = puzzle
    grid = [[0] * n for _ in range(n)]
    for (r, c), v in givens.items():
        grid[r][c] = v
    clues = {}
    for (a, op, b) in ineq:
        clues.setdefault(a, []).append((b, op))
        clues.setdefault(b, []).append((a, ">" if op == "<" else "<"))
    cells = [(r, c) for r in range(n) for c in range(n) if (r, c) not in givens]
    tried = assigned = 0

    def ok(r, c, v):
        for k in range(n):
            if (k != c and grid[r][k] == v) or (k != r and grid[k][c] == v):
                return False
        for (o, op) in clues.get((r, c), ()):
            w = grid[o[0]][o[1]]
            if w and not (v < w if op == "<" else v > w):
                return False
        return True

    # Givens that clash between themselves make the puzzle unsolvable outright.
    for (r, c), v in givens.items():
        grid[r][c] = 0
        if not ok(r, c, v):
            return 0, 0, False
        grid[r][c] = v

    def go(i):
        nonlocal tried, assigned
        if i == len(cells):
            return True
        r, c = cells[i]
        for v in range(1, n + 1):
            tried += 1
            if tried > cap:
                raise OverflowError
            if not ok(r, c, v):
                continue
            assigned += 1
            grid[r][c] = v
            if go(i + 1):
                return True
            grid[r][c] = 0
        return False

    sys.setrecursionlimit(10000)
    try:
        solved = go(0)
    except OverflowError:
        return None
    return tried, assigned, solved


def run_cli(workspace, path, solver, timeout=None, limit=120):
    cmd = [sys.executable, "futoshiki.py", path, "--solver", solver, "--json"]
    if timeout is not None:
        cmd += ["--timeout", str(timeout)]
    started = time.perf_counter()
    try:
        p = subprocess.run(cmd, cwd=workspace, capture_output=True, text=True, timeout=limit)
    except subprocess.TimeoutExpired:
        return {"error": f"no answer within {limit}s"}, time.perf_counter() - started
    wall = time.perf_counter() - started
    if "Traceback" in p.stderr:
        return {"error": "crashed: " + p.stderr.strip().splitlines()[-1]}, wall
    try:
        out = json.loads(p.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": f"stdout is not one JSON object (exit {p.returncode}): {p.stdout[-200:]!r}"}, wall
    if p.returncode != 0:
        out["error"] = f"exit code {p.returncode}"
    return out, wall


def difficulty(name):
    m = re.match(r"(\d+)x\d+-(\w+)", name)
    return m.group(2) if m else ""


def grade(workspace, puzzles_dir):
    checks = []

    def check(group, name, passed, detail=""):
        checks.append({"group": group, "name": name, "pass": bool(passed), "detail": detail})

    # Deliverables.
    for f in ("futoshiki.py", "README.md", "REPORT.md"):
        check("deliverables", f, os.path.isfile(os.path.join(workspace, f)))
    own = os.path.join(workspace, "puzzles")
    names = os.listdir(own) if os.path.isdir(own) else []
    for size in ("4x4", "6x6", "8x8"):
        check("deliverables", f"own {size} puzzle", any(size in n.lower() for n in names))
    check("deliverables", "own unsolvable puzzle", any("unsolv" in n.lower() for n in names))
    check("deliverables", "own malformed puzzle", any("malform" in n.lower() or "invalid" in n.lower() for n in names))
    sources = ""
    for root, _, files in os.walk(workspace):
        if "/." in root:
            continue
        for f in files:
            if f.endswith(".py"):
                with open(os.path.join(root, f), errors="replace") as fh:
                    sources += fh.read()
    banned = [lib for lib in ("constraint", "ortools", "pysat", "z3", "pulp", "python_constraint") if re.search(rf"^\s*(import|from)\s+{lib}\b", sources, re.M)]
    check("deliverables", "no CSP/SAT libraries", not banned, ", ".join(banned))
    check("deliverables", "uses tkinter", re.search(r"^\s*(import|from)\s+tkinter", sources, re.M))
    check("deliverables", "solve_with_backtracking", "def solve_with_backtracking" in sources)
    check("deliverables", "solve_with_ac3", "def solve_with_ac3" in sources)

    # The agent's own tests.
    try:
        for extra in ([], ["-s", "tests", "-t", "."]):
            p = subprocess.run([sys.executable, "-m", "unittest", "discover", "-q", *extra], cwd=workspace, capture_output=True, text=True, timeout=300)
            ran = re.search(r"Ran (\d+) test", p.stderr)
            if ran and int(ran.group(1)) > 0:
                break
        check("testing", "own unittest suite passes", p.returncode == 0 and ran and int(ran.group(1)) > 0, (ran.group(0) if ran else p.stderr[-200:]))
    except subprocess.TimeoutExpired:
        check("testing", "own unittest suite passes", False, "over 300s")

    results = []
    hard = []
    files = sorted(f for f in os.listdir(puzzles_dir) if f.endswith(".txt"))
    for f in files:
        path = os.path.join(puzzles_dir, f)
        if f.startswith("malformed"):
            for solver in ("basic", "ac3"):
                out, _ = run_cli(workspace, path, solver)
                check("validation", f"{f} [{solver}] rejected", out.get("status") == "invalid" and "error" not in out, out.get("error") or out.get("status"))
            continue
        with open(path) as fh:
            puzzle = parse(fh.read())
        ref = reference_basic(puzzle)
        if ref is None:
            hard.append(f)
        for solver in ("basic", "ac3"):
            out, wall = run_cli(workspace, path, solver, timeout=60, limit=90)
            status = out.get("status")
            row = {"puzzle": f, "n": puzzle[0], "difficulty": difficulty(f), "solver": solver, "status": status, "time": out.get("time"), "nodes": out.get("nodes"), "wall": round(wall, 3)}
            results.append(row)
            if "error" in out:
                check(solver, f"{f} runs", False, out["error"])
                continue
            expect_solved = ref is None or ref[2]
            if ref is not None and not ref[2]:
                check(solver, f"{f} no_solution", status == "no_solution", status)
            elif solver == "basic" and ref is None:
                check("basic", f"{f} solved or timed out", status in ("solved", "timeout"), status)
            else:
                check(solver, f"{f} solved", status == "solved", status)
            if status == "solved":
                good, why = valid_solution(puzzle, out.get("grid"))
                check(solver, f"{f} solution validates", good, why)
            check(solver, f"{f} reports nodes and time", isinstance(out.get("nodes"), int) and isinstance(out.get("time"), (int, float)))
            if solver == "basic" and ref is not None:
                tried, assigned, _ = ref
                check("basic", f"{f} node count", out.get("nodes") in (tried, assigned), f"got {out.get('nodes')}, want {assigned} (assigned) or {tried} (tried)")
            if solver == "ac3" and ref is not None and expect_solved and isinstance(out.get("nodes"), int) and puzzle[0] >= 6:
                check("ac3", f"{f} fewer nodes than basic", out["nodes"] <= ref[1], f"{out['nodes']} vs basic {ref[1]}")

    # Time-out: a puzzle basic backtracking can't finish, with half a second.
    if hard:
        out, wall = run_cli(workspace, os.path.join(puzzles_dir, hard[0]), "basic", timeout=0.5, limit=30)
        check("basic", "time-out is honoured", out.get("status") == "timeout" and wall < 10, f"{out.get('status')} after {wall:.1f}s")
        check("basic", "time-out reports nodes", isinstance(out.get("nodes"), int) and out.get("nodes", 0) > 0)

    with tempfile.TemporaryDirectory() as tmp:
        for name, text in MALFORMED.items():
            p = os.path.join(tmp, name + ".txt")
            with open(p, "w") as fh:
                fh.write(text)
            out, _ = run_cli(workspace, p, "ac3")
            check("validation", f"rejects {name}", out.get("status") == "invalid" and "error" not in out, out.get("error") or out.get("status"))
        p = os.path.join(tmp, "empty-givens.txt")
        with open(p, "w") as fh:
            fh.write(EMPTY_GIVENS)
        out, _ = run_cli(workspace, p, "basic")
        check("validation", "accepts comments and an empty GIVENS section", out.get("status") == "solved", out.get("error") or out.get("status"))

    groups = {}
    for c in checks:
        g = groups.setdefault(c["group"], [0, 0])
        g[0] += c["pass"]
        g[1] += 1
    return {
        "workspace": workspace,
        "passed": sum(c["pass"] for c in checks),
        "total": len(checks),
        "groups": {k: f"{a}/{b}" for k, (a, b) in groups.items()},
        "checks": checks,
        "results": results,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("workspace")
    ap.add_argument("--puzzles", default=DEFAULT_PUZZLES)
    ap.add_argument("--out")
    args = ap.parse_args()
    report = grade(os.path.abspath(args.workspace), args.puzzles)
    text = json.dumps(report, indent=2)
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text)
    print(f"{report['passed']}/{report['total']} checks  {report['groups']}")
    for c in report["checks"]:
        if not c["pass"]:
            print(f"  FAIL {c['group']}: {c['name']}  {c['detail']}")


if __name__ == "__main__":
    main()
