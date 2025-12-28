local api = vim.api
local highlight = require "move.preview.highlight"

local M = {}

---Build the preview buffer with all changes
---@param state table PreviewState
function M.build_preview_buffer(state)
  local lines = {}

  -- Show file move operation at top (first change should be the move operation)
  local move_op = state.changes[1]
  if move_op and move_op.type == "file_move" then
    local operation_label = "File Operation"
    local operation_width = vim.fn.strwidth(operation_label) + 2
    local operation_border = string.rep("═", operation_width)

    table.insert(lines, "╔" .. operation_border .. "╗")
    table.insert(lines, string.format("║ %s ║", operation_label))
    table.insert(lines, "╚" .. operation_border .. "╝")

    -- Mark the line where move operation starts for toggle functionality
    move_op.buffer_line = #lines + 1

    -- Show status marker
    local status_marker = ""
    if move_op.status == "accepted" then
      status_marker = " ✓"
    elseif move_op.status == "declined" then
      status_marker = " ✗"
    end

    -- Show move command with status
    local cmd = move_op.use_git and "git mv" or "mv"
    local line = string.format(
      "  %s %s → %s%s",
      cmd,
      move_op.old_name,
      move_op.new_name,
      status_marker
    )

    -- Add warning if destination exists
    if move_op.dest_exists then
      line = line .. " ⚠️  (destination exists)"
    end

    table.insert(lines, line)
  else
    -- Fallback if move operation is not first change
    local operation_label = "File Operation"
    local operation_width = vim.fn.strwidth(operation_label) + 2
    local operation_border = string.rep("═", operation_width)

    table.insert(lines, "╔" .. operation_border .. "╗")
    table.insert(lines, string.format("║ %s ║", operation_label))
    table.insert(lines, "╚" .. operation_border .. "╝")
    table.insert(
      lines,
      string.format("  git mv %s → %s", state.old_name, state.new_name)
    )
  end

  -- Show truncation warning if applicable
  if state.truncated then
    table.insert(
      lines,
      string.format(
        "  ⚠ Warning: Showing changes from limited file set"
          .. " (processed subset of %d files)",
        state.total_files
      )
    )
  end

  -- File headers provide sufficient visual separation
  table.insert(lines, "")

  -- Group changes by file (skip move operation)
  local files_map = {}
  for _, change in ipairs(state.changes) do
    -- Skip the file move operation (it's already shown above)
    if change.type ~= "file_move" then
      if not files_map[change.file] then
        files_map[change.file] = {}
      end
      table.insert(files_map[change.file], change)
    end
  end

  -- Sort files for consistent display
  local sorted_files = {}
  for file, _ in pairs(files_map) do
    table.insert(sorted_files, file)
  end
  table.sort(sorted_files)

  for _, file in ipairs(sorted_files) do
    local file_changes = files_map[file]

    -- Sort changes by line number for consolidated view
    table.sort(file_changes, function(a, b)
      return a.line_num < b.line_num
    end)

    -- Build set of all line numbers being changed (to avoid showing as context)
    local changed_lines = {}
    for _, change in ipairs(file_changes) do
      changed_lines[change.line_num] = true
    end

    -- File header
    local file_label = string.format("File: %s", file)
    local total_width = vim.fn.strwidth(file_label) + 2 -- +2 for "║ " prefix
    local border = string.rep("═", total_width)

    table.insert(lines, "╔" .. border .. "╗")
    table.insert(lines, string.format("║ %s ║", file_label))
    table.insert(lines, "╚" .. border .. "╝")

    -- Track last shown line to avoid duplicate context
    local last_shown_line = 0

    for _, change in ipairs(file_changes) do
      -- Calculate context_before start position
      local ctx_before_start = change.line_num - #change.context_before

      -- Show context_before (skip if overlaps with previous change)
      if ctx_before_start > last_shown_line + 1 then
        -- Gap between changes - show ellipsis
        if last_shown_line > 0 then
          table.insert(lines, "     | ...")
        end
      end

      for i, line in ipairs(change.context_before) do
        local line_num = ctx_before_start + i - 1
        -- Skip if this line is already shown or is being changed
        if line_num > last_shown_line and not changed_lines[line_num] then
          table.insert(lines, string.format(" %3d | %s", line_num, line))
          last_shown_line = line_num
        end
      end

      -- Mark where this change's import line starts
      change.buffer_line = #lines + 1

      -- Status indicator
      local status_marker = ""
      if change.status == "accepted" then
        status_marker = " ✓"
      elseif change.status == "declined" then
        status_marker = " ✗"
      end

      -- Show import diff based on status
      -- Use full_line if available, otherwise fallback to simplified format
      local old_line = change.full_line or ("from " .. change.old_import)
      local new_line = old_line:gsub(vim.pesc(change.old_import), change.new_import)

      if change.status == "accepted" then
        table.insert(
          lines,
          string.format(
            "+ %3d | %s%s",
            change.line_num,
            new_line,
            status_marker
          )
        )
      elseif change.status == "declined" then
        table.insert(
          lines,
          string.format(
            "- %3d | %s%s",
            change.line_num,
            old_line,
            status_marker
          )
        )
      else
        table.insert(
          lines,
          string.format("- %3d | %s", change.line_num, old_line)
        )
        table.insert(
          lines,
          string.format("+ %3d | %s", change.line_num, new_line)
        )
      end

      -- Update last_shown_line to at least the import line (but don't go backwards)
      last_shown_line = math.max(last_shown_line, change.line_num)

      -- Show context_after only if next change is not consecutive
      -- (i.e., there's a gap between this change and the next one)
      local next_change = file_changes[_ + 1]
      local show_context = not next_change
        or next_change.line_num > change.line_num + #change.context_after

      if show_context then
        for i, line in ipairs(change.context_after) do
          local line_num = change.line_num + i
          -- Skip if this line is already shown or is being changed
          if line_num > last_shown_line and not changed_lines[line_num] then
            table.insert(lines, string.format(" %3d | %s", line_num, line))
            last_shown_line = line_num
          end
        end
      end
    end

    table.insert(lines, "")
  end

  -- Make buffer modifiable before updating
  vim.bo[state.bufnr].modifiable = true
  api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  -- Apply syntax highlighting after buffer is fully updated
  vim.schedule(function()
    if not api.nvim_win_is_valid(state.winid) then
      return
    end
    if not api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    highlight.apply_highlights(state.bufnr, state.namespace)
  end)
end

---Find which change the cursor is currently on
---@param state table PreviewState
---@return integer|nil Index of the change, or nil if not on a change
function M.find_change_at_cursor(state)
  local cursor_line = api.nvim_win_get_cursor(state.winid)[1]

  -- Find the last change whose buffer_line is <= cursor_line
  local best_match = nil
  local best_distance = math.huge

  for i, change in ipairs(state.changes) do
    if change.buffer_line and change.buffer_line <= cursor_line then
      local distance = cursor_line - change.buffer_line
      if distance < best_distance then
        best_distance = distance
        best_match = i
      end
    end
  end

  return best_match
end

---Atomically update a single change's display lines
---@param state table PreviewState
---@param change table ChangePreview
---@param old_status string Previous status before toggle
function M.update_change_lines(state, change, old_status)
  -- Handle file move operation separately
  if change.type == "file_move" then
    local status_marker = ""
    if change.status == "accepted" then
      status_marker = " ✓"
    elseif change.status == "declined" then
      status_marker = " ✗"
    end

    local cmd = change.use_git and "git mv" or "mv"
    local line = string.format(
      "  %s %s → %s%s",
      cmd,
      change.old_name,
      change.new_name,
      status_marker
    )

    if change.dest_exists then
      line = line .. " ⚠️  (destination exists)"
    end

    -- Update the single line
    vim.bo[state.bufnr].modifiable = true
    api.nvim_buf_set_lines(
      state.bufnr,
      change.buffer_line - 1,
      change.buffer_line,
      false,
      { line }
    )
    vim.bo[state.bufnr].modifiable = false

    -- Apply highlights to the updated line
    highlight.apply_highlights_range(
      state.bufnr,
      state.namespace,
      change.buffer_line - 1,
      change.buffer_line
    )
    return
  end

  -- Handle import changes
  local new_lines = {}
  local status_marker = ""

  -- Use full_line if available, otherwise fallback to simplified format
  local old_line = change.full_line or ("from " .. change.old_import)
  local new_line = old_line:gsub(vim.pesc(change.old_import), change.new_import)

  if change.status == "accepted" then
    status_marker = " ✓"
    table.insert(
      new_lines,
      string.format(
        "+ %3d | %s%s",
        change.line_num,
        new_line,
        status_marker
      )
    )
  elseif change.status == "declined" then
    status_marker = " ✗"
    table.insert(
      new_lines,
      string.format(
        "- %3d | %s%s",
        change.line_num,
        old_line,
        status_marker
      )
    )
  else
    -- Pending: show both old and new for comparison
    table.insert(
      new_lines,
      string.format("- %3d | %s", change.line_num, old_line)
    )
    table.insert(
      new_lines,
      string.format("+ %3d | %s", change.line_num, new_line)
    )
  end

  -- buffer_line now points directly to import line in consolidated view
  local import_start_line = change.buffer_line
  local old_import_lines = old_status == "pending" and 2 or 1

  -- Update the buffer
  vim.bo[state.bufnr].modifiable = true
  api.nvim_buf_set_lines(
    state.bufnr,
    import_start_line - 1,
    import_start_line - 1 + old_import_lines,
    false,
    new_lines
  )
  vim.bo[state.bufnr].modifiable = false

  -- Apply highlights to these specific lines
  highlight.apply_highlights_range(
    state.bufnr,
    state.namespace,
    import_start_line - 1,
    import_start_line - 1 + #new_lines
  )

  -- Adjust buffer_line for subsequent changes if the number of lines changed
  local line_delta = #new_lines - old_import_lines
  if line_delta ~= 0 then
    for _, other_change in ipairs(state.changes) do
      if other_change.buffer_line > change.buffer_line then
        other_change.buffer_line = other_change.buffer_line + line_delta
      end
    end
  end
end

---Jump to a specific change with optional top positioning
---@param state table PreviewState
---@param index integer Change index to jump to
---@param scroll_to_top? boolean Position change at top of window (default: false)
function M.jump_to_change(state, index, scroll_to_top)
  if index < 1 or index > #state.changes then
    return
  end

  state.current_index = index
  local change = state.changes[index]
  local target_line = change.buffer_line

  -- Move cursor to the change
  api.nvim_win_set_cursor(state.winid, { target_line, 0 })

  if scroll_to_top then
    -- Position change near top of window (with small offset for readability)
    local topline = math.max(1, target_line - 2)
    vim.fn.winrestview { topline = topline, lnum = target_line }
  end
  -- Otherwise, let Neovim's natural scrolling handle positioning
end

return M
