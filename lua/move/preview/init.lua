---@class ChangePreview
---@field file string File path
---@field line_num integer Line number of the import
---@field old_import string Original import statement
---@field new_import string New import statement
---@field context_before string[] Lines before the change
---@field context_after string[] Lines after the change
---@field status "pending"|"accepted"|"declined"
---@field buffer_line integer Line in preview buffer where change starts
---@field node_range table Treesitter node range for precise updating

---@class PreviewState
---@field changes ChangePreview[] All changes to preview
---@field current_index integer Current change being viewed (1-indexed)
---@field bufnr integer Preview buffer number
---@field winid integer Preview window ID
---@field old_name string Source module path
---@field new_name string Destination module path
---@field project_root string Project root directory
---@field use_git boolean Whether to use git mv
---@field namespace integer Extmark namespace
---@field truncated boolean? Whether file list was truncated
---@field total_files integer? Total number of files found

local api = vim.api
local fn = vim.fn

local apply = require "move.preview.apply"
local collector = require "move.preview.collector"
local filesystem = require "move.filesystem"
local keymaps = require "move.preview.keymaps"
local refactor = require "move.refactor"
local state_mod = require "move.preview.state"
local utils = require "move.utils"
local window = require "move.preview.window"

local M = {}

---Get logger instance
---@return table Logger
local function get_log()
  return require("plenary.log").new {
    plugin = "pymove-preview",
    use_console = true,
  }
end

