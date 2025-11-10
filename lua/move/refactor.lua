local api = vim.api
local fn = vim.fn
local Path = require "plenary.path"
local utils = require "move.utils"

local M = {}

-- Get logger from parent module
local function get_log()
  return require("plenary.log").new {
    plugin = "pymove-refactor",
    use_console = true,
  }
end

---Find all files matching a pattern in a directory
---@param pattern string Regex pattern to search for
---@param directory string Directory to search in
---@param extension string File extension pattern (e.g., "*.py")
---@return string[] List of file paths
function M.find_files_with_pattern(pattern, directory, extension)
  local results = {}
  local log = get_log()
  local rg_cmd = string.format(
    "rg --files-with-matches --no-messages -g '%s' -e '%s' %s",
    extension,
    pattern,
    directory
  )
  local grep_cmd = string.format(
    "grep -rlE --include '%s' '%s' %s",
    extension,
    pattern,
    directory
  )

  local function run_command(cmd)
    local output = fn.systemlist(cmd)
    if vim.v.shell_error ~= 0 then
      return nil, output
    end
    return output
  end

  local output, err = run_command(rg_cmd)
  if not output then
    output, err = run_command(grep_cmd)
    if not output then
      log.debug("Error running command: ", err)
      return results
    end
  end

  for _, file in ipairs(output) do
    table.insert(results, file)
  end

  return results
end

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

---Update specific imports in a file by line numbers
---@param file string Path to the file
---@param specific_changes table[] List of changes with file, line_num, old_import, new_import
---@param project_root string Project root directory
function M.update_specific_imports(file, specific_changes, project_root)
  local log = get_log()
  local bufnr = fn.bufadd(file)
  fn.bufload(bufnr)

  -- Add error handling for treesitter parsing
  local success, parser = pcall(vim.treesitter.get_parser, bufnr, "python")
  if not success then
    log.warn("Failed to get parser for file: " .. file)
    return
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    log.warn("Failed to parse file: " .. file)
    return
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
  local updates = {}

  -- Build a set of line numbers we want to update
  local target_lines = {}
  for _, change in ipairs(specific_changes) do
    target_lines[change.line_num] = change
  end

  -- Use iter_captures to find matching imports
  for id, node, metadata in query_obj:iter_captures(root, bufnr) do
    if node then
      local capture_name = query_obj.captures[id]
      if capture_name == "module_name" then
        local start_row, start_col, end_row, end_col = node:range()
        local line_num = start_row + 1 -- Convert to 1-indexed

        -- Check if this is one of the lines we want to update
        local target_change = target_lines[line_num]
        if target_change then
          local success, name = pcall(vim.treesitter.get_node_text, node, bufnr)
          if success then
            -- Resolve relative imports
            if name:find "^%." then
              local rel_path = Path:new(file):make_relative(project_root)
              name = utils.absolute_dotted_path(rel_path, name)
            end

            -- Verify it matches what we expect
            if name == target_change.old_import then
              table.insert(updates, {
                node = node,
                old_import = name,
                new_import = target_change.new_import,
                start_row = start_row,
                start_col = start_col,
                end_row = end_row,
                end_col = end_col,
              })
            end
          end
        end
      end
    end
  end

  -- Apply updates
  for _, update in ipairs(updates) do
    api.nvim_buf_set_text(
      bufnr,
      update.start_row,
      update.start_col,
      update.end_row,
      update.end_col,
      { update.new_import }
    )
  end

  -- Only write and format if there were changes
  if #updates > 0 then
    api.nvim_buf_call(bufnr, function()
      vim.cmd "write!"
      -- Check if conform is available before using it
      local success, conform = pcall(require, "conform")
      if success then
        conform.format()
      end
    end)
  end

  return #updates
end

---Update imports in a file from old to new dotted name
---@param file string Path to the file
---@param old_dotted_name string Old import path
---@param new_dotted_name string New import path
---@param project_root string Project root directory
function M.update_imports(file, old_dotted_name, new_dotted_name, project_root)
  local log = get_log()
  local bufnr = fn.bufadd(file)
  fn.bufload(bufnr)

  -- Add error handling for treesitter parsing
  local success, parser = pcall(vim.treesitter.get_parser, bufnr, "python")
  if not success then
    log.warn("Failed to get parser for file: " .. file)
    return
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    log.warn("Failed to parse file: " .. file)
    return
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
  local changes = {}

  -- Use iter_captures to properly handle capture groups
  for id, node, metadata in query_obj:iter_captures(root, bufnr) do
    if node then
      local capture_name = query_obj.captures[id]
      if capture_name == "module_name" then
        local success, name = pcall(vim.treesitter.get_node_text, node, bufnr)
        if not success then
          log.warn("Failed to get node text: " .. tostring(name))
          goto continue
        end

        if name:find "^%." then
          local rel_path = Path:new(file):make_relative(project_root)
          name = utils.absolute_dotted_path(rel_path, name)
        end

        if name:find("^" .. old_dotted_name) then
          local new_import = name:gsub("^" .. old_dotted_name, new_dotted_name)
          table.insert(
            changes,
            { node = node, old_import = name, new_import = new_import }
          )
        end
        ::continue::
      end
    end
  end

  for _, change in ipairs(changes) do
    local start_row, start_col, end_row, end_col = change.node:range()
    api.nvim_buf_set_text(
      bufnr,
      start_row,
      start_col,
      end_row,
      end_col,
      { change.new_import }
    )
  end

  -- Only write and format if there were changes
  if #changes > 0 then
    api.nvim_buf_call(bufnr, function()
      vim.cmd "write!"
      -- Check if conform is available before using it
      local success, conform = pcall(require, "conform")
      if success then
        conform.format()
      end
    end)
  end
end

return M
