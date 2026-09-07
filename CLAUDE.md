# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**pymove.nvim** is a Neovim plugin for Python development that provides two core features:
1. **Move** - Refactor module/package locations with automatic import updates
2. **Sort** - Intelligently organize functions and class methods with dependency-aware sorting

## Development Commands

The implementation and test harness are Lua. CPython checks the rewritten
fixture projects; no Python dependency installation is needed.

### Testing
```bash
# Full move acceptance suite (Neovim, plenary, Python parser, rg, python3)
sh tests/run.sh
# Focused operation regressions
sh tests/run.sh operation
```

### Code Quality
```bash
# Lua lint, scoped to the changed Lua files
luacheck <changed-lua-files> --globals vim --no-max-line-length --no-unused-args
```

Use Lua tooling for implementation checks. Ruff and mypy do not check Lua.

### Plugin Development
```bash
# Test plugin in Neovim (from Neovim)
:source lua/pymove/init.lua
:PySortClass  # Test sorting
:PyMoveUI     # Test refactoring
```

## High-Level Architecture

### Module Structure

The plugin is organized into three main Lua modules:

1. **`lua/pymove/`** - Main entry point and plugin coordinator
   - `init.lua` - Plugin setup, calls into sort and move modules
   - `config.lua` - Configuration management

2. **`lua/sort/`** - Python code sorting functionality
   - `init.lua` - Public API for sorting operations
   - `parser.lua` - Treesitter-based Python AST parsing
   - `sorter.lua` - Topological sorting and categorization logic
   - `commands.lua` - Vim command registration
   - `config.lua` - Sort-specific configuration

3. **`lua/move/`** - Module refactoring and import updates
   - `init.lua` - Main refactoring API
   - `imports.lua` - Treesitter import matching, shared by the preview and the
     direct path (see "Import Forms Handled")
   - `refactor.lua` - Import update logic using ripgrep
   - `filesystem.lua` - Import-root resolution, file operations, git integration
   - `utils.lua` - Path/module name conversions
   - `commands.lua` - Vim command registration
   - `preview/` - Interactive preview UI subsystem
     - `init.lua` - Preview orchestration
     - `window.lua` - Buffer and window management
     - `collector.lua` - Change collection logic
     - `state.lua` - Preview state management
     - `apply.lua` - Applying accepted changes
     - `keymaps.lua` - Preview window keybindings
     - `highlight.lua` - Syntax highlighting

### Key Design Patterns

**Sorting Algorithm:**
- Uses treesitter queries to parse Python AST
- Categorizes methods: dunder (`__init__`) → public → private (`_helper`)
- Preserves special methods like `__init__` at the top
- For module-level functions: builds dependency graph and performs topological sort using Kahn's algorithm
- Applies changes incrementally, re-parsing after each modification

**Refactoring Workflow:**
1. Validate source exists and destination is available
2. Resolve source and destination dotted names from their import roots
3. Use ripgrep to find all files with matching import patterns
4. Show interactive preview with per-file diffs
5. Check proposed edits before moving, then move and replace each importer's bytes
6. Display progress bar during bulk import updates

**Preview System:**
- Creates a custom floating window with syntax highlighting
- Tracks three states per change: pending → accepted → declined
- Allows per-file approval/rejection
- Validates accepted spans before moving; stages each importer replacement

### Dependencies

**External:**
- **plenary.nvim** - Lua utilities (Path, logging, async)
- **treesitter** - Python parser (`:TSInstall python`)
- **ripgrep** - Fast file searching (`rg` command)
- **git** (optional) - History-preserving file moves

**Internal:**
- Plugin communicates between modules via `require()`
- Shared logger via `plenary.log`
- Configuration flows: user opts → `pymove.config` → module-specific configs

## Implementation Notes

### Adding New Sorting Categories

Modify `lua/sort/sorter.lua`:
- Update `categorize()` function to recognize new patterns
- Adjust `config.options.categories` order in `lua/sort/config.lua`
- The sorter respects the category order defined in config

### Extending Refactoring

To add new refactoring patterns:
- Naming in `lua/move/filesystem.lua` (`resolve_move_names()`) -- the one place
  a path becomes a dotted name, and the only place the import root is decided.
  `move.import_root`, or `import_root=` on the command, overrides the
  inference outright and skips its scans.
