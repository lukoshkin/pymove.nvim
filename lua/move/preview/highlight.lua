local api = vim.api

local M = {}

---Compiled patterns for highlighting (cached for performance)
M.patterns = {
  header = "^[╔║╚]",
  git_mv = "git mv",
  old_import = "^%-",
  new_import = "^%+",
  context = "^ %d+ |",
  accepted = "✓",
  declined = "✗",
}

---Apply syntax highlighting to the preview buffer (optimized)
---@param bufnr integer Buffer number
---@param namespace integer Namespace for extmarks
function M.apply_highlights(bufnr, namespace)
  -- Clear existing highlights
  api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Safety limit to prevent memory explosion on large previews
  local MAX_HIGHLIGHT_LINES = 10000

  -- Batch extmarks for better performance
  local extmarks = {}

  for line_idx, line_text in ipairs(lines) do
    if line_idx > MAX_HIGHLIGHT_LINES then
      break
    end

    local row = line_idx - 1 -- 0-indexed
    local line_len = #line_text
    if line_len == 0 then
      goto continue
    end

    -- Check patterns (box-drawing chars are multi-byte UTF-8)
    if line_text:match(M.patterns.header) then
      table.insert(extmarks, {
        row,
        0,
        { end_col = line_len, hl_group = "PyMoveHeader", strict = false },
      })
    elseif line_text:find(M.patterns.git_mv, 1, true) then
      table.insert(extmarks, {
        row,
        0,
        {
          end_col = line_len,
          hl_group = "PyMoveFileOperation",
          strict = false,
        },
      })
    elseif line_text:match(M.patterns.old_import) then
      table.insert(extmarks, {
        row,
        0,
        { end_col = line_len, hl_group = "PyMoveOldImport", strict = false },
      })
    elseif line_text:match(M.patterns.new_import) then
      table.insert(extmarks, {
        row,
        0,
        { end_col = line_len, hl_group = "PyMoveNewImport", strict = false },
      })
    elseif line_text:match(M.patterns.context) then
      table.insert(extmarks, {
        row,
        0,
        { end_col = line_len, hl_group = "PyMoveContext", strict = false },
      })
    else
      -- Check for status indicators (less common, so check last)
      local accepted_col = line_text:find(M.patterns.accepted, 1, true)
      if accepted_col then
        table.insert(extmarks, {
          row,
          accepted_col - 1,
          {
            end_col = accepted_col,
            hl_group = "PyMoveAccepted",
            strict = false,
          },
        })
      end

      local declined_col = line_text:find(M.patterns.declined, 1, true)
      if declined_col then
        table.insert(extmarks, {
          row,
          declined_col - 1,
          {
            end_col = declined_col,
            hl_group = "PyMoveDeclined",
            strict = false,
          },
        })
      end
    end

    ::continue::
  end

  -- Apply all extmarks in batch
  for _, mark in ipairs(extmarks) do
    api.nvim_buf_set_extmark(bufnr, namespace, mark[1], mark[2], mark[3])
  end
end

---Apply highlights to a range of lines (for incremental updates)
---@param bufnr integer Buffer number
---@param namespace integer Namespace for extmarks
---@param start_line integer Start line (0-indexed)
---@param end_line integer End line (exclusive, 0-indexed)
function M.apply_highlights_range(bufnr, namespace, start_line, end_line)
  -- Clear existing highlights in range
  api.nvim_buf_clear_namespace(bufnr, namespace, start_line, end_line)

  local lines = api.nvim_buf_get_lines(bufnr, start_line, end_line, false)

  for i, line_text in ipairs(lines) do
    local row = start_line + i - 1
    local line_len = #line_text

    if line_len == 0 then
      goto continue
    end

    -- Apply appropriate highlights based on content
    if line_text:match(M.patterns.old_import) then
      pcall(api.nvim_buf_set_extmark, bufnr, namespace, row, 0, {
        end_col = line_len,
        hl_group = "PyMoveOldImport",
        strict = false,
      })
    elseif line_text:match(M.patterns.new_import) then
      pcall(api.nvim_buf_set_extmark, bufnr, namespace, row, 0, {
        end_col = line_len,
        hl_group = "PyMoveNewImport",
        strict = false,
      })
    end

    -- Check for status indicators
    local accepted_col = line_text:find(M.patterns.accepted, 1, true)
    if accepted_col then
      pcall(
        api.nvim_buf_set_extmark,
        bufnr,
        namespace,
        row,
        accepted_col - 1,
        {
          end_col = accepted_col,
          hl_group = "PyMoveAccepted",
          strict = false,
        }
      )
    end

    local declined_col = line_text:find(M.patterns.declined, 1, true)
    if declined_col then
      pcall(
        api.nvim_buf_set_extmark,
        bufnr,
        namespace,
        row,
        declined_col - 1,
        {
          end_col = declined_col,
          hl_group = "PyMoveDeclined",
          strict = false,
        }
      )
    end

    ::continue::
  end
end

return M