---Show interactive preview for module move
---@param old_name string Source module path
---@param new_name string Destination module path
---@param project_root string? Project root
---@param options table? Options (use_git, max_files)
function M.show_interactive_preview(old_name, new_name, project_root, options)
  local log = get_log()
  options = options or {}
  project_root = project_root or filesystem.find_project_root()

  local use_git = options.use_git
  if use_git == nil then
    use_git = filesystem.is_git_repo(project_root)
  end

  -- Validate that source exists before showing preview
  local Path = require "plenary.path"
  local old_path = Path:new(project_root) / old_name
  local new_path = Path:new(project_root) / new_name

  if not old_path:exists() then
    log.error(
      "Cannot preview move: Source path does not exist: " .. tostring(old_path)
    )
    vim.notify(
      "Cannot preview move: Source does not exist: " .. old_name,
      vim.log.levels.ERROR
    )
    return
  end

  -- Warn if destination already exists (don't block, just warn)
  local dest_exists = new_path:exists()
  if dest_exists then
    log.warn("Warning: Destination already exists: " .. tostring(new_path))
  end

  -- File limit to prevent processing too many files at once
  local max_files = options.max_files or 200

  -- Collect files that might need updates
  local old_dotted = utils.path_to_dotted_name(old_name)
  local new_dotted = utils.path_to_dotted_name(new_name)
  local change = utils.estimate_change(old_dotted, new_dotted)
  local pattern = utils.file_change_pattern(change)
  local all_files =
    refactor.find_files_with_pattern(pattern, project_root, "*.py")

  if #all_files == 0 then
    log.info "No import changes detected."
    vim.notify("No imports to update", vim.log.levels.INFO)
    return
  end

  -- Limit files if necessary
  local files = all_files
  local truncated = false
  if #all_files > max_files then
    files = vim.list_slice(all_files, 1, max_files)
    truncated = true
    vim.notify(
      string.format(
        "Processing first %d of %d files (limit: max_files=%d)",
        max_files,
        #all_files,
        max_files
      ),
      vim.log.levels.WARN
    )
  end

  -- Check for swap files before proceeding
  local swap_files = collector.check_swap_files(files)
  if #swap_files > 0 then
    -- Create a buffer to display swap file information
    local swap_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[swap_bufnr].filetype = "text"
    vim.bo[swap_bufnr].bufhidden = "wipe"

    local msg_lines = {
      "WARNING: Active swap files detected",
      "=" .. string.rep("=", 50),
      "",
      "The following files have active swap files:",
      "",
    }
    for _, swap_info in ipairs(swap_files) do
      table.insert(msg_lines, "File:     " .. swap_info.file)
      table.insert(msg_lines, "Swap:     " .. swap_info.swap_path)
      table.insert(msg_lines, "")
    end
    table.insert(msg_lines, string.rep("-", 50))
    table.insert(msg_lines, "")
    table.insert(msg_lines, "This may indicate:")
    table.insert(
      msg_lines,
      "  • Files are open in other Neovim instances/terminals"
    )
    table.insert(msg_lines, "  • Previous editing sessions crashed")
    table.insert(msg_lines, "")
    table.insert(msg_lines, "Proceeding may cause conflicts or data loss.")
    table.insert(msg_lines, "")

    vim.api.nvim_buf_set_lines(swap_bufnr, 0, -1, false, msg_lines)
    vim.bo[swap_bufnr].modifiable = false

    -- Open in a split window
    vim.cmd "split"
    local swap_winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(swap_winid, swap_bufnr)
    vim.api.nvim_win_set_height(swap_winid, math.min(#msg_lines + 1, 20))

    -- Ask user if they want to proceed
    local response = vim.fn.confirm(
      "Active swap files detected. Do you want to proceed anyway?",
      "&Yes\n&No",
      2 -- Default to No
    )

    -- Close the info window
    if vim.api.nvim_win_is_valid(swap_winid) then
      vim.api.nvim_win_close(swap_winid, true)
    end

    if response ~= 1 then
      log.info "User cancelled due to swap files"
      vim.notify("Operation cancelled", vim.log.levels.INFO)
      return
    end

    log.warn(
      string.format(
        "User chose to proceed despite %d swap files",
        #swap_files
      )
    )
  end

  -- Setup highlights
  window.setup_highlights()

  -- Show loading window
  local loading_bufnr, loading_winid = window.create_loading_window()
  window.update_loading_progress(loading_bufnr, 0, #files, nil)

  -- Collect changes asynchronously with progress updates
  collector.collect_changes_async(
    old_dotted,
    new_dotted,
    files,
    project_root,
    function(current, total, file)
      -- Progress callback
      if api.nvim_win_is_valid(loading_winid) then
        window.update_loading_progress(loading_bufnr, current, total, file)
      end
    end,
    function(changes)
      -- Completion callback
      -- Close loading window
      if api.nvim_win_is_valid(loading_winid) then
        api.nvim_win_close(loading_winid, true)
      end

      if #changes == 0 then
        log.info "No matching imports found."
        vim.notify("No matching imports found", vim.log.levels.INFO)
        return
      end

      -- Create preview window
      local bufnr, winid = window.create_floating_window()

      -- Add file move operation as first "change"
      local move_operation = {
        type = "file_move",
        file = tostring(old_path),
        old_name = old_name,
        new_name = new_name,
        status = "pending", -- Default to pending (user must explicitly accept)
        buffer_line = 4, -- Line where move operation is shown (after header)
        dest_exists = dest_exists,
        use_git = use_git,
      }
      table.insert(changes, 1, move_operation)

      -- Create state
      local state = {
        changes = changes,
        current_index = 1,
        bufnr = bufnr,
        winid = winid,
        old_name = old_name,
        new_name = new_name,
        project_root = project_root,
        use_git = use_git,
        backup = options.backup or false,
        namespace = api.nvim_create_namespace "pymove-preview",
        truncated = truncated,
        total_files = #all_files,
      }

      -- Build buffer and setup keymaps
      state_mod.build_preview_buffer(state)
      keymaps.setup_keymaps(state, apply.apply_accepted_changes)

      -- Jump to first change after everything is rendered
      vim.schedule(function()
        if not api.nvim_win_is_valid(state.winid) then
          return
        end
        if not api.nvim_buf_is_valid(state.bufnr) then
          return
        end
        state_mod.jump_to_change(state, 1, true)
        window.update_winbar(state.winid)
      end)
    end
  )
end

return M