- File discovery in `lua/move/utils.lua` (see `file_change_pattern()`) -- regex
  passed to ripgrep. Over-matching only costs a parse; under-matching means a
  silently stale import, so err wide.
- Statement matching in `lua/move/imports.lua` (`find_matches()`) -- the single
  place both the preview and the direct path get their matches from.
- Rewriting in `lua/move/refactor.lua` (`rewrite_import_lines()`), which applies
  edits right-to-left and verifies each span's text before touching it.

### Import Forms Handled

`lua/move/imports.lua` is the single matcher. Both command paths collect imports
through `lua/move/preview/collector.lua` before moving the source; the standalone
`update_imports_direct()` API also calls `find_matches()`. The matcher walks
`import_statement` / `import_from_statement` fields in
Lua instead of using a field-constrained query, because the moved module can sit
in either the `module_name:` or the `name:` field, and `module_name:` holds a
`relative_import` node for relative imports but a `dotted_name` for absolute
ones.

Handled:
- `import a.b` / `import a.b as c` / `import a.b, c.d as e`
- `from a.b import c` / `... as d` / `... import *` / parenthesized multi-line
- `from .utils import f`, `from ..pkg.utils import f` -- relative, module in
  `module_name:`. Only that node is rewritten.
- `from . import utils` / `... as u` -- relative, module in `name:`. Both halves
  change, so the whole statement is the rewritten span.

Matching is on whole dotted components (`utils.rename_dotted_prefix`), so moving
`src/utils.py` never touches `src.utils_legacy` or `src_utils`.

A relative import whose importer is inside the moved subtree is left alone only
when it still reaches the same module from where the importer lands. Asking
merely whether the importer moves is not enough: `from ..old.util import VALUE`
inside `pkg/old` climbs out to `pkg` and names the package it just left, so
renaming `pkg/old` to `pkg/new` strands it even though its target travelled
along. `imports.lua` therefore resolves the statement twice -- once from the
importer's current path, once from `importer_destination()` -- and rewrites it
unless the second resolution equals the renamed first. A new relative spelling
is likewise computed from the destination, since that is where the file will
live. Cross-package moves containing relative imports in the
moved code are refused by `imports.validate_relocation()` before mutation. That
guard walks the source with `vim.fs.find` rather than `vim.fn.globpath`, whose
first argument is a comma-separated list of directories -- a comma anywhere in
the path split the source into two that do not exist, and a guard that finds no
files permits everything. This
conservative boundary also rejects inward relative imports that might be safe;
supporting their transformation is separate work. Source files are checked even
when importer discovery would not collect them.

**Local bindings are preserved by aliasing.** `from . import utils` binds the
name `utils`; renaming the module would rebind it and break every `utils.foo()`
in the file. So a rename emits `from src import helpers as utils`. A pure
relocation needs no alias (the tail is unchanged), and an explicit alias is
already binding-safe. Every synthesized alias is reported through
`lua/move/report.lua` -- a quickfix list (`:copen`, then `:cdo`) plus a
`$TMPDIR/pymove-aliases-*.txt` file of `file:line:old:new` for external tools.

**Dotted names come from the import root, not the filesystem root.** Two
different roots are in play and must not be confused. The *filesystem* root
(`filesystem.find_project_root()`, found by `.git` / `pyproject.toml`) scopes
ripgrep and is what command arguments are given against -- those stay paths,
because they tab-complete and say plainly whether a target is a module or a
package. The *import* root is where Python starts counting the name, and in a
src layout it is `src/`, one level below.

**The import root is read off the code, not guessed from the tree.** The package
chain cannot settle it: `src/mypkg/` and a PEP 420 `ns/pkg/` are identical on
disk, and only `sys.path` separates them. What does settle it is how the project
already spells modules there. `filesystem.find_import_root()` scores each
candidate root by how many imports actually use its spelling, and takes the most
frequent. A codebase writing `from mypkg.utils import f` names
`src/mypkg/utils.py` as `mypkg.utils`; one whose tests write
`from src.mypkg.utils import f` names the same file `src.mypkg.utils`. Both are
right, because both match what has to keep working.

