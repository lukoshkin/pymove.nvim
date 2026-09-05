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

---Escape a string so gsub treats it as a literal replacement
---@param text string
---@return string
local function escape_replacement(text)
  return (text:gsub("%%", "%%%%"))
end

---Rewrite a file on disk, replacing import names on the given lines
---
---Edits are applied in place with Lua file IO rather than by shelling out to
---`patch`, so the result does not depend on an external binary, a writable
---temp directory, or fuzzy context matching.
---@param file string File path (absolute)
---@param edits table[] List of {line_num, old_text, new_text, start_col?, end_col?}
---@param backup boolean? Whether to keep a `.orig` copy of the file
---@return integer applied Number of edits written
---@return string? err Description of the edits that could not be applied
local function rewrite_import_lines(file, edits, backup)
  local fd = io.open(file, "r")
  if not fd then
    return 0, "cannot read file"
  end
  local content = fd:read "*a"
  fd:close()

  local lines = vim.split(content, "\n", { plain = true })

  -- Right-to-left so that column offsets of pending edits stay valid
  table.sort(edits, function(a, b)
    if a.line_num ~= b.line_num then
      return a.line_num > b.line_num
    end
    return (a.start_col or 0) > (b.start_col or 0)
  end)

  local applied, unmatched = 0, {}
  for _, edit in ipairs(edits) do
    local line = lines[edit.line_num]
    local updated = nil

    if line then
      local from, to = edit.start_col, edit.end_col
      if from and to then
        -- A stale range means the file changed after the preview was built;
        -- report it rather than rewriting whatever now sits on that line
        if line:sub(from + 1, to) == edit.old_text then
          updated = line:sub(1, from) .. edit.new_text .. line:sub(to + 1)
        end
      elseif line:find(edit.old_text, 1, true) then
        updated = line:gsub(
          vim.pesc(edit.old_text),
          escape_replacement(edit.new_text),
          1
        )
      end
    end

    if updated then
      lines[edit.line_num] = updated
      applied = applied + 1
    else
      table.insert(
        unmatched,
        string.format("line %d (%s)", edit.line_num, edit.old_text)
      )
    end
  end

  local err = #unmatched > 0
      and (
        "file changed since preview, no match on "
        .. table.concat(unmatched, ", ")
      )
    or nil

  if applied == 0 then
    return 0, err
  end

  if backup then
    local backup_fd = io.open(file .. ".orig", "w")
    if backup_fd then
      backup_fd:write(content)
      backup_fd:close()
    else
      return 0, "cannot write backup file"
    end
  end

  local out = io.open(file, "w")
  if not out then
    return 0, "cannot write file"
  end
  out:write(table.concat(lines, "\n"))
  out:close()

  return applied, err
end

---Build a line edit out of a collected import change
---@param change table Change with line_num, old_import, new_import, node_range?
---@return table edit
local function change_to_edit(change)
  local edit = {
    line_num = change.line_num,
    old_text = change.old_import,
    new_text = change.new_import,
  }
  local range = change.node_range
  if range and range[1] == range[3] then
    edit.start_col, edit.end_col = range[2], range[4]
  end
  return edit
end

---Update specific imports in a file by line numbers
---@param file string Path to the file
---@param specific_changes table[] List of changes with file, line_num, old_import, new_import
---@param project_root string? Unused, kept for call-site compatibility
---@param backup boolean? Whether to create backup files (default: false)
---@return integer applied Number of imports rewritten
function M.update_specific_imports_direct(file, specific_changes, project_root, backup)
  local log = get_log()

  if #specific_changes == 0 then
    return 0
  end

  local edits = {}
  for _, change in ipairs(specific_changes) do
    table.insert(edits, change_to_edit(change))
  end

  local applied, err = rewrite_import_lines(file, edits, backup)
  if err then
    log.error(string.format("Failed to update imports in %s: %s", file, err))
  end

  return applied
end

