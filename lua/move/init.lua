local fn = vim.fn
local Path = require "plenary.path"
local filesystem = require "move.filesystem"
local config = require "pymove.config"
local refactor = require "move.refactor"
local report = require "move.report"
local utils = require "move.utils"
local imports = require "move.imports"
local collector = require "move.preview.collector"
local window = require "move.preview.window"

local M = {}

-- Global logger for the module
local log = require("plenary.log").new {
  plugin = "pymove-refactor",
  use_console = true,
}

---Move a Python module or package and update all imports
---@param old_name string Source module/package path
---@param new_name string Destination module/package path
---@param project_root string? Project root (defaults to cwd)
---@param options table? Options: dry_run, use_git
---@return boolean success
---@return string message
function M.move_module_or_package(old_name, new_name, project_root, options)
  options = options or {}
  local dry_run = options.dry_run or false
  local use_git = options.use_git

  project_root = project_root or filesystem.find_project_root()
  filesystem.reset_root_cache(options.import_root)

  -- Auto-detect git if not specified
  if use_git == nil then
    use_git = filesystem.is_git_repo(project_root)
  end

  log.info(
    string.format(
      "Moving Python module/package: %s -> %s (dry_run: %s, use_git: %s)",
      old_name,
      new_name,
      tostring(dry_run),
      tostring(use_git)
    )
  )

  -- Convert to absolute paths within project
  local old_path = Path:new(project_root) / old_name
  local new_path = Path:new(project_root) / new_name

  -- Validate the move is possible
  local valid, err =
    filesystem.validate_move_possible(tostring(old_path), tostring(new_path))
  if not valid then
    log.error("Cannot move module/package: " .. err)
    return false, err
  end

  -- Calculate import path changes. Dotted names come from each side's import
  -- root, not the filesystem root the paths are given against
  local resolved, names =
    pcall(filesystem.resolve_move_names, project_root, old_name, new_name)
  if not resolved then
    return false, tostring(names)
  end
  local old_dotted, new_dotted = names.old_dotted, names.new_dotted
  local supported, reason =
    imports.validate_relocation(tostring(old_path), old_dotted, new_dotted)
  if not supported then
    ---@cast reason string
    return false, reason
  end
  local change = utils.estimate_change(old_dotted, new_dotted)
  local pattern = utils.file_change_pattern(change, old_dotted)
  local files, search_error =
    refactor.find_files_with_pattern(pattern, project_root, "*.py")
  if not files then
    ---@cast search_error string
    return false, search_error
  end
  report.warn_rival_spellings(names.rivals, new_dotted)
  local strategy = report.resolve_strategy(
    options.relative_imports or config.options.move.relative_imports,
    names.inferred
  )

  local changes, by_file = {}, {}
  for _, file in ipairs(files) do
    local file_changes, scan_error = collector.process_file_changes(
      file,
      old_dotted,
      new_dotted,
      project_root,
      0,
      strategy
    )
    if not file_changes then
      ---@cast scan_error string
      return false, scan_error
    end
    by_file[file] = file_changes
    vim.list_extend(changes, file_changes)
  end
  local ready, preparation_error = refactor.validate_changes(changes)
  if not ready then
    ---@cast preparation_error string
    return false, preparation_error
  end

  if dry_run then
    log.info "DRY RUN - Would perform the following actions:"
    log.info(
      "  1. Move: " .. tostring(old_path) .. " -> " .. tostring(new_path)
    )
    log.info("  2. Update imports in " .. #files .. " files:")
    for _, file in ipairs(files) do
      log.info("     - " .. file)
    end
    log.info("  3. Import changes: " .. old_dotted .. " -> " .. new_dotted)
    return true, "Dry run completed successfully"
  end

  -- Step 1: Move the actual file/directory
  local move_success, move_err = filesystem.move_file_or_directory(
    tostring(old_path),
    tostring(new_path),
    use_git
  )
  if not move_success then
    log.error("Failed to move file/directory: " .. move_err)
    return false, move_err
  end

  -- Update file paths after move (files inside the moved directory have new paths)
  local old_path_str = tostring(old_path)
  local new_path_str = tostring(new_path)
  for i, file in ipairs(files) do
    if file == old_path_str then
      files[i] = new_path_str
    elseif file:sub(1, #old_path_str + 1) == old_path_str .. "/" then
      files[i] = new_path_str .. file:sub(#old_path_str + 1)
    end
    if files[i] ~= file then
      by_file[files[i]] = by_file[file]
      by_file[file] = nil
    end
  end

  -- Step 2: Update imports in all affected files with progress bar
  local updated_files, failures, aliased = 0, {}, {}

  if #files > 0 then
    local title = string.format(" Updating Imports (%d files) ", #files)
    local loading_bufnr, loading_winid = window.create_loading_window(title)

    for i, file in ipairs(files) do
      -- Update progress
      window.update_loading_progress(loading_bufnr, i - 1, #files, file)

      local file_changes = by_file[file]
      local num_changes, write_error = refactor.update_specific_imports_direct(
        file,
        file_changes,
        project_root,
        options.backup
      )
      if num_changes > 0 then
        updated_files = updated_files + 1
      end
      if num_changes ~= #file_changes then
        table.insert(failures, file .. ": " .. write_error)
      else
        for _, item in ipairs(file_changes) do
          item.file = file
          table.insert(aliased, item)
        end
      end
    end

    -- Final progress update
    window.update_loading_progress(loading_bufnr, #files, #files, nil)

    -- Brief pause to show completion before closing
    vim.cmd "redraw"
    vim.defer_fn(function()
      if vim.api.nvim_win_is_valid(loading_winid) then
        vim.api.nvim_win_close(loading_winid, true)
      end
    end, 500)
  end

  report.publish_aliases(aliased)

  vim.cmd "silent! checktime"
  if #failures > 0 then
    local message = "Source moved, but import updates failed:\n"
      .. table.concat(failures, "\n")
    vim.notify(message, vim.log.levels.ERROR)
    return false, message
  end

  local success_msg = string.format(
    "Moved %s → %s and updated %d files",
    old_name,
    new_name,
    updated_files
  )

  log.info(success_msg)
  vim.notify(success_msg, vim.log.levels.INFO)

  return true, success_msg
end

---Preview a move operation with interactive UI
---@param old_name string Source module/package path
---@param new_name string Destination module/package path
---@param project_root string? Project root (defaults to cwd)
---@param options table? Options: use_git
function M.preview_move(old_name, new_name, project_root, options)
  local preview = require "move.preview"
  preview.show_interactive_preview(old_name, new_name, project_root, options)
end

---Interactive move with user prompts
---Shows preview UI directly
function M.move_with_ui()
  local old_name = fn.input "Source module/package path: "
  if old_name == "" then
    return
  end

  local new_name = fn.input "Destination module/package path: "
  if new_name == "" then
    return
  end

  -- Always show preview UI
  M.preview_move(old_name, new_name)
end

return M