Two things keep the count honest. **Candidates stop at the first package**: a
directory carrying an `__init__.py` is part of a name, never where one starts,
and nothing inside a package can be a root either. Without that stop
`mypkg/logging.py` would offer `mypkg` as a candidate whose spelling is the bare
name `logging`, and every `import logging` in the project would vote for it.
**Neighbours are probes too**: a module nobody imports yet carries no evidence,
but the files beside it share its directory and therefore its root, so
`probe_modules()` scores the whole directory rather than one file.

Each side of a move resolves its own root (`filesystem.resolve_move_names()`),
since moving out of `src/` into a flat package changes the root on the way. The
destination has no imports of its own to be recognised by, so it is named from
whatever a module already living around it is named from, and inherits the
source's root when nothing lives there yet. Importers resolve their own root too
(`filesystem.import_relative_path()`), because the relative-import arithmetic in
`utils.absolute_dotted_path()` / `utils.relative_dotted_path()` counts package
components from it -- but `import_relative_path()` never searches. An importer
under a root already settled for the move is named from it, and anything outside
falls back to the package chain: asking how often the project imports a test
module would cost a scan per directory to learn nothing, since nothing imports
it. A move therefore costs one scan per candidate root, not per file.
`filesystem.reset_root_cache()` clears both the per-directory memo and the
settled roots at the start of each operation, and the settled roots are tagged
with the project they came from so a second project in the same session cannot
inherit them.

**Scoring is the expensive part of a move.** Each candidate root costs one
project-wide ripgrep scan, on top of the one discovery spends, so an ordinary
move runs three. Nothing caps what those walk: outside a git repo, or with no
`.gitignore` covering it, a non-hidden `venv/` is scanned like source. Both
roots can therefore be pinned per command -- `import_root=<dir>` and
`project_root=<dir>` on `:PyMove` / `:PyMovePreview`, parsed by
`commands.parse_options()`. `import_root=` is the one that removes scans (three
to one); `project_root=` only narrows what they walk. The pin reaches
`filesystem` through `reset_root_cache(import_root)` and lasts exactly one
operation, outranking `move.import_root`; `""` is a real value meaning the
project root, so it is checked for nil rather than truthiness. An argument that
matches nothing is an error -- a mistyped `import_root=` that silently reverted
to scoring would be indistinguishable from the bug it exists to avoid.

**When no import settles it**, the package chain is the only evidence left:
`structural_import_root()` takes the parent of the topmost ancestor carrying an
`__init__.py`, since a source root's parent is never itself a package, and the
project root when no ancestor is a package at all. That reading is flagged, and
`report.resolve_strategy()` says which way it went, points at `move.import_root`
-- set it to `"src"`, or `""` for the project root, to settle the question
outright -- and falls back to `"preserve"` for the move, since a relative import
is right under either reading.

**Relative-import spelling** is controlled by `move.relative_imports`
(`"absolute"` by default, `"preserve"` to keep a relative form when a valid one
exists). Both spellings are computed once while collecting, so `<C-r>` in the
preview toggles between them as a redraw rather than another pass over the
files. An import written absolutely has no relative candidate and renders the
same either way.

**Reported as needing a manual edit** (shown as an `unfixable` preview entry,
and as a warning listing `file:line` on the non-preview path):
- `from . import a, utils` -- only one name should move; split it first.
- A `from . import ...` statement spanning several lines.
- A move that lands the module at the import root, where `from X import Y`
  would have to become `import Y`.

**Remaining limitations:**
- `from pkg import module` where `module` itself is the thing being moved and
  `pkg` is a package rather than a relative prefix -- see issue #2. The relative
  form (`from . import module`) *is* handled; `utils.rename_from_import()` is
  the shared seam that issue #2 extends.
- A project that spells the same module two ways -- `mypkg.utils` inside the
  package, `src.mypkg.utils` in tests run from the repo root. Only the more
  common spelling is rewritten; the other is named by
  `report.warn_rival_spellings()` and left for a hand edit or a second run with
  `move.import_root` set. Discovery is built from the winning spelling, so those
  files are never even collected.
- Vendored trees. `count_spellings()` scans whatever ripgrep walks, and outside
  a git repo a non-hidden `vendor/` or `venv/` is not ignored, so its imports
  vote on the root alongside the project's own.

**Failure handling:** `move.search` distinguishes no matches from a failed scan
and passes paths as process arguments. Scoring errors, discovery errors, parser
failures and invalid direct-command edits stop before moving. Preview validates
all accepted edits before moving or writing any importer. A stale span refuses
the whole accepted set. A move with no importers is valid in both paths.

