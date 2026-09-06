# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**pymove.nvim** is a Neovim plugin for Python development that provides two core features:
1. **Move** - Refactor module/package locations with automatic import updates
2. **Sort** - Intelligently organize functions and class methods with dependency-aware sorting

## Development Commands

This project uses Python for testing. Use `uv` for package management.

### Testing
```bash
# Run test file to verify sorting behavior
uv run python test_sorting.py

# Run specific test file in src/
uv run python src/test_data.py
```

### Code Quality
```bash
# Type checking (mypy strict mode enabled, except for tests)
uv run mypy lua/  # Note: Primarily Lua, limited Python

# Lint Lua code (if configured)
uv run ruff check  # For Python test files
```

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
   - `filesystem.lua` - File operations and git integration
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
2. Convert file paths to Python dotted names (e.g., `src/utils.py` → `src.utils`)
3. Use ripgrep to find all files with matching import patterns
4. Show interactive preview with per-file diffs
5. Apply accepted changes: move file (with `git mv` if in repo) + update imports
6. Display progress bar during bulk import updates

**Preview System:**
- Creates a custom floating window with syntax highlighting
- Tracks three states per change: pending → accepted → declined
- Allows per-file approval/rejection
- Rewrites accepted import lines in place (no external `patch` binary)

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
- File discovery in `lua/move/utils.lua` (see `file_change_pattern()`) -- regex
  passed to ripgrep. Over-matching only costs a parse; under-matching means a
  silently stale import, so err wide.
- Statement matching in `lua/move/imports.lua` (`find_matches()`) -- the single
  place both the preview and the direct path get their matches from.
- Rewriting in `lua/move/refactor.lua` (`rewrite_import_lines()`), which applies
  edits right-to-left and verifies each span's text before touching it.

### Import Forms Handled

`lua/move/imports.lua` is the single matcher; `lua/move/preview/collector.lua`
and `update_imports_direct()` both call `find_matches()` rather than carrying
their own query. It walks `import_statement` / `import_from_statement` fields in
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

A relative import whose importer is itself inside the moved subtree is left
alone. That is correct only when the move keeps the same parent package (a
rename, or moving a package within its parent), because the target travelled
with it. It is **wrong** for a cross-package move: after moving `src/utils.py`
to `other/helpers.py`, a `from .sibling import x` inside it now resolves against
`other`, not `src`. See the "Not handled" list below.

**Local bindings are preserved by aliasing.** `from . import utils` binds the
name `utils`; renaming the module would rebind it and break every `utils.foo()`
in the file. So a rename emits `from src import helpers as utils`. A pure
relocation needs no alias (the tail is unchanged), and an explicit alias is
already binding-safe. Every synthesized alias is reported through
`lua/move/report.lua` -- a quickfix list (`:copen`, then `:cdo`) plus a
`$TMPDIR/pymove-aliases-*.txt` file of `file:line:old:new` for external tools.

**Absolute spelling is gated on the package chain.** Dotted names are derived
from the path relative to the project root, but that root is found by `.git` /
`pyproject.toml`, which in a src layout sits one level above the importable
package -- so `src/mypkg/utils.py` is called `src.mypkg.utils` while Python
knows it as `mypkg.utils`. `report.resolve_strategy()` checks every directory
between the root and the module for `__init__.py`; when the chain is broken it
falls back to `"preserve"` for that move and says why, rather than writing an
import that cannot resolve. Imports with no relative form are still written
absolutely and are called out in the same warning. Proper import-root detection
is tracked separately in issue #3.

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
- A move that lands the module at the project root, where `from X import Y`
  would have to become `import Y`.

**Not handled** (silently skipped, no user warning):
- `from pkg import module` where `module` itself is the thing being moved and
  `pkg` is a package rather than a relative prefix -- see issue #2. The relative
  form (`from . import module`) *is* handled; `utils.rename_from_import()` is
  the shared seam that issue #2 extends.
- Dotted names are derived from the filesystem root rather than the import
  root, so a src layout names `src/mypkg/utils.py` as `src.mypkg.utils` instead
  of `mypkg.utils` -- issue #3. `resolve_strategy()` guards the rewrite; it does
  not fix discovery or matching.
- The moved code's own outward relative imports. Moving `src/pkg` to
  `other/pkg` leaves `from ..util import f` inside it pointing at the old
  parent, and moving the single module `src/utils.py` to `other/helpers.py`
  leaves its own `from .sibling import x` pointing at `other.sibling`. These
  files are usually not even in the ripgrep discovery set, so no warning fires.

### Testing Changes

Python test files in `src/test_data.py` and `test_sorting.py` contain example code for testing sorting behavior:
- Mixed module-level and class-level code
- Dependency chains between functions
- Various method naming conventions

Run sorting commands on these files to verify behavior.

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
  byte span with Lua file IO, so applying does not depend on `patch(1)`, a writable temp
  directory, or fuzzy context matching

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

src/                 # Python test data
test_sorting.py      # Test file for sorting
```
