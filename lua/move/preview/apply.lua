local api = vim.api
local Path = require "plenary.path"
local filesystem = require "move.filesystem"
local refactor = require "move.refactor"

local M = {}

---Get logger instance
---@return table Logger
local function get_log()
  return require("plenary.log").new {
    plugin = "pymove-preview-apply",
    use_console = true,
  }
end

---Apply only accepted changes
---@param state table PreviewState
function M.apply_accepted_changes(state)
  local log = get_log()

  local accepted = vim.tbl_filter(function(change)
    return change.status == "accepted"
  end, state.changes)

  if #accepted == 0 then
    log.warn "No changes accepted. Aborting."
    vim.notify("No changes were accepted", vim.log.levels.WARN)
    api.nvim_win_close(state.winid, true)
    return
  end

  -- Step 1: Move the file/directory (only if destination doesn't exist)
  local old_path = Path:new(state.project_root) / state.old_name
  local new_path = Path:new(state.project_root) / state.new_name

  if new_path:exists() then
    -- Destination already exists - skip move, just update imports
    log.info(
      string.format(
        "Destination already exists: %s. Skipping move, updating imports only.",
        tostring(new_path)
      )
    )
  elseif old_path:exists() then
    -- Normal case: move the file
    local move_success, move_err = filesystem.move_file_or_directory(
      tostring(old_path),
      tostring(new_path),
      state.use_git
    )

    if not move_success then
      log.error("Failed to move file/directory: " .. move_err)
      vim.notify("Failed to move: " .. move_err, vim.log.levels.ERROR)
      return
    end
  else
    -- Neither source nor destination exist - error
    log.error "Source file/directory does not exist"
    vim.notify("Error: Source path does not exist", vim.log.levels.ERROR)
    return
  end

  -- Step 2: Update only accepted imports
  -- Group accepted changes by file
  local changes_by_file = {}
  for _, change in ipairs(accepted) do
    if not changes_by_file[change.file] then
      changes_by_file[change.file] = {}
    end
    table.insert(changes_by_file[change.file], change)
  end

  -- Apply selective import updates per file
  local updated_files = 0
  for file, file_changes in pairs(changes_by_file) do
    local num_updates =
      refactor.update_specific_imports(file, file_changes, state.project_root)
    if num_updates and num_updates > 0 then
      updated_files = updated_files + 1
    end
  end

  log.info(
    string.format(
      "Successfully moved and updated %d imports in %d files",
      #accepted,
      updated_files
    )
  )

  vim.notify(
    string.format(
      "✓ Moved %s → %s and updated %d imports",
      state.old_name,
      state.new_name,
      #accepted
    ),
    vim.log.levels.INFO
  )

  api.nvim_win_close(state.winid, true)
end

return M
