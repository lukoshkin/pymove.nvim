local api = vim.api

local M = {}

---Setup custom highlight groups for preview buffer
function M.setup_highlights()
  -- Section headers
  api.nvim_set_hl(0, "PyMoveHeader", { fg = "#89b4fa", bold = true }) -- Blue
  api.nvim_set_hl(0, "PyMoveFileOperation", { fg = "#f9e2af", bold = true }) -- Yellow

  -- Import changes
  api.nvim_set_hl(0, "PyMoveOldImport", { fg = "#f38ba8", bg = "#3e2b35" }) -- Red background
  api.nvim_set_hl(0, "PyMoveNewImport", { fg = "#a6e3a1", bg = "#2b3328" }) -- Green background

  -- Status indicators
  api.nvim_set_hl(0, "PyMoveAccepted", { fg = "#a6e3a1", bold = true }) -- Green
  api.nvim_set_hl(0, "PyMoveDeclined", { fg = "#f38ba8", bold = true }) -- Red
  api.nvim_set_hl(0, "PyMovePending", { fg = "#cdd6f4" }) -- White

  -- Context lines
  api.nvim_set_hl(0, "PyMoveContext", { fg = "#6c7086" }) -- Dim gray
end

---Create a floating window with X% screen size
---@return integer bufnr
---@return integer winid
function M.create_floating_window()
  local width = math.floor(vim.o.columns * 0.7)
  local height = math.floor(vim.o.lines * 0.7)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local bufnr = api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false

  -- Disable syntax to prevent it from interfering with our highlights
  vim.bo[bufnr].syntax = "off"

  local opts = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " PyMove Preview ",
    title_pos = "center",
  }

  local winid = api.nvim_open_win(bufnr, true, opts)
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = true

  -- Disable syntax in window as well
  vim.cmd "setlocal syntax=off"

  return bufnr, winid
end

---Create a loading progress window
---@return integer bufnr
---@return integer winid
function M.create_loading_window()
  local width = 60
  local height = 6
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local bufnr = api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].modifiable = false

  local opts = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Processing Files ",
    title_pos = "center",
  }

  local winid = api.nvim_open_win(bufnr, false, opts)
  return bufnr, winid
end

---Update loading window with progress
---@param bufnr integer Buffer number
---@param current integer Current file index
---@param total integer Total files
---@param file string? Current file being processed
function M.update_loading_progress(bufnr, current, total, file)
  local percent = math.floor((current / total) * 100)
  local bar_width = 50
  local filled = math.floor((current / total) * bar_width)
  local bar = string.rep("█", filled)
    .. string.rep("░", bar_width - filled)

  local window_width = 60 -- From create_loading_window

  -- Helper to center a line
  local function center_line(text)
    local padding = math.floor((window_width - vim.fn.strwidth(text)) / 2)
    return string.rep(" ", padding) .. text
  end

  local status_text = string.format(
    "Processing files: %d/%d (%d%%)",
    current,
    total,
    percent
  )

  local lines = {
    center_line(status_text),
    center_line(bar),
    "",
    center_line("Current:"),
    file and center_line(vim.fn.fnamemodify(file, ":t")) or "",
  }

  vim.bo[bufnr].modifiable = true
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.cmd "redraw"
end

---Create and show floating help window
---@param parent_winid integer Parent window ID to position relative to
---@return integer bufnr Help buffer number
---@return integer winid Help window ID
function M.show_help_window(parent_winid)
  local help_lines = {
    "╔═ Keymaps ════════════════════════════════════════════════════",
    "│ Navigation:",
    "│   <C-n>         Jump to next change",
    "│   <C-p>         Jump to previous change",
    "│",
    "│ Actions:",
    "│   <Space>       Toggle status (pending → accepted → declined)",
    "│   <C-a> / <A-a> Accept all pending changes",
    "│",
    "│ Finalize:",
    "│   q             Apply accepted changes and close",
    "│   <Esc>         Cancel without applying",
    "│",
    "│   ?             Close this help",
    "╚══════════════════════════════════════════════════════════════",
  }

  -- Create buffer
  local bufnr = api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].modifiable = false

  -- Calculate position (centered in screen)
  local width = 65
  local height = #help_lines
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local opts = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Help ",
    title_pos = "center",
  }

  local winid = api.nvim_open_win(bufnr, true, opts)

  -- Set buffer content
  vim.bo[bufnr].modifiable = true
  api.nvim_buf_set_lines(bufnr, 0, -1, false, help_lines)
  vim.bo[bufnr].modifiable = false

  -- Apply highlights
  local ns = api.nvim_create_namespace "pymove-help"
  for i, line in ipairs(help_lines) do
    local row_idx = i - 1
    if line:match "^╔" or line:match "^╚" then
      api.nvim_buf_set_extmark(
        bufnr,
        ns,
        row_idx,
        0,
        { end_col = #line, hl_group = "PyMoveHeader", strict = false }
      )
    else
      api.nvim_buf_set_extmark(
        bufnr,
        ns,
        row_idx,
        0,
        { end_col = #line, hl_group = "PyMoveContext", strict = false }
      )
    end
  end

  -- Setup keymaps to close help and return to preview window
  local function close_help()
    api.nvim_win_close(winid, true)
    api.nvim_set_current_win(parent_winid)
  end

  for _, key in ipairs { "?", "<Esc>", "q" } do
    vim.keymap.set("n", key, close_help, { buffer = bufnr, silent = true })
  end

  return bufnr, winid
end

---Update winbar with help hint
---@param winid integer Window ID
function M.update_winbar(winid)
  vim.wo[winid].winbar = "  Press ? for help  "
end

return M
