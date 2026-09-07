# PyMove - Module Refactoring

A Neovim plugin for intelligently moving and renaming Python modules/packages with automatic import updates across your entire project.

## Features

- **Smart refactoring**: Move or rename Python files/packages
- **Automatic import updates**: Rewrites supported import forms across the project
- **Git integration**: Auto-detects git and uses `git mv` when available
- **Interactive preview**: Visual preview with per-file change approval
- **Dependency tracking**: Finds all files affected by the move
- **Safe operations**: Validates moves before execution

## Requirements

- Neovim 0.11+
- Python treesitter parser: `:TSInstall python`
- ripgrep (`rg`) for fast file searching
- plenary.nvim

## Usage

### Commands

- `:PyMove <old_path> <new_path> [--git|--no-git]` - Move module/package directly
- `:PyMovePreview <old_path> <new_path> [--git|--no-git]` - Preview changes before applying
- `:PyMoveUI` - Interactive move with prompts and preview

### Default Keymap

- `<Space>mr` - Interactive move/rename with UI

### Lua API

```lua
local move = require("move")

-- Move with automatic import updates
move.move_module_or_package(
  "old/module.py",
  "new/location/module.py",
  nil,  -- project_root (nil = auto-detect)
  { use_git = true }
)

-- Preview changes before applying
move.preview_move(
  "old/module.py",
  "new/location/module.py"
)

-- Interactive move with UI prompts
move.move_with_ui()
```

## Interactive Preview

The preview window shows:

- File operation summary (`git mv` or regular move)
- All affected files with import changes
- Line-by-line diff for each file
- Context lines around each change

### Preview Keymaps

**Navigation:**
- `<C-n>` - Jump to next change
- `<C-p>` - Jump to previous change

**Actions:**
- `<Space>` - Toggle status (pending → accepted → declined)
- `<C-a>` / `<Alt-a>` - Accept all pending changes
- `<C-r>` - Toggle how relative imports are rewritten (absolute ⇄ preserve)

**Finalize:**
- `q` - Apply accepted changes and close
- `<Esc>` - Cancel without applying

**Help:**
- `?` - Show/hide help window

## Examples

### Moving a Single Module

```bash
# Move src/old.py to src/utils/new.py
:PyMovePreview src/old.py src/utils/new.py
```

**Before:**
```python
# other_file.py
from src.old import MyClass
```

**After:**
```python
# other_file.py
from src.utils.new import MyClass
```

### Moving a Package

```bash
# Move entire package
:PyMovePreview src/old_package src/new_package
```

Updates all imports:
```python
# Before
from src.old_package import module
from src.old_package.submodule import Class

# After
from src.new_package import module
from src.new_package.submodule import Class
```

### Dry Run

```lua
local move = require("move")

-- Check what would be changed without applying
move.move_module_or_package(
  "old/module.py",
  "new/module.py",
  nil,
  { dry_run = true }
)
```

## How It Works

1. **Validation**: Checks if source exists and destination is available
2. **Discovery**: Finds all Python files that import the module
3. **Analysis**: Calculates import path transformations
4. **Preview**: Shows interactive diff of all changes
5. **Preparation**: Checks proposed spans and file access before moving or rewriting
6. **Execution**:
   - Moves file/directory (using `git mv` if in git repo)
   - Stages and replaces each affected importer's contents
7. **Result**: Reports updates or a failure

Both command paths collect imports before moving the source. Preview also
allows a move with no matching importers. Discovery and parser failures stop
the operation; no matches is a valid result. Stale accepted preview spans stop
the entire accepted set before modification.

Cross-package moves containing relative imports anywhere in the moved code
are currently refused. Convert those imports to absolute form first. This
includes inward relative imports that could be safe but have not been covered
by the cross-package transformation. Same-parent renames remain supported.

Each importer replacement preserves permissions and avoids truncating the
original file on a failed write. This is not a transaction across the project:
an I/O failure after the source moves can leave other files already updated.
The command reports failure; inspect `:messages` and your diff before recovery.
For preview, declining the move or individual imports intentionally applies
only your accepted subset and can require manual follow-up.

Mixed import spellings, vendored trees influencing inference, and
`from pkg import module` when moving that module remain limitations. The
bounded acceptance cases and test command are in [tests/README.md](../../tests/README.md).

## Git Integration

- Auto-detects if project is in a git repository
- Uses `git mv` for tracked files (preserves history)
- Falls back to regular filesystem operations for non-git projects
- Can be explicitly controlled with `--git` or `--no-git` flags

## Configuration

Configure via the main pymove plugin:

```lua
{
  dir = "~/.config/evangelist/pymove",
  name = "pymove.nvim",
  ft = "python",
  opts = {
    move = {
      -- Git integration (nil = auto-detect)
      use_git = nil,

      -- How to rewrite an import that was written relatively:
      --   "absolute" - always emit a full dotted path (default)
      --   "preserve" - keep it relative when a valid relative form exists
      -- Toggle per preview with <C-r>.
      -- "absolute" falls back to "preserve" when the resolver reports an
      -- inferred import root; a warning explains the assumption.
      relative_imports = "absolute",

      -- Keymaps (false to disable)
      keymaps = {
        move_ui = "<Space>mr",
      },
    },
  },
}
```

Disable keymaps and set custom ones:

```lua
opts = {
  move = {
    keymaps = false,  -- Disable defaults
  },
},
keys = {
  { "<leader>pm", function() require("move").move_with_ui() end,
    desc = "Python move/rename module" },
}
```

## Preview Window Customization

The preview window uses custom highlight groups that you can override:

- `PyMoveHeader` - Section headers and borders (default: blue, bold)
- `PyMoveFileOperation` - File operation line (default: yellow, bold)
- `PyMoveOldImport` - Old import statements (default: red background)
- `PyMoveNewImport` - New import statements (default: green background)
- `PyMoveAccepted` - Accepted changes marker (default: green, bold)
- `PyMoveDeclined` - Declined changes marker (default: red, bold)
- `PyMoveContext` - Context lines (default: dim gray)

## License

MIT
