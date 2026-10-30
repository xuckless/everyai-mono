Build a Futoshiki puzzle solver in Python in this repository, modelled as a constraint satisfaction problem. Use only the standard library and Tkinter: no ready-made Futoshiki solver and no CSP, SAT or optimization library. Work in the repository root, commit when it's done, and verify it yourself before you say it is.

## The puzzle
An N×N grid. Every cell holds an integer 1..N, each value appears once per row and once per column, fixed values stay as given, and every inequality clue between two adjacent cells holds. `(2,1) < (2,2)` means row 2 column 1 is smaller than the cell to its right.

## CSP model (required)
- One variable X(r,c) per cell. Domains start as {1..N}; a fixed cell's domain is {v}.
- Row and column all-different are decomposed into binary not-equal constraints between every pair of cells in the same row or column.
- Each clue is a directed binary constraint Xi < Xj or Xi > Xj.
- Arcs are directed so REVISE(Xi, Xj) can test whether every value in Di has support in Dj.

## Input format
Plain text, one-based indices; blank lines and lines starting with `#` are ignored. Each section heading must appear even when the section is empty.
```
SIZE
4
GIVENS
1,1,2
2,3,1
INEQUALITIES
1,2,>,1,3
2,4,>,3,4
3,4,>,4,4
```
GIVENS lines are `row,column,value`. INEQUALITIES lines are `row1,column1,operator,row2,column2`, where the operator is `<` or `>` and the two cells are horizontally or vertically adjacent.

Reject, with an informative message and no crash: malformed or missing sections, invalid integers, out-of-range values, duplicate fixed values in a row or column, a cell given twice, non-adjacent inequality endpoints and invalid operators.

## Solvers
1. **Basic backtracking**, `solve_with_backtracking`: recursive; no AC-3, forward checking, MRV, degree or LCV. Assign unfilled cells in row-major order, try values in ascending order, check every row, column, fixed-value and inequality constraint whose values are known before committing, and backtrack as soon as an assignment is inconsistent.
2. **AC-3 enhanced**, `solve_with_ac3`: backtracking combined with propagation.
   - Run AC-3 on the initial domains before search.
   - REVISE(Xi, Xj) removes x from Di when no y in Dj satisfies the constraint. When Di changes, re-enqueue the neighbouring arcs. An empty domain fails the branch.
   - After each tentative assignment, copy or restore domains correctly and run AC-3 on the affected arcs.
   - Choose variables by MRV, break ties with the most-constraining (degree) heuristic, and order values by LCV.
   - Document how domain state is saved and restored.

Both solvers take a configurable time-out (60 s by default) and report solved, no solution, or time-out.

**Measurement.** Count one node each time the solver attempts a value assignment to an unassigned variable. Time with `time.perf_counter()`, from just before solver initialization until a solution, failure or time-out is returned. File selection and GUI rendering are not included.

## GUI (Tkinter)
- A Load button with a file picker; parse, validate and show the puzzle.
- The N×N grid with fixed values and horizontal and vertical clues in their places.
- A choice of Basic Backtracking or AC-3 Enhanced, and a Solve button.
- A status of Solving, Solved, No solution, Invalid puzzle or Time out.
- Solver values look visibly different from fixed values.
- Runtime and nodes visited for every finished or timed-out attempt.
- Solving must not freeze the window.

## Command line (required, used for grading)
`python3 futoshiki.py` with no arguments opens the GUI.

`python3 futoshiki.py PUZZLE.txt --solver basic|ac3 [--timeout SECONDS] --json` solves headlessly. It prints exactly one JSON object to stdout and exits 0 for every handled outcome, including invalid files:
```
{"status": "solved"|"no_solution"|"timeout"|"invalid", "grid": [[1,2,...],...] or null, "nodes": 123, "time": 0.0123, "message": "..."}
```
Without `--json`, print the grid, the total nodes visited and the runtime.

## Testing
- Puzzle files in `puzzles/`: at least one valid 4×4, one 6×6 and one 8×8; at least two difficulty levels among the valid ones; one unsolvable but well-formed puzzle; and one malformed file.
- Check every result independently with a validation function covering completeness, value ranges, row and column uniqueness, fixed values and all inequalities.
- Add automated tests runnable with `python3 -m unittest`.

## Deliverables
- `futoshiki.py` and any modules it uses.
- `puzzles/*.txt`.
- The tests.
- `README.md` with run instructions.
- `REPORT.md`, about 1–2 pages, covering:
  - the CSP formulation
  - both algorithms and how AC-3, MRV, degree and LCV fit together
  - the experimental method (machine, time-out, puzzle set, how difficulty was set)
  - a results table (Puzzle, N, Difficulty, Solver, Status, Time s, Nodes visited) for both solvers on every puzzle, with time-outs marked explicitly
  - a discussion, including why runtime need not follow node count
  - limitations
