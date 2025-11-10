local config = require "pymove.config"

local M = {}

---Setup function called by lazy.nvim or user
---@param opts PyMoveConfig?
function M.setup(opts)
  -- Setup config first
  config.setup(opts)

  -- Always load sorting functionality (it's the core feature)
  if config.options.sorting then
    -- Convert the unified config to the format expected by sort module
    local sort_opts = vim.tbl_extend("force", config.options.sorting, {
      -- Map the new keymap structure to the old default_keymaps flag
      default_keymaps = config.options.sorting.keymaps ~= false,
    })

    require("sort").setup(sort_opts)
  end

  -- Load move/rename functionality if configured
  if config.options.move then
    require("move.commands").setup(config.options.move)
  end
end

-- Re-export sorting functions for backward compatibility
M.sort_class = function()
  require("sort").sort_class()
end

M.sort_file = function()
  require("sort").sort_file()
end

M.sort_visual = function()
  require("sort").sort_visual()
end

M.sort_python = function(scope)
  require("sort").sort_python(scope)
end

return M
