---@class SortingConfig
---@field preserve_methods string[] Methods to keep at top (e.g., __init__)
---@field categories string[] Order of method categories
---@field sort_within_categories boolean Sort alphabetically within each category
---@field visual_selection_lexsort boolean Always use lexsort for visual selections
---@field enable_dependency_sort boolean Use topological sort for module functions
---@field module_categories string[]|nil Module-level categories (nil/empty disables module sorting)
---@field put_functions_before_classes boolean|nil Order functions before classes (nil = preserve original order)
---@field keymaps table<string, string>|false Keymaps for sorting (false to disable)

---@class MoveConfig
---@field use_git boolean|nil Auto-detect git by default
---@field import_root string|nil Directory dotted names start from (nil = infer)
---@field relative_imports "absolute"|"preserve" How to rewrite relative imports
---@field keymaps table<string, string>|false Keymaps for moving (false to disable)

---@class PyMoveConfig
---@field sorting SortingConfig|table Configuration for sorting functionality
---@field move MoveConfig|table Configuration for move/rename functionality

local M = {}

---@type PyMoveConfig
M.defaults = {
  sorting = {
    -- Methods that should always stay at the top in their original order
    preserve_methods = { "__init__", "__new__", "__str__", "__repr__" },

    -- Order of categories for sorting (first to last)
    categories = { "dunder", "public", "private" },

    -- Sort alphabetically within each category
    sort_within_categories = false,

    -- Always use lexicographic sorting for visual selections
    visual_selection_lexsort = true,

    -- Enable topological sorting for module-level functions
    -- (respects dependencies between functions)
    enable_dependency_sort = true,

    -- Module-level sorting categories
    -- Categories: "constants" (module-level assignments), "public" (no underscore),
    --            "utility" (single underscore), "private" (double underscore)
    -- Set to nil or {} to disable module-level sorting
    module_categories = { "constants", "public", "utility" },

    -- Order functions before classes at module level
    -- true: functions always before classes
    -- false: classes always before functions
    -- nil: preserve original function/class order (only sort by category)
    put_functions_before_classes = nil,

    -- Keymaps for sorting functionality
    -- Set to false to disable all keymaps
    keymaps = {
      sort_class = "<Space>mc", -- Sort methods in current class
      sort_file = "<Space>mm", -- Sort all functions/methods in file
      sort_visual = "<Space>m", -- Sort functions/methods in visual selection
    },
  },

  move = {
    -- Git integration (nil = auto-detect)
    use_git = nil,

    -- Directory that dotted names are counted from, relative to the project
    -- root -- "src" for a src layout, "" for the project root itself.
    -- nil infers it from how the codebase already spells its imports, which
    -- is right whenever any absolute import of the module exists. Set this
    -- when pymove says it could not tell -- or to make a move faster, since
    -- inferring costs one project-wide scan per candidate root and this
    -- costs none. `import_root=` on a command pins it for that move alone.
    import_root = nil,

    -- How to rewrite an import that was written relatively
    --   "absolute" - always emit a full dotted path
    --   "preserve" - keep it relative when a valid relative form exists
    -- Toggle per preview with <C-r>
    relative_imports = "absolute",

    -- Keymaps for move/rename functionality
    -- Set to false to disable all keymaps
    keymaps = {
      move_ui = "<Space>mr", -- Interactive move/rename with UI
    },
  },
}

-- Populated with the defaults up front so consumers can read options whether or
-- not `setup()` has run
---@type PyMoveConfig
M.options = vim.deepcopy(M.defaults)

---Merge user options with defaults
---@param opts PyMoveConfig?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
