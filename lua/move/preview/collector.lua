local api = vim.api
local fn = vim.fn
local Path = require "plenary.path"
local utils = require "move.utils"

local M = {}

---Cache for treesitter queries to avoid recompilation
local query_cache = {}

---Get or create cached treesitter query
---@param lang string Language name
---@param query_string string Query string
---@return vim.treesitter.Query
local function get_cached_query(lang, query_string)
  local cache_key = lang .. ":" .. query_string
  if not query_cache[cache_key] then
    query_cache[cache_key] = vim.treesitter.query.parse(lang, query_string)
  end
  return query_cache[cache_key]
end

---Get logger instance
---@return table Logger
local function get_log()
  return require("plenary.log").new {
    plugin = "pymove-preview-collector",
    use_console = true,
  }
end

---Process a single file for import changes
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
  local log = get_log()
  local changes = {}

  local bufnr = fn.bufadd(file)
  fn.bufload(bufnr)

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

        -- Resolve relative imports
        if name:find "^%." then
          local rel_path = Path:new(file):make_relative(project_root)
          name = utils.absolute_dotted_path(rel_path, name)
        end

        -- Check if this import matches
        if name:find("^" .. old_dotted) then
          local new_import = name:gsub("^" .. old_dotted, new_dotted)
          local start_row, start_col, end_row, end_col = node:range()

          -- Get context lines
          local total_lines = api.nvim_buf_line_count(bufnr)
          local ctx_start = math.max(0, start_row - context_lines)
          local ctx_end = math.min(total_lines, end_row + context_lines + 1)

          local context_before =
            api.nvim_buf_get_lines(bufnr, ctx_start, start_row, false)
          local context_after =
            api.nvim_buf_get_lines(bufnr, end_row + 1, ctx_end, false)

          table.insert(changes, {
            file = file,
            line_num = start_row + 1, -- 1-indexed for display
            old_import = name,
            new_import = new_import,
            context_before = context_before,
            context_after = context_after,
            status = "pending",
            buffer_line = 0, -- Will be set when building buffer
            node_range = { start_row, start_col, end_row, end_col },
          })
        end

        ::continue_node::
      end
    end
  end

  return changes
end

---Collect all import changes with async batched processing
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
  local changes = {}
  local context_lines = 3
  local batch_size = 10 -- Process 10 files at a time
  local current_idx = 1

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
      -- Schedule next batch to avoid blocking UI
      vim.schedule(process_batch)
    else
      -- All done
      callback(changes)
    end
  end

  -- Start processing
  process_batch()
end

return M
