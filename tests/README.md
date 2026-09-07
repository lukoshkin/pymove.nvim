# Tests

```bash
sh tests/run.sh                     # full acceptance suite
sh tests/run.sh operation           # operation contract only
sh tests/run.sh import_root         # root resolution only
PYMOVE_TEST_VERBOSE=1 sh tests/run.sh # keep the plugin's own logging
```

The wrapper disables user configuration, swap files and ShaDa, and puts logs
and cache in a fresh temporary directory printed at startup. It leaves that
directory available for diagnosis. Set `NVIM=/path/to/nvim` to choose a binary;
the runner prints Neovim, Python and ripgrep versions and the parser location.
The underlying `nvim -l tests/run.lua [spec]` entry point also remains available.

Requires Neovim 0.11+, `python3`, `rg`, the Python treesitter parser, and
plenary.nvim. Plenary is looked up in the usual plugin-manager directories; set
`PLENARY_PATH` if yours lives somewhere else. Install the parser with
`:TSInstall python` into Neovim's runtime path. The runner does not download
dependencies. Missing prerequisites fail startup; Python checks never count
as passed or skipped when Python is unavailable. Interpreter failures print
their output. Exit status is zero only when every assertion passes.

For AppImage installations on machines without FUSE, extract the AppImage into
a temporary directory and point `NVIM` at its extracted `usr/bin/nvim`.

## Layout

| File | Contents |
|---|---|
| `run.lua` | Entry point and spec selection |
| `run.sh` | Configuration-free invocation with temporary logs/cache |
| `helpers.lua` | Fixture writing, assertions, the CPython check |
| `fixtures.lua` | The project layouts, one function per shape |
| `import_root_spec.lua` | Where a dotted name starts, and the arithmetic on it |
| `move_spec.lua` | Whole moves, checked by resulting files and by CPython |
| `operation_spec.lua` | Preview/direct equivalence, executable behavior, and failure boundaries |

## Acceptance contract

| Case | Required result |
|---|---|
| Module rename under a project path containing spaces | Both paths rewrite imports and preserve exercised bindings |
| Same-parent package rename | Preview and direct produce identical trees that Python imports |
| Cross-root module move without relative imports in the moved file | Both paths produce the same importable tree |
| Preview toggled to preserve relative spelling | Matches the direct `relative_imports="preserve"` result |
| Move declined, selected import accepted | Only the accepted edit is written |
| No importers | Both paths can move the source |
| Cross-package move containing relative imports in moved code | Refused with the original tree intact |
| The same move under a path containing a comma | Refused identically; punctuation cannot disable the guard |
| Package rename whose moved code names the package relatively | Rewritten to follow the rename; imports that travel with the subtree or reach outside it are left alone |
| Discovery/parser/preparation failure | Refused with the original tree intact |
| Stale accepted preview spans | Refused before any move or importer write |
| Source rename failure | Failure returned; importers unchanged |
| Write fails after preparation | Failure returned; the failed importer is not truncated |

Late I/O failure is **not** a whole-operation rollback: the source may already
have moved and other importers may already have been rewritten. Each importer
is staged and replaced individually. The command reports failure and the files
that need recovery; this suite does not claim crash durability or a transaction
across the project.

This is the stabilization gate. For changes to these behaviors, run the full
suite, review failures against this table, and add a failing reproduction before
fixing a contract violation. Broader import inference, mixed spellings, vendored
trees, and additional import forms remain separate work. A passing gate does
not establish support for every Python refactoring.

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
- **`self_reference`** — a package whose modules reach a sibling by climbing out
  and naming the package on the way back in. `from ..old.util import VALUE` and
  `from .util import VALUE` reach the same module, but only the second survives
  a rename of the package: the first re-descends through a name that no longer
  exists. A rule that asks only whether the importer moves leaves it stale and
  still reports success. The fixture carries all three shapes at once — the
  stranded one, one that travels with the subtree, and one that reaches outside
  it — because the cheap fix for the first breaks the other two.
- **`wide`** — the scan-count guard. Resolving a root costs one project scan per
  candidate; importers must add none, or a move goes quadratic in the tree.

A fixture directory containing a space is deliberate: an unquoted search root
with `--no-messages` returns nothing instead of erroring, which silently drops
every count to zero and flips the answer. A directory containing a comma is
deliberate for the same reason one level up: `globpath()` reads its first
argument as a list, so the comma made the relocation guard scan nothing and
approve a move it exists to refuse. Both are failures that return an empty
result rather than an error, which is why they need a fixture rather than a
code review.

## Adding a case

Put the layout in `fixtures.lua` with a comment saying which reading it forces,
then assert against it. When a bug turns up in the wild, add the layout that
reproduces it before fixing — and check the new assertion fails against the
unfixed code, since an assertion that cannot fail is worse than none.
