local api = vim.api
local fn = vim.fn

local M = {}

local FLAGS = { "--no-git", "--git", "-b", "--backup" }
local KWARGS = { "import_root=", "project_root=" }

---Read the trailing arguments of a move command
---
---`import_root=` is the one that costs nothing to get right and a lot to leave
---open: without it each candidate root is scored by a project-wide scan, which
---is the slow part of a move on a large or unignored tree. An empty value is
---meaningful -- it names modules from the project root itself -- so the two
---roots are returned separately from the options rather than defaulted here.
---@param args string[]
---@param first integer Index of the first option argument
---@return table? options Nil when an argument was not recognised
---@return string? project_root
---@return string? error
function M.parse_options(args, first)
  local options, project_root = {}, nil
  for i = first, #args do
    local argument = args[i]
    local key, value = argument:match "^([%w_]+)=(.*)$"
    if argument == "--no-git" then
      options.use_git = false
    elseif argument == "--git" then
      options.use_git = true
    elseif argument == "-b" or argument == "--backup" then
      options.backup = true
    elseif key == "import_root" then
      options.import_root = value
    elseif key == "project_root" then
      project_root = (fn.fnamemodify(fn.expand(value), ":p"):gsub("/$", ""))
    else
      return nil, nil, "Unrecognized argument: " .. argument
    end
  end
  return options, project_root
end

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

  -- For 3rd+ arguments, complete flags and the root overrides
  if arg_count >= 3 then
    local options = vim.list_extend(vim.list_slice(FLAGS), KWARGS)
    return vim.tbl_filter(function(option)
      return option:find("^" .. vim.pesc(arglead))
    end, options)
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
        "Usage: :PyMove <old_path> <new_path> [--no-git|--git] "
          .. "[import_root=<dir>] [project_root=<dir>]",
        vim.log.levels.ERROR
      )
      return
    end

    local old_name, new_name = args[1], args[2]
    local options, project_root, err = M.parse_options(args, 3)
    if not options then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end

    move.move_module_or_package(old_name, new_name, project_root, options)
  end, {
    nargs = "*",
    desc = "Move Python module/package and update imports directly",
    complete = complete_python_paths,
  })

  api.nvim_create_user_command("PyMovePreview", function(cmd_opts)
    local args = vim.split(cmd_opts.args, " ", { trimempty = true })
    if #args < 2 then
      vim.notify(
        "Usage: :PyMovePreview <old_path> <new_path> [--no-git|--git] "
          .. "[-b|--backup] [import_root=<dir>] [project_root=<dir>]",
        vim.log.levels.ERROR
      )
      return
    end

    local old_name, new_name = args[1], args[2]
    local options, project_root, err = M.parse_options(args, 3)
    if not options then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end

    move.preview_move(old_name, new_name, project_root, options)
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