---Update specific imports in a file by line numbers
---@param file string Path to the file
---@param specific_changes table[] List of changes with file, line_num, old_import, new_import
---@param project_root string Project root directory
function M.update_specific_imports(file, specific_changes, project_root)
  local log = get_log()
  local bufnr = fn.bufadd(file)

  -- Suppress swap file prompts during buffer load
  local old_shortmess = vim.o.shortmess
  vim.o.shortmess = vim.o.shortmess .. "A"

  local load_success = pcall(fn.bufload, bufnr)

  -- Restore original shortmess setting
  vim.o.shortmess = old_shortmess

  if not load_success then
    log.warn("Failed to load buffer for file: " .. file)
    return 0
  end

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
      name: (dotted_name) @module_name)
    (import_statement
      name: (aliased_import
        name: (dotted_name) @module_name))
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
---@param backup boolean? Whether to create backup files (default: false)
function M.update_imports_direct(file, old_dotted_name, new_dotted_name, project_root, backup)
  local log = get_log()

  -- Use buffer to find changes with treesitter
  local bufnr = fn.bufadd(file)

  -- Suppress swap file prompts during buffer load
  local old_shortmess = vim.o.shortmess
  vim.o.shortmess = vim.o.shortmess .. "A"

  local load_success = pcall(fn.bufload, bufnr)

  -- Restore original shortmess setting
  vim.o.shortmess = old_shortmess

  if not load_success then
    log.warn("Failed to load buffer for file: " .. file)
    if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
      pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent! bunload!")
      end)
    end
    return 0
  end

  local success, parser = pcall(vim.treesitter.get_parser, bufnr, "python")
  if not success then
    log.warn("Failed to get parser for file: " .. file)
    if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
      pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent! bunload!")
      end)
    end
    return 0
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    log.warn("Failed to parse file: " .. file)
    if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
      pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent! bunload!")
      end)
    end
    return 0
  end

  local tree = trees[1]
  local root = tree:root()
  local query_string = [[
    (import_from_statement
      module_name: (dotted_name) @module_name)
    (import_statement
      name: (dotted_name) @module_name)
    (import_statement
      name: (aliased_import
        name: (dotted_name) @module_name))
  ]]
  local query_obj = get_cached_query("python", query_string)
  local edits = {}

  -- Collect changes using treesitter
  for id, node, metadata in query_obj:iter_captures(root, bufnr) do
    if node then
      local capture_name = query_obj.captures[id]
      if capture_name == "module_name" then
        local success, name = pcall(vim.treesitter.get_node_text, node, bufnr)
        if not success then
          goto continue
        end

        if name:find "^%." then
          local rel_path = Path:new(file):make_relative(project_root)
          name = utils.absolute_dotted_path(rel_path, name)
        end

        local new_import =
          utils.rename_dotted_prefix(name, old_dotted_name, new_dotted_name)
        if new_import then
          local start_row, start_col, end_row, end_col = node:range()
          table.insert(
            edits,
            change_to_edit {
              line_num = start_row + 1, -- 1-indexed
              old_import = name,
              new_import = new_import,
              node_range = { start_row, start_col, end_row, end_col },
            }
          )
        end
        ::continue::
      end
    end
  end

  -- Clean up buffer (unload only, don't delete)
  if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("silent! bunload!")
    end)
  end

  if #edits == 0 then
    return 0
  end

  local applied, err = rewrite_import_lines(file, edits, backup)
  if err then
    log.error(string.format("Failed to update imports in %s: %s", file, err))
  end

  return applied
end

---Update imports in a file from old to new dotted name
---@param file string Path to the file
---@param old_dotted_name string Old import path
---@param new_dotted_name string New import path
---@param project_root string Project root directory
function M.update_imports(file, old_dotted_name, new_dotted_name, project_root)
  local log = get_log()
  local bufnr = fn.bufadd(file)

  -- Suppress swap file prompts during buffer load
  local old_shortmess = vim.o.shortmess
  vim.o.shortmess = vim.o.shortmess .. "A"

  local load_success = pcall(fn.bufload, bufnr)

  -- Restore original shortmess setting
  vim.o.shortmess = old_shortmess

  if not load_success then
    log.warn("Failed to load buffer for file: " .. file)
    return 0
  end

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
      name: (dotted_name) @module_name)
    (import_statement
      name: (aliased_import
        name: (dotted_name) @module_name))
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
