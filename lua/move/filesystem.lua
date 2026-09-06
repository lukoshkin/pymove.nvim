local fn = vim.fn
local Path = require "plenary.path"

local M = {}

-- Get logger from parent module
local function get_log()
  return require("plenary.log").new {
    plugin = "pymove-refactor",
    use_console = true,
  }
end

---Find the project root by searching for common markers
---@param start_path string? Starting path (defaults to current buffer's directory)
---@return string? Project root path
function M.find_project_root(start_path)
  start_path = start_path or fn.expand "%:p:h"
  local current = Path:new(start_path)

  -- Project root markers, in order of priority
  local markers = {
    ".git",
    "pyproject.toml",
    "setup.py",
    "setup.cfg",
    "requirements.txt",
    "Pipfile",
    "poetry.lock",
  }

  -- Walk up the directory tree
  while current do
    for _, marker in ipairs(markers) do
      local marker_path = current / marker
      if marker_path:exists() then
        return tostring(current)
      end
    end

    local parent = current:parent()
    if not parent or tostring(parent) == tostring(current) then
      break
    end
    current = parent
  end

  -- Fallback to cwd if no markers found
  return fn.getcwd()
end

---Find the first directory between the project root and a module that is not a
---package
---
---Dotted names are derived from the path relative to the project root, but that
---root is found by `.git` / `pyproject.toml`, which in a src layout sits one
---level above the importable package. When any directory on the way down lacks
---an `__init__.py`, the dotted name built from it is not importable -- `src` in
---`src/mypkg/utils.py` being the common case.
---@param project_root string
---@param rel_path string Module path relative to the project root
---@return string? offender Relative path of the first non-package directory
function M.first_non_package_dir(project_root, rel_path)
  local dir = rel_path:gsub("/+$", ""):match "^(.*)/[^/]*$"
  if not dir or dir == "" or dir == "." then
    return nil
  end

  local walked = {}
  for part in dir:gmatch "[^/]+" do
    table.insert(walked, part)
    local as_path = table.concat(walked, "/")
    local init = Path:new(project_root) / as_path / "__init__.py"
    if not init:exists() then
      return as_path
    end
  end

  return nil
end

---Check if a directory is a git repository
---@param project_root string
---@return boolean
function M.is_git_repo(project_root)
  local git_dir = Path:new(project_root) / ".git"
  return git_dir:exists()
end

---Validate that a move operation is possible
---@param old_path string Source path
---@param new_path string Destination path
---@return boolean success
---@return string? error
function M.validate_move_possible(old_path, new_path)
  local log = get_log()
  local old_full_path = Path:new(old_path)
  local new_full_path = Path:new(new_path)

  if not old_full_path:exists() then
    return false, "Source path does not exist: " .. tostring(old_full_path)
  end

  if new_full_path:exists() then
    return false,
      "Destination path already exists: " .. tostring(new_full_path)
  end

  if old_full_path:is_file() and not old_path:match "%.py$" then
    return false, "Source file is not a Python file: " .. old_path
  end

  if old_full_path:is_dir() then
    local init_file = old_full_path / "__init__.py"
    if not init_file:exists() then
      log.warn(
        "Source directory is not a Python package (no __init__.py): "
          .. old_path
      )
    end
  end

  return true, nil
end

---Create parent directories for a file path if they don't exist
---@param file_path string
---@return boolean success
---@return string? error
function M.create_parent_dirs(file_path)
  local log = get_log()
  local path = Path:new(file_path)
  local parent = path:parent()

  if not parent:exists() then
    local success, err = parent:mkdir { parents = true }
    if not success then
      return false, "Failed to create parent directories: " .. tostring(err)
    end
    log.info("Created parent directories: " .. tostring(parent))
  end

  return true, nil
end

---Move a file or directory, optionally using git mv
---@param old_path string Source path
---@param new_path string Destination path
---@param use_git boolean Whether to try git mv first
---@return boolean success
---@return string? error
function M.move_file_or_directory(old_path, new_path, use_git)
  local log = get_log()
  local old_full_path = Path:new(old_path)
  local new_full_path = Path:new(new_path)

  -- Create parent directories for destination
  local success, err = M.create_parent_dirs(new_path)
  if not success then
    return false, err
  end

  if use_git then
    -- Try git mv first
    local git_cmd = string.format("git mv '%s' '%s'", old_path, new_path)
    local output = fn.system(git_cmd)
    if vim.v.shell_error == 0 then
      log.info(
        "Successfully moved using git: " .. old_path .. " -> " .. new_path
      )
      return true, nil
    else
      log.warn("Git mv failed, falling back to filesystem move: " .. output)
    end
  end

  -- Fallback to filesystem move
  local success, err = pcall(function()
    old_full_path:rename { new_name = tostring(new_full_path) }
  end)

  if success then
    log.info("Successfully moved: " .. old_path .. " -> " .. new_path)
    return true, nil
  else
    return false, "Failed to move file/directory: " .. tostring(err)
  end
end

return M
