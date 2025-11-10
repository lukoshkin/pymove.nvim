local config = require "sort.config"
local sort = require "sort"

-- Create user commands
vim.api.nvim_create_user_command("PySortClass", function()
  sort.sort_class()
end, {
  desc = "Sort methods in Python class at cursor",
})

vim.api.nvim_create_user_command("PySortFile", function()
  sort.sort_file()
end, {
  desc = "Sort all functions and methods in Python file",
})

vim.api.nvim_create_user_command("PySortMethods", function(opts)
  local scope = opts.args
  if scope == "" then
    scope = "class"
  end
  sort.sort_python(scope)
end, {
  nargs = "?",
  complete = function()
    return { "visual", "class", "file" }
  end,
  desc = "Sort Python functions/methods with scope (visual|class|file)",
})

-- Setup keymaps if enabled
-- Support both old default_keymaps flag and new keymaps structure
local enable_keymaps = config.options.default_keymaps
local keymaps = config.options.keymaps

-- For backward compatibility: if default_keymaps is true and keymaps isn't set,
-- use default keymap values
if enable_keymaps and not keymaps then
  keymaps = {
    sort_class = "<Space>mc",
    sort_file = "<Space>mm",
    sort_visual = "<Space>m",
  }
end

if keymaps and keymaps ~= false then
  if keymaps.sort_class then
    vim.keymap.set("n", keymaps.sort_class, function()
      sort.sort_class()
    end, {
      desc = "Sort methods in current Python class",
      buffer = false,
    })
  end

  if keymaps.sort_file then
    vim.keymap.set("n", keymaps.sort_file, function()
      sort.sort_file()
    end, {
      desc = "Sort all functions/methods in Python file",
      buffer = false,
    })
  end

  if keymaps.sort_visual then
    vim.keymap.set("v", keymaps.sort_visual, function()
      sort.sort_visual()
    end, {
      desc = "Sort Python functions/methods in selection",
      buffer = false,
    })
  end
end