The writer stages each importer beside its destination, checks write/close
results, preserves permissions, and replaces it with a filesystem rename.
Failures return an error instead of counting as an update. This is per-file
replacement, not project-wide rollback: a late failure can leave the source
moved and other importers updated. Only successful edits enter alias reports.

### Testing Changes

**Move/import rewriting** has an automated suite -- `sh tests/run.sh`,
exit status 0 only when everything passes. It writes a throwaway Python project
per case, runs real moves against it, and checks the result by importing the
rewritten tree with required `python3`, and exercises selected call sites to
check preserved bindings. `tests/README.md` defines the acceptance boundary and
explains what each fixture layout is for; the short
version is that they are not variety but the specific shapes that broke a
version of the import-root rules, several of them pairs no rule can separate
from the directory tree alone.

When a move bug turns up, add the layout that reproduces it to
`tests/fixtures.lua` first, and confirm the new assertion fails against the
unfixed code -- an assertion that cannot fail is worse than none.

**Sorting** has no automated suite. `src/test_data.py` and `test_sorting.py`
hold example code -- mixed module- and class-level definitions, dependency
chains, various naming conventions -- to run the sort commands against by hand.

### Preview Window Internals

The preview system (`lua/move/preview/`) collects changes, then rewrites them in place:
- Each change records: file, line_num, old_import, new_import, both relative and
  absolute candidates, context, treesitter `node_range`
- State machine tracks user decisions (pending/accepted/declined), plus
  `unfixable` for matches that cannot be rewritten automatically -- those cannot
  be accepted and are never applied
- `<C-r>` toggles the relative-import spelling by re-rendering from the
  candidates already on each change
- Only accepted changes are applied when user confirms
- `update_specific_imports_direct()` in `lua/move/refactor.lua` edits the exact `node_range`
  byte span with Lua file IO, stages the replacement beside the importer, and
  uses a filesystem rename. It does not depend on `patch(1)` or fuzzy matching.

## Common Workflows

### Debugging Plugin Issues
```vim
" Enable verbose logging
:set verbose=9
:messages  " View logs

" Check if treesitter parser is loaded
:TSInstall python
:checkhealth nvim-treesitter
```

### Manual Import Updates
The `move.refactor` module can be used standalone:
```lua
local refactor = require("move.refactor")
refactor.update_imports_direct(
  "/path/to/file.py",
  "old.module.path",
  "new.module.path",
  "/project/root"
)
```

### Customizing Sort Behavior
All sorting options are in `lua/sort/config.lua`:
- `preserve_methods` - Methods kept at top
- `categories` - Sort order
- `sort_within_categories` - Alphabetical sorting
- `enable_dependency_sort` - Topological sort for functions

## Important Constraints

- **Neovim version**: Requires 0.11+ for latest treesitter APIs
- **Python treesitter**: Must be installed or parsing will fail
- **Git detection**: Auto-detects `.git` directory for `git mv` support
- **Ripgrep requirement**: Move functionality requires `rg` command
- **Single-file edits**: Sorter applies changes one class/function at a time, re-parsing after each to maintain correctness

## File Organization

```
lua/
├── pymove/          # Main plugin coordinator
│   ├── init.lua
│   └── config.lua
├── sort/            # Sorting functionality
│   ├── init.lua
│   ├── parser.lua
│   ├── sorter.lua
│   ├── commands.lua
│   └── config.lua
└── move/            # Refactoring functionality
    ├── init.lua
    ├── imports.lua   # Treesitter import matching (shared)
    ├── refactor.lua
    ├── filesystem.lua
    ├── utils.lua
    ├── commands.lua
    └── preview/     # Interactive preview UI
        ├── init.lua
        ├── window.lua
        ├── collector.lua
        ├── state.lua
        ├── apply.lua
        ├── keymaps.lua
        └── highlight.lua

tests/               # Move/import test suite (sh tests/run.sh)
├── run.sh
├── run.lua
├── helpers.lua
├── fixtures.lua     # Project layouts, one per shape that broke a rule
├── import_root_spec.lua
├── move_spec.lua
└── operation_spec.lua

src/                 # Python test data for sorting
test_sorting.py      # Test file for sorting
```
