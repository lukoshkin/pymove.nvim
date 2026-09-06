local api = vim.api
local Path = require "plenary.path"
local filesystem = require "move.filesystem"
local refactor = require "move.refactor"
local report = require "move.report"

local M = {}

local log = require("plenary.log").new {
  plugin = "pymove-preview-apply",
  use_console = true,
}

---Rewrite a path that lived under the moved source into its new location
---@param file_path string
---@param old_root string Absolute path the move started from
---@param new_root string Absolute path the move landed on
---@return string
local function remap_moved_path(file_path, old_root, new_root)
  if file_path == old_root then
    return new_root
  end
  if file_path:sub(1, #old_root + 1) == old_root .. "/" then
    return new_root .. file_path:sub(#old_root + 1)
  end
  return file_path
end

local function notify_error_and_close(message, state)
  log.error(message)
  vim.notify(message, vim.log.levels.ERROR)
  api.nvim_win_close(state.winid, true)
end

---Apply only accepted changes
---@param state table PreviewState
function M.apply_accepted_changes(state)
  local move_operation, import_changes = nil, {}
  for _, change in ipairs(state.changes) do
    if change.type == "file_move" then
      move_operation = change
    else
      table.insert(import_changes, change)
    end
  end

  local accepted_imports = vim.tbl_filter(function(change)
    return change.status == "accepted"
  end, import_changes)

  local move_accepted = move_operation and move_operation.status == "accepted"
  if not move_accepted and #accepted_imports == 0 then
    log.warn "No changes accepted"
    vim.notify("No changes were accepted", vim.log.levels.WARN)
    api.nvim_win_close(state.winid, true)
    return
  end

  local old_path = Path:new(state.project_root) / state.old_name
  local new_path = Path:new(state.project_root) / state.new_name

  if move_accepted then
    if not old_path:exists() then
      notify_error_and_close(
        "Error: Source path does not exist:\n" .. tostring(old_path),
        state
      )
      return
    end

    if new_path:exists() then
      local dest_path_str = tostring(new_path)
      local test_cmd = string.format(
        "test -w '%s' || test -w \"$(dirname '%s')\"",
        dest_path_str,
        dest_path_str
      )
      vim.fn.system(test_cmd)

      if vim.v.shell_error ~= 0 then
        notify_error_and_close(
          "Error: Destination exists but is not accessible by current user:\n"
            .. state.new_name
            .. "\n\nCheck file permissions or try running with sudo/appropriate permissions.",
          state
        )
        return
      end

      local response = vim.fn.confirm(
        "Destination already exists: " .. state.new_name .. "\nOverwrite?",
        "&Yes\n&No",
        2
      )
      if response ~= 1 then
        log.info "User cancelled move due to existing destination"
        vim.notify("Move cancelled", vim.log.levels.INFO)
        api.nvim_win_close(state.winid, true)
        return
      end

      log.info("Removing existing destination: " .. dest_path_str)
      local rm_cmd
      if new_path:is_dir() then
        rm_cmd = string.format("rm -rf '%s'", dest_path_str)
      else
        rm_cmd = string.format("rm -f '%s'", dest_path_str)
      end

      local rm_output = vim.fn.system(rm_cmd)
      if vim.v.shell_error ~= 0 then
        notify_error_and_close(
          "Failed to remove existing destination: "
            .. rm_output
            .. "\n\nYou may need appropriate permissions to overwrite this file.",
          state
        )
        return
      end

      if new_path:exists() then
        notify_error_and_close("Failed to remove existing destination", state)
        return
      end
      log.info "Successfully removed existing destination"
    end

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
    log.info(string.format("Moved %s → %s", state.old_name, state.new_name))
  else
    log.info "File move operation declined"
  end
  local updated_files, updated_imports, failed_files = 0, 0, 0
  if #accepted_imports > 0 then
    local old_path_str, new_path_str = tostring(old_path), tostring(new_path)
    local changes_by_file = {}

    for _, change in ipairs(accepted_imports) do
      local file_path = change.file
      if move_accepted then
        file_path = remap_moved_path(file_path, old_path_str, new_path_str)
      end

      changes_by_file[file_path] = changes_by_file[file_path] or {}
      table.insert(changes_by_file[file_path], change)
    end

    for file, file_changes in pairs(changes_by_file) do
      local num_updates = refactor.update_specific_imports_direct(
        file,
        file_changes,
        state.project_root,
        state.backup
      ) or 0
      if num_updates > 0 then
        updated_files = updated_files + 1
        updated_imports = updated_imports + num_updates
      end
      if num_updates < #file_changes then
        failed_files = failed_files + 1
      end
    end

    -- Files were rewritten on disk; refresh any buffers holding stale copies
    vim.cmd "silent! checktime"

    report.publish_aliases(accepted_imports)
  end

  local msg_parts = {}
  if move_accepted then
    table.insert(
      msg_parts,
      string.format("Moved %s → %s", state.old_name, state.new_name)
    )
  end
  if #accepted_imports > 0 then
    table.insert(
      msg_parts,
      string.format(
        "updated %d of %d imports in %d files",
        updated_imports,
        #accepted_imports,
        updated_files
      )
    )
  end

  if failed_files > 0 then
    local failure_msg = string.format(
      "%s (%d file(s) failed -- see :messages for details)",
      table.concat(msg_parts, " and "),
      failed_files
    )
    log.error(failure_msg)
    vim.notify(failure_msg, vim.log.levels.ERROR)
  else
    local success_msg = "✓ " .. table.concat(msg_parts, " and ")
    log.info(success_msg)
    vim.notify(success_msg, vim.log.levels.INFO)
  end

  api.nvim_win_close(state.winid, true)
end

return M
