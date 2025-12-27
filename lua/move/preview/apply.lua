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

  -- Separate move operation from import changes
  local move_operation = nil
  local import_changes = {}

  for _, change in ipairs(state.changes) do
    if change.type == "file_move" then
      move_operation = change
    else
      table.insert(import_changes, change)
    end
  end

  -- Filter accepted import changes
  local accepted_imports = vim.tbl_filter(function(change)
    return change.status == "accepted"
  end, import_changes)

  -- Check if anything is accepted
  local move_accepted = move_operation and move_operation.status == "accepted"
  if not move_accepted and #accepted_imports == 0 then
    log.warn "No changes accepted. Aborting."
    vim.notify("No changes were accepted", vim.log.levels.WARN)
    api.nvim_win_close(state.winid, true)
    return
  end

  local old_path = Path:new(state.project_root) / state.old_name
  local new_path = Path:new(state.project_root) / state.new_name

  -- Step 1: Move the file/directory (only if move operation is accepted)
  if move_accepted then
    if not old_path:exists() then
      log.error("Source file does not exist: " .. tostring(old_path))
      vim.notify(
        "Error: Source path does not exist:\n" .. tostring(old_path),
        vim.log.levels.ERROR
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
        log.error(
          "Destination exists but is not accessible: " .. dest_path_str
        )
        vim.notify(
          "Error: Destination exists but is not accessible by current user:\n"
            .. state.new_name
            .. "\n\nCheck file permissions or try running with sudo/appropriate permissions.",
          vim.log.levels.ERROR
        )
        api.nvim_win_close(state.winid, true)
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
        log.error("Failed to remove existing destination: " .. rm_output)
        vim.notify(
          "Failed to remove existing destination: "
            .. rm_output
            .. "\n\nYou may need appropriate permissions to overwrite this file.",
          vim.log.levels.ERROR
        )
        api.nvim_win_close(state.winid, true)
        return
      end

      if new_path:exists() then
        log.error "Destination still exists after removal attempt"
        vim.notify(
          "Failed to remove existing destination",
          vim.log.levels.ERROR
        )
        api.nvim_win_close(state.winid, true)
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
    log.info "File move operation declined - skipping file move"
  end

  -- Step 2: Update only accepted imports
  local updated_files = 0
  if #accepted_imports > 0 then
    -- Group accepted changes by file and update paths after move
    local old_path_str = tostring(old_path)
    local new_path_str = tostring(new_path)
    local changes_by_file = {}

    for _, change in ipairs(accepted_imports) do
      local file_path = change.file
      -- Update path if file was inside the moved directory (only if move happened)
      if move_accepted and file_path:sub(1, #old_path_str) == old_path_str then
        file_path = new_path_str .. file_path:sub(#old_path_str + 1)
      end

      if not changes_by_file[file_path] then
        changes_by_file[file_path] = {}
      end
      table.insert(changes_by_file[file_path], change)
    end

    -- Apply selective import updates per file using direct I/O
    for file, file_changes in pairs(changes_by_file) do
      local num_updates = refactor.update_specific_imports_direct(
        file,
        file_changes,
        state.project_root
      )
      if num_updates and num_updates > 0 then
        updated_files = updated_files + 1
      end
    end
  end

  -- Build success message
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
        "updated %d imports in %d files",
        #accepted_imports,
        updated_files
      )
    )
  end
  local success_msg = "✓ " .. table.concat(msg_parts, " and ")

  log.info(success_msg)
  vim.notify(success_msg, vim.log.levels.INFO)

  api.nvim_win_close(state.winid, true)
end

return M
