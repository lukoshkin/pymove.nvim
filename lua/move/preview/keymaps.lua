local api = vim.api
local state_mod = require "move.preview.state"
local window = require "move.preview.window"

local M = {}

---Toggle status of current change: pending → accepted → declined → pending
---@param state table PreviewState
local function toggle_change_status(state)
  local change_index = state_mod.find_change_at_cursor(state)
  if not change_index then
    vim.notify("No change found at cursor position", vim.log.levels.WARN)
    return
  end

  local change = state.changes[change_index]
  local cursor_pos = api.nvim_win_get_cursor(state.winid)
  local old_status = change.status

  -- Cycle through statuses
  if change.status == "pending" then
    change.status = "accepted"
  elseif change.status == "accepted" then
    change.status = "declined"
  else -- declined
    change.status = "pending"
  end

  state.current_index = change_index
  state_mod.update_change_lines(state, change, old_status)

  -- Restore cursor position
  vim.schedule(function()
    if not api.nvim_win_is_valid(state.winid) then
      return
    end
    if not api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    -- Validate cursor position is within buffer bounds
    local line_count = api.nvim_buf_line_count(state.bufnr)
    if cursor_pos[1] > line_count then
      cursor_pos[1] = line_count
    end
    pcall(api.nvim_win_set_cursor, state.winid, cursor_pos)
  end)
end

---Setup buffer-local keymaps
---@param state table PreviewState
---@param apply_changes_fn function Function to apply accepted changes
function M.setup_keymaps(state, apply_changes_fn)
  local opts = { buffer = state.bufnr, silent = true }

  -- Navigation using file headers (search-based with wrapping)
  vim.keymap.set("n", "<C-n>", function()
    api.nvim_win_call(state.winid, function()
      vim.fn.search("^║ File:", "w")
      local target_line = vim.fn.line "."
      local topline = math.max(1, target_line - 2)
      vim.fn.winrestview { topline = topline, lnum = target_line }
    end)
  end, opts)

  vim.keymap.set("n", "<C-p>", function()
    api.nvim_win_call(state.winid, function()
      vim.fn.search("^║ File:", "bw")
      local target_line = vim.fn.line "."
      local topline = math.max(1, target_line - 2)
      vim.fn.winrestview { topline = topline, lnum = target_line }
    end)
  end, opts)

  -- Toggle status of current change
  vim.keymap.set("n", "<Space>", function()
    toggle_change_status(state)
  end, opts)

  -- Accept all pending changes (just mark, don't apply)
  local function accept_all_pending()
    local cursor_pos = api.nvim_win_get_cursor(state.winid)
    for _, change in ipairs(state.changes) do
      if change.status == "pending" then
        local old_status = change.status
        change.status = "accepted"
        state_mod.update_change_lines(state, change, old_status)
      end
    end
    pcall(api.nvim_win_set_cursor, state.winid, cursor_pos)
  end

  vim.keymap.set("n", "<C-a>", accept_all_pending, opts)
  vim.keymap.set("n", "<A-a>", accept_all_pending, opts)

  -- Show help window
  vim.keymap.set("n", "?", function()
    window.show_help_window(state.winid)
  end, opts)

  -- Apply accepted changes and close
  vim.keymap.set("n", "q", function()
    apply_changes_fn(state)
  end, opts)

  -- Cancel without applying
  vim.keymap.set("n", "<Esc>", function()
    vim.notify("Cancelled without applying changes", vim.log.levels.INFO)
    api.nvim_win_close(state.winid, true)
  end, opts)
end

return M
