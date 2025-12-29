local api = vim.api

local M = {}

---Complete Python file paths relative to project root
---@param arglead string Current argument being completed
---@param cmdline string Full command line
---@param curpos integer Cursor position
---@return string[] Completion candidates
local function complete_python_paths(arglead, cmdline, curpos)
  local filesystem = require "move.filesystem"
  local project_root = filesystem.find_project_root()

  -- Count how many arguments we have
  local args = vim.split(cmdline, "%s+", { trimempty = true })
  local arg_count = #args - 1 -- Subtract command name
  if cmdline:match "%s$" then
    arg_count = arg_count + 1
  end

  -- For 3rd+ arguments, complete flags
  if arg_count >= 3 then
    local flags = { "--no-git", "--git", "--ignore-swap" }
    return vim.tbl_filter(function(flag)
      return flag:find("^" .. vim.pesc(arglead))
    end, flags)
  end

  -- For 1st and 2nd arguments, complete Python files
  local pattern = arglead .. "*.py"
  local candidates = vim.fn.glob(pattern, false, true)

  -- Also check for directories (potential packages)
  local dir_pattern = arglead .. "*/"
  local dirs = vim.fn.glob(dir_pattern, false, true)

  -- Combine and make paths relative to project root
  for _, dir in ipairs(dirs) do
    table.insert(candidates, dir)
  end

  -- Remove leading ./ if present
  for i, path in ipairs(candidates) do
    candidates[i] = path:gsub("^%./", "")
  end

  return candidates
end

---Setup commands and keymaps for move functionality
---@param opts MoveConfig
function M.setup(opts)
  opts = opts or {}

  -- Lazy-load the move module to avoid circular dependency
  local move = require "move"

  -- Create user commands
  api.nvim_create_user_command("PyMove", function(cmd_opts)
    local args = vim.split(cmd_opts.args, " ", { trimempty = true })
    if #args < 2 then
      vim.notify(
        "Usage: :PyMove <old_path> <new_path> [--no-git|--git]",
        vim.log.levels.ERROR
      )
      return
    end

    local old_name, new_name = args[1], args[2]
    local options = {}

    for i = 3, #args do
      if args[i] == "--no-git" then
        options.use_git = false
      elseif args[i] == "--git" then
        options.use_git = true
      end
    end

    move.move_module_or_package(old_name, new_name, nil, options)
  end, {
    nargs = "*",
    desc = "Move Python module/package and update imports directly",
    complete = complete_python_paths,
  })

  api.nvim_create_user_command("PyMovePreview", function(cmd_opts)
    local args = vim.split(cmd_opts.args, " ", { trimempty = true })
    if #args < 2 then
      vim.notify(
        "Usage: :PyMovePreview <old_path> <new_path> [--no-git|--git] [--ignore-swap]",
        vim.log.levels.ERROR
      )
      return
    end

    local old_name, new_name = args[1], args[2]
    local options = {}

    for i = 3, #args do
      if args[i] == "--no-git" then
        options.use_git = false
      elseif args[i] == "--git" then
        options.use_git = true
      elseif args[i] == "--ignore-swap" then
        options.ignore_swap = true
      end
    end

    move.preview_move(old_name, new_name, nil, options)
  end, {
    nargs = "*",
    desc = "Preview Python module/package move with interactive UI",
    complete = complete_python_paths,
  })

  api.nvim_create_user_command("PyMoveUI", function()
    move.move_with_ui()
  end, {
    desc = "Interactive Python module/package move",
  })

  -- Setup keymaps if enabled
  if opts.keymaps and opts.keymaps ~= false then
    if opts.keymaps.move_ui then
      vim.keymap.set("n", opts.keymaps.move_ui, function()
        move.move_with_ui()
      end, {
        desc = "Interactive Python module/package move",
        buffer = false,
      })
    end
  end
end

return M
