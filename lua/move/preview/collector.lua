local api = vim.api
local fn = vim.fn
local Path = require "plenary.path"
local utils = require "move.utils"

local M = {}

local query_cache = {}
local log = require("plenary.log").new {
  plugin = "pymove-preview-collector",
  use_console = true,
}

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

local function get_cached_query(lang, query_string)
  local cache_key = lang .. ":" .. query_string
  query_cache[cache_key] = query_cache[cache_key]
    or vim.treesitter.query.parse(lang, query_string)
  return query_cache[cache_key]
end

---@param file string File path
---@param old_dotted string Old import path
---@param new_dotted string New import path
---@param project_root string Project root
---@param context_lines integer Number of context lines
---@return table[] changes
function M.process_file_changes(
  file,
  old_dotted,
  new_dotted,
  project_root,
  context_lines
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
    log.warn("Failed to load buffer for file: " .. file)
    return changes
  end

  local success, parser = pcall(vim.treesitter.get_parser, bufnr, "python")
  if not success then
    log.warn("Failed to get parser for file: " .. file)
    return changes
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    log.warn("Failed to parse file: " .. file)
    return changes
  end

  local tree = trees[1]
  local root = tree:root()
  local query_string = [[
    (import_from_statement
      module_name: (dotted_name) @module_name)
    (import_statement
      (dotted_name) @module_name)
  ]]
  local query_obj = get_cached_query("python", query_string)

  for id, node, metadata in query_obj:iter_captures(root, bufnr) do
    if node then
      local capture_name = query_obj.captures[id]
      if capture_name == "module_name" then
        local success, name = pcall(vim.treesitter.get_node_text, node, bufnr)
        if not success then
          goto continue_node
        end

        if name:find "^%." then
          local rel_path = Path:new(file):make_relative(project_root)
          name = utils.absolute_dotted_path(rel_path, name)
        end

        if name:find("^" .. old_dotted) then
          local new_import = name:gsub("^" .. old_dotted, new_dotted)
          local start_row, start_col, end_row, end_col = node:range()

          local total_lines = api.nvim_buf_line_count(bufnr)
          local ctx_start = math.max(0, start_row - context_lines)
          local ctx_end = math.min(total_lines, end_row + context_lines + 1)

          local context_before = api.nvim_buf_get_lines(bufnr, ctx_start, start_row, false)
          local context_after = api.nvim_buf_get_lines(bufnr, end_row + 1, ctx_end, false)

          -- Get the full import line for display
          local full_line = api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1] or ""

          table.insert(changes, {
            file = file,
            line_num = start_row + 1,
            old_import = name,
            new_import = new_import,
            full_line = full_line,
            context_before = context_before,
            context_after = context_after,
            status = "pending",
            buffer_line = 0,
            node_range = { start_row, start_col, end_row, end_col },
          })
        end

        ::continue_node::
      end
    end
  end

  return changes
end

---@param old_dotted string Old import path
---@param new_dotted string New import path
---@param files string[] Files to check
---@param project_root string Project root
---@param progress_cb function? Progress callback (current, total, file)
---@param callback function Completion callback with changes
function M.collect_changes_async(
  old_dotted,
  new_dotted,
  files,
  project_root,
  progress_cb,
  callback
)
  local changes, current_idx = {}, 1
  local context_lines, batch_size = 3, 10

  local function process_batch()
    local batch_end = math.min(current_idx + batch_size - 1, #files)

    for i = current_idx, batch_end do
      local file = files[i]
      local file_changes = M.process_file_changes(
        file,
        old_dotted,
        new_dotted,
        project_root,
        context_lines
      )
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
