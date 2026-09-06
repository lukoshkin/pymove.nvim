# Tests

```bash
nvim -l tests/run.lua              # everything
nvim -l tests/run.lua import_root  # one spec
PYMOVE_TEST_VERBOSE=1 nvim -l tests/run.lua   # keep the plugin's own logging
```

Exit status is 0 only when every assertion passes, so this drops into CI as-is.

Requires `nvim`, `rg`, the python treesitter parser (`:TSInstall python`), and
plenary.nvim. Plenary is looked up in the usual plugin-manager directories; set
`PLENARY_PATH` if yours lives somewhere else. `python3` is optional — without it
the interpreter checks report as skipped rather than failing.

## Layout

| File | Contents |
|---|---|
| `run.lua` | Entry point and spec selection |
| `helpers.lua` | Fixture writing, assertions, the CPython check |
| `fixtures.lua` | The project layouts, one function per shape |
| `import_root_spec.lua` | Where a dotted name starts, and the arithmetic on it |
| `move_spec.lua` | Whole moves, checked by resulting files and by CPython |

Every case writes a fresh project under `vim.fn.tempname()`. That is not
tidiness: a move rewrites its fixture in place, so a suite that shared one would
pass on the first run and fail on the second for reasons unrelated to the code.

## What the fixtures are for

They are not assorted variety. Each one is a layout that broke a version of the
import-root rules, and several are pairs that no rule can tell apart from the
directory tree alone:

- **`src` vs `src_dotted`** — byte-identical trees. One codebase writes
  `from mypkg.utils import f`, the other `from src.mypkg.utils import f`. Both
  spellings are legal and each is correct for its own project, so the resolver
  has to follow the imports rather than the filesystem.
- **`src` vs `ns_wrapping`** — a source root and a PEP 420 namespace package are
  the same shape on disk; only `sys.path` separates them.
- **`stdlib_clash`** — `mypkg/logging.py` in a project that also imports the
  stdlib `logging`. If a package directory is ever offered as a candidate root,
  this module's spelling becomes the bare name `logging`, every ordinary
  `import logging` votes for it, and the move rewrites the stdlib import
  everywhere. The more common the collision, the more confident the wrong answer.
- **`fresh_module`** — a module nothing imports yet. Evidence about the file
  itself is empty; its neighbours carry it.
- **`deep`** — `a/` is a package, so `a/b` cannot be a source root. Decidable
  from the tree, and a rule that stops at the first missing `__init__.py` while
  walking up gets it wrong.
- **`ns_top`, `ns_dir`** — nothing absolute to learn from, so these exercise the
  package-chain fallback and the report that says the answer was inferred.
- **`wide`** — the scan-count guard. Resolving a root costs one project scan per
  candidate; importers must add none, or a move goes quadratic in the tree.

A fixture directory containing a space is deliberate: an unquoted search root
with `--no-messages` returns nothing instead of erroring, which silently drops
every count to zero and flips the answer.

## Adding a case

Put the layout in `fixtures.lua` with a comment saying which reading it forces,
then assert against it. When a bug turns up in the wild, add the layout that
reproduces it before fixing — and check the new assertion fails against the
unfixed code, since an assertion that cannot fail is worse than none.
