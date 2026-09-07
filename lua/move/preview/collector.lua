local api = vim.api
local fn = vim.fn
local filesystem = require "move.filesystem"
local imports = require "move.imports"

local M = {}

---Check if a file has an active swap file
---@param filepath string File path to check
---@return boolean has_swap True if swap file exists
---@return string? swap_path Path to swap file if it exists
local function has_swap_file(filepath)
  -- Expand to absolute path
  local abs_path = vim.fn.fnamemodify(filepath, ":p")

  -- Get Neovim's swap directory
  local swap_dir = vim.fn.stdpath "state" .. "/swap"

  -- Neovim encodes file paths in swap file names by replacing / with %
  -- e.g., /home/user/file.py -> %home%user%file.py.swp
  local encoded_path = abs_path:gsub("/", "%%")

  -- Check for swap files with various extensions (.swp, .swo, .swn, etc.)
  local swap_extensions = { "swp", "swo", "swn", "swm", "swl", "swk" }

  for _, ext in ipairs(swap_extensions) do
    local swap_path = string.format("%s/%s.%s", swap_dir, encoded_path, ext)
    if vim.fn.filereadable(swap_path) == 1 then
      return true, swap_path
    end
  end

  return false, nil
end

---Check all files for swap files
---@param files string[] List of file paths to check
---@return table[] swap_files List of {file, swap_path} for files with swaps
function M.check_swap_files(files)
  local swap_files = {}

  for _, file in ipairs(files) do
    local has_swap, swap_path = has_swap_file(file)
    if has_swap then
      table.insert(swap_files, {
        file = file,
        swap_path = swap_path,
      })
    end
  end

  return swap_files
end

---@param file string File path
---@param old_dotted string Old import path
---@param new_dotted string New import path
---@param project_root string Project root
---@param context_lines integer Number of context lines
---@param strategy "absolute"|"preserve" How to spell rewritten relative imports
---@return table[]? changes
---@return string? error
function M.process_file_changes(
  file,
  old_dotted,
  new_dotted,
  project_root,
  context_lines,
  strategy
)
  local changes = {}

  local bufnr = fn.bufadd(file)

  -- Suppress swap file prompts during buffer load
  local old_shortmess = vim.o.shortmess
  vim.o.shortmess = vim.o.shortmess .. "A"

  local load_success = pcall(fn.bufload, bufnr)

  -- Restore original shortmess setting
  vim.o.shortmess = old_shortmess

  if not load_success then
    return nil, "Failed to load buffer for file: " .. file
  end

  local success, parser = pcall(vim.treesitter.get_parser, bufnr, "python")
  if not success or not parser then
    return nil,
      "Python treesitter parser unavailable for "
        .. file
        .. " -- run :TSInstall python to install it"
  end

  local rel_path = filesystem.import_relative_path(project_root, file)
  local ok, matches =
    pcall(imports.find_matches, bufnr, rel_path, old_dotted, new_dotted)
  if not ok then
    return nil,
      "Failed to scan imports in " .. file .. ": " .. tostring(matches)
  end
  local total_lines = api.nvim_buf_line_count(bufnr)

  for _, match in ipairs(matches) do
    imports.select_strategy(match, strategy)

    local start_row, end_row = match.node_range[1], match.node_range[3]
    local ctx_start = math.max(0, start_row - context_lines)
    local ctx_end = math.min(total_lines, end_row + context_lines + 1)

    table.insert(changes, {
      file = file,
      line_num = match.line_num,
      old_import = match.old_import,
      new_import = match.new_import,
      new_import_absolute = match.new_import_absolute,
      new_import_relative = match.new_import_relative,
      unfixable = match.unfixable,
      reason = match.reason,
      aliased_name = match.aliased_name,
      aliased_to = match.aliased_to,
      full_line = api.nvim_buf_get_lines(
        bufnr,
        start_row,
        start_row + 1,
        false
      )[1] or "",
      context_before = api.nvim_buf_get_lines(
        bufnr,
        ctx_start,
        start_row,
        false
      ),
      context_after = api.nvim_buf_get_lines(
        bufnr,
        end_row + 1,
        ctx_end,
        false
      ),
      status = match.unfixable and "unfixable" or "pending",
      buffer_line = 0,
      node_range = match.node_range,
    })
  end

  return changes
end

---@param old_dotted string Old import path
---@param new_dotted string New import path
---@param files string[] Files to check
---@param project_root string Project root
---@param progress_cb function? Progress callback (current, total, file)
---@param callback function Completion callback with changes
---@param strategy "absolute"|"preserve" How to spell rewritten relative imports
function M.collect_changes_async(
  old_dotted,
  new_dotted,
  files,
  project_root,
  progress_cb,
  callback,
  strategy
)
  local changes, current_idx = {}, 1
  local context_lines, batch_size = 3, 10

  local function process_batch()
    local batch_end = math.min(current_idx + batch_size - 1, #files)

    for i = current_idx, batch_end do
      local file = files[i]
      local file_changes, err = M.process_file_changes(
        file,
        old_dotted,
        new_dotted,
        project_root,
        context_lines,
        strategy
      )
      if not file_changes then
        callback(nil, err)
        return
      end
      for _, change in ipairs(file_changes) do
        table.insert(changes, change)
      end

      if progress_cb then
        progress_cb(i, #files, file)
      end
    end

    current_idx = batch_end + 1

    if current_idx <= #files then
      vim.schedule(process_batch)
    else
      callback(changes)
    end
  end

  process_batch()
end

return M
