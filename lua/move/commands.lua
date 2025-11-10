local api = vim.api

local M = {}

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
    complete = function(arglead, cmdline, curpos)
      return { "--no-git", "--git" }
    end,
  })

  api.nvim_create_user_command("PyMovePreview", function(cmd_opts)
    local args = vim.split(cmd_opts.args, " ", { trimempty = true })
    if #args < 2 then
      vim.notify(
        "Usage: :PyMovePreview <old_path> <new_path> [--no-git|--git]",
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

    move.preview_move(old_name, new_name, nil, options)
  end, {
    nargs = "*",
    desc = "Preview Python module/package move with interactive UI",
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
