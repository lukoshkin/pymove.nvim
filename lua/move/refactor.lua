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

---Generate unified diff patch for a file
---@param file string File path (absolute)
---@param changes table[] List of {line_num, old_text, new_text}
---@param project_root string Project root for relative paths
---@return string|nil patch Unified diff patch or nil on error
local function generate_patch(file, changes, project_root)
  -- Read original file
  local f = io.open(file, "r")
  if not f then
    return nil
  end

  local lines = {}
  for line in f:lines() do
    table.insert(lines, line)
  end
  f:close()

  -- Apply changes to create modified version
  local modified_lines = vim.deepcopy(lines)

  -- Sort changes by line number (descending) to maintain positions
  table.sort(changes, function(a, b)
    return a.line_num > b.line_num
  end)

  for _, change in ipairs(changes) do
    local line_idx = change.line_num
    if line_idx > 0 and line_idx <= #modified_lines then
      local old_line = modified_lines[line_idx]
      -- Replace the old import with new import in the line
      local new_line = old_line:gsub(
        vim.pesc(change.old_text),
        change.new_text
      )
      modified_lines[line_idx] = new_line
    end
  end

  -- Make file path relative to project root
  local rel_file = Path:new(file):make_relative(project_root)

  -- Generate unified diff
  local patch_lines = {}
  table.insert(patch_lines, "--- " .. rel_file)
  table.insert(patch_lines, "+++ " .. rel_file)

  -- Find hunks (consecutive changed lines)
  local hunks = {}
  local in_hunk = false
  local hunk_start = nil

  for i = 1, #lines do
    if lines[i] ~= modified_lines[i] then
      if not in_hunk then
        hunk_start = i
        in_hunk = true
      end
    else
      if in_hunk then
        table.insert(hunks, { start = hunk_start, ["end"] = i - 1 })
        in_hunk = false
      end
    end
  end

  if in_hunk then
    table.insert(hunks, { start = hunk_start, ["end"] = #lines })
  end

  -- Generate hunk content with context
  local context = 3
  for _, hunk in ipairs(hunks) do
    local start_line = math.max(1, hunk.start - context)
    local end_line = math.min(#lines, hunk["end"] + context)

    local orig_count = end_line - start_line + 1
    local new_count = orig_count -- Same for line replacements

    table.insert(
      patch_lines,
      string.format("@@ -%d,%d +%d,%d @@", start_line, orig_count, start_line, new_count)
    )

    for i = start_line, end_line do
      if i >= hunk.start and i <= hunk["end"] and lines[i] ~= modified_lines[i] then
        table.insert(patch_lines, "-" .. lines[i])
        table.insert(patch_lines, "+" .. modified_lines[i])
      else
        table.insert(patch_lines, " " .. lines[i])
      end
    end
  end

  return table.concat(patch_lines, "\n")
end

---Update specific imports in a file by line numbers (patch-based approach)
---@param file string Path to the file
---@param specific_changes table[] List of changes with file, line_num, old_import, new_import
---@param project_root string Project root directory
---@param backup boolean? Whether to create backup files (default: false)
function M.update_specific_imports_direct(file, specific_changes, project_root, backup)
  local log = get_log()

  if #specific_changes == 0 then
    return 0
  end

  -- Convert to patch format
  local patch_changes = {}
  for _, change in ipairs(specific_changes) do
    table.insert(patch_changes, {
      line_num = change.line_num,
      old_text = change.old_import,
      new_text = change.new_import,
    })
  end

  -- Generate patch
  local patch = generate_patch(file, patch_changes, project_root)
  if not patch then
    log.warn("Failed to generate patch for file: " .. file)
    return 0
  end

  -- Write patch to temporary file
  local patch_file = fn.tempname() .. ".patch"
  local f = io.open(patch_file, "w")
  if not f then
    log.error("Failed to create temp patch file")
    return 0
  end
  f:write(patch)
  f:close()

  -- Apply patch using patch command (p0 = no path stripping)
  local backup_flag = backup and "--backup" or "--no-backup"
  local cmd = string.format(
    "cd %s && patch -s -p0 %s < %s",
    vim.fn.shellescape(project_root),
    backup_flag,
    vim.fn.shellescape(patch_file)
  )
  local result = fn.system(cmd)
  local exit_code = vim.v.shell_error

  -- Clean up temp file
  fn.delete(patch_file)

  if exit_code ~= 0 then
    log.error(string.format("Failed to apply patch: %s", result))
    return 0
  end

  return #specific_changes
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

---Update imports in a file from old to new dotted name (patch-based approach)
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
      (dotted_name) @module_name)
  ]]
  local query_obj = get_cached_query("python", query_string)
  local patch_changes = {}

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

        if name:find("^" .. old_dotted_name) then
          local new_import = name:gsub("^" .. old_dotted_name, new_dotted_name)
          local start_row, _, _, _ = node:range()
          table.insert(patch_changes, {
            line_num = start_row + 1, -- 1-indexed
            old_text = name,
            new_text = new_import,
          })
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

  if #patch_changes == 0 then
    return 0
  end

  -- Generate and apply patch
  local patch = generate_patch(file, patch_changes, project_root)
  if not patch then
    log.warn("Failed to generate patch for file: " .. file)
    return 0
  end

  local patch_file = fn.tempname() .. ".patch"
  local f = io.open(patch_file, "w")
  if not f then
    log.error("Failed to create temp patch file")
    return 0
  end
  f:write(patch)
  f:close()

  -- Apply patch using patch command (p0 = no path stripping)
  local backup_flag = backup and "--backup" or "--no-backup"
  local cmd = string.format(
    "cd %s && patch -s -p0 %s < %s",
    vim.fn.shellescape(project_root),
    backup_flag,
    vim.fn.shellescape(patch_file)
  )
  local result = fn.system(cmd)
  local exit_code = vim.v.shell_error

  fn.delete(patch_file)

  if exit_code ~= 0 then
    log.error(string.format("Failed to apply patch (exit code %d): %s", exit_code, result))
    return 0
  end

  return #patch_changes
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
