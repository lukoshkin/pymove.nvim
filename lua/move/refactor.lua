local api = vim.api
local fn = vim.fn
local filesystem = require "move.filesystem"
local imports = require "move.imports"
local search = require "move.search"

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
---@return string[]? List of file paths, nil on search failure
---@return string? error
function M.find_files_with_pattern(pattern, directory, extension)
  if fn.executable "rg" == 1 then
    return search.run {
      "rg",
      "--files-with-matches",
      "-g",
      extension,
      "-e",
      pattern,
      "--",
      directory,
    }
  end
  return search.run {
    "grep",
    "-rlE",
    "--include",
    extension,
    "-e",
    pattern,
    "--",
    directory,
  }
end

---Escape a string so gsub treats it as a literal replacement
---@param text string
---@return string
local function escape_replacement(text)
  return (text:gsub("%%", "%%%%"))
end

---Stage bytes beside the destination so a failed write cannot truncate it.
---@param file string
---@param content string
---@return boolean success
---@return string? error
local function write_replacement(file, content)
  local target, resolve_error = vim.uv.fs_realpath(file)
  if not target then
    return false, resolve_error
  end
  local temporary = target .. ".pymove-" .. fn.fnamemodify(fn.tempname(), ":t")
  local fd, open_error = io.open(temporary, "w")
  if not fd then
    return false, open_error
  end
  local written, write_error = fd:write(content)
  local closed, close_error = fd:close()
  local err = not written and write_error or not closed and close_error
  if not err and fn.setfperm(temporary, fn.getfperm(target)) == 0 then
    err = "cannot preserve file permissions"
  end
  if not err then
    local renamed, rename_error = vim.uv.fs_rename(temporary, target)
    if renamed then
      return true
    end
    err = rename_error
  end
  local removed, removal_error = os.remove(temporary)
  if not removed then
    err = err
      .. "; could not remove staging file "
      .. temporary
      .. ": "
      .. removal_error
  end
  return false, err
end

---Rewrite a file on disk, replacing import names on the given lines
---
---Edits are applied in place with Lua file IO rather than by shelling out to
---`patch`, so the result does not depend on an external binary, a writable
---temp directory, or fuzzy context matching.
---@param file string File path (absolute)
---@param edits table[] List of {line_num, old_text, new_text, start_col?, end_col?}
---@param backup boolean? Whether to keep a `.orig` copy of the file
---@param validate_only boolean? Check edits and write access without writing
---@return integer applied Number of edits written
---@return string? err Description of the edits that could not be applied
local function rewrite_import_lines(file, edits, backup, validate_only)
  local fd = io.open(file, validate_only and "r+" or "r")
  if not fd then
    return 0,
      "cannot open file for " .. (validate_only and "rewriting" or "reading")
  end
  local content, read_error = fd:read "*a"
  fd:close()
  if not content then
    return 0, "cannot read file: " .. read_error
  end

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
      and ("file changed since preview, no match on " .. table.concat(
        unmatched,
        ", "
      ))
    or nil

  if err then
    return 0, err
  end
  if validate_only or applied == 0 then
    return applied
  end

  if backup then
    local backup_fd = io.open(file .. ".orig", "w")
    if backup_fd then
      local written, write_error = backup_fd:write(content)
      local closed, close_error = backup_fd:close()
      if not written or not closed then
        return 0, "cannot write backup: " .. (write_error or close_error)
      end
    else
      return 0, "cannot write backup file"
    end
  end

  local written, write_error =
    write_replacement(file, table.concat(lines, "\n"))
  if not written then
    return 0, "cannot write file: " .. write_error
  end

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
---@param validate_only boolean? Check spans and write access without writing
---@return integer applied Number of imports rewritten
---@return string? error
function M.update_specific_imports_direct(
  file,
  specific_changes,
  project_root,
  backup,
  validate_only
)
  local log = get_log()

  if #specific_changes == 0 then
    return 0
  end

  local edits = {}
  for _, change in ipairs(specific_changes) do
    table.insert(edits, change_to_edit(change))
  end

  local applied, err = rewrite_import_lines(file, edits, backup, validate_only)
  if err then
    log.error(string.format("Failed to update imports in %s: %s", file, err))
  end

  return applied, err
end

---Check every proposed edit before moving the source or writing any importer.
---@param changes table[]
---@return boolean valid
---@return string? error
function M.validate_changes(changes)
  local by_file = {}
  for _, change in ipairs(changes) do
    if change.unfixable then
      return false,
        string.format("%s:%d: %s", change.file, change.line_num, change.reason)
    end
    by_file[change.file] = by_file[change.file] or {}
    table.insert(by_file[change.file], change)
  end
  for file, edits in pairs(by_file) do
    local count, err =
      M.update_specific_imports_direct(file, edits, nil, false, true)
    if count ~= #edits then
      return false, file .. ": " .. err
    end
  end
  return true
end

---Update imports in a file from old to new dotted name
---@param file string Path to the file
---@param old_dotted_name string Old import path
---@param new_dotted_name string New import path
---@param project_root string Project root directory
---@param backup boolean? Whether to create backup files (default: false)
---@param strategy "absolute"|"preserve"? How to spell rewritten relative imports
---@return integer applied Number of imports rewritten
---@return table[] unfixable Matches that need a manual edit
---@return table[] aliased Matches kept working by a synthesized alias
function M.update_imports_direct(
  file,
  old_dotted_name,
  new_dotted_name,
  project_root,
  backup,
  strategy
)
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
        vim.cmd "silent! bunload!"
      end)
    end
    return 0, {}, {}
  end

  local rel_path = filesystem.import_relative_path(project_root, file)
  local ok, matches = pcall(
    imports.find_matches,
    bufnr,
    rel_path,
    old_dotted_name,
    new_dotted_name
  )

  -- Clean up buffer (unload only, don't delete)
  if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd "silent! bunload!"
    end)
  end

  if not ok then
    log.warn(
      "Failed to scan imports in "
        .. file
        .. " -- if this is every file, run :TSInstall python"
    )
    return 0, {}, {}
  end

  local edits, unfixable, aliased = {}, {}, {}
  for _, match in ipairs(matches) do
    if match.unfixable then
      table.insert(unfixable, {
        file = file,
        line_num = match.line_num,
        reason = match.reason,
      })
    else
      imports.select_strategy(match, strategy or "absolute")
      table.insert(edits, change_to_edit(match))
      if match.aliased_name then
        table.insert(aliased, {
          file = file,
          line_num = match.line_num,
          aliased_name = match.aliased_name,
          aliased_to = match.aliased_to,
        })
      end
    end
  end

  if #edits == 0 then
    return 0, unfixable, aliased
  end

  local applied, err = rewrite_import_lines(file, edits, backup)
  if err then
    log.error(string.format("Failed to update imports in %s: %s", file, err))
  end

  return applied, unfixable, aliased
end

return M
