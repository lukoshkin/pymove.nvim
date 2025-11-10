local fn = vim.fn
local Path = require "plenary.path"
local utils = require "move.utils"
local refactor = require "move.refactor"
local filesystem = require "move.filesystem"

local M = {}

-- Global logger for the module
log = require("plenary.log").new {
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

  project_root = project_root or fn.getcwd()

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

  -- Calculate import path changes
  local old_dotted = utils.path_to_dotted_name(old_name)
  local new_dotted = utils.path_to_dotted_name(new_name)
  local change = utils.estimate_change(old_dotted, new_dotted)
  local pattern = utils.file_change_pattern(change)
  local files = refactor.find_files_with_pattern(pattern, project_root, "*.py")

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

  -- Step 2: Update imports in all affected files
  local updated_files = 0
  for _, file in ipairs(files) do
    local before_update = fn.getftime(file)
    refactor.update_imports(file, old_dotted, new_dotted, project_root)
    local after_update = fn.getftime(file)

    if after_update > before_update then
      updated_files = updated_files + 1
    end
  end

  log.info(
    string.format(
      "Successfully moved module/package and updated imports in %d files",
      updated_files
    )
  )
  return true,
    string.format(
      "Moved %s -> %s and updated %d files",
      old_name,
      new_name,
      updated_files
    )
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
