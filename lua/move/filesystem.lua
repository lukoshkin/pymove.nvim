local fn = vim.fn
local Path = require "plenary.path"
local config = require "pymove.config"
local utils = require "move.utils"
local search = require "move.search"

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
---@return string Project root path
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

---Import roots are a property of a directory, so files under one share an
---answer. Reset between operations, since a move changes the tree underneath.
local root_cache = {}

---Roots settled for the move in progress, and the project they belong to.
---Every file under one is named from it, so no file needs its own lookup.
local decided = { project_root = nil, roots = {} }

---Forget every import root worked out so far
function M.reset_root_cache()
  root_cache = {}
  decided = { project_root = nil, roots = {} }
end

---@param project_root string
---@param rel_dir string
---@return boolean
local function is_package_dir(project_root, rel_dir)
  if rel_dir == "" then
    return false
  end
  return (Path:new(project_root) / rel_dir / "__init__.py"):exists()
end

---Every directory a module could plausibly be named from
---
---Ordered shallowest first, from the project root down. The walk stops at the
---first package: a directory carrying an `__init__.py` is part of a module's
---name, never the place a name starts, and nothing inside a package can be a
---root either. Without that stop, `mypkg/logging.py` would offer `mypkg` as a
---candidate whose spelling is the bare name `logging` -- and then every
---`import logging` in the project would look like evidence for it.
---@param project_root string
---@param rel_dir string
---@return string[]
local function candidate_roots(project_root, rel_dir)
  local roots, parts = { "" }, {}
  for part in rel_dir:gmatch "[^/]+" do
    table.insert(parts, part)
    local candidate = table.concat(parts, "/")
    if is_package_dir(project_root, candidate) then
      break
    end
    table.insert(roots, candidate)
  end
  return roots
end

---Import root implied by the package chain alone
---
---A source root's parent is never itself a package, so the topmost ancestor
---carrying an `__init__.py` fixes where naming starts: everything at or below it
---is package structure, and its parent is the root. When no ancestor is a
---package there is nothing to anchor to and the project root is the only answer
----- which is also the right one for a PEP 420 tree, whose directories are all
---part of the name.
---@param project_root string
---@param rel_dir string
---@return string
local function structural_import_root(project_root, rel_dir)
  local parts, walked = {}, {}
  for part in rel_dir:gmatch "[^/]+" do
    table.insert(walked, part)
    table.insert(parts, table.concat(walked, "/"))
  end
  for i = 1, #parts do
    if is_package_dir(project_root, parts[i]) then
      return i == 1 and "" or parts[i - 1]
    end
  end
  return ""
end

---Modules whose spelling can be looked up to place a directory's import root
---
---The module being moved is the first probe, but on its own it is a poor one:
---something nobody imports yet -- a brand-new file, or a package's private
---helper -- carries no evidence at all, while its neighbours usually do. They
---share a directory, so they share a root.
---@param project_root string
---@param rel_dir string
---@param rel_path string The module being named
---@return string[]
local function probe_modules(project_root, rel_dir, rel_path)
  local probes, seen = { rel_path }, { [rel_path] = true }
  local dir = rel_dir == "" and project_root
    or tostring(Path:new(project_root) / rel_dir)

  for _, abs in ipairs(fn.glob(dir .. "/*.py", false, true)) do
    if #probes >= 6 then
      break
    end
    local rel = Path:new(abs):make_relative(project_root)
    if not seen[rel] and fn.fnamemodify(abs, ":t") ~= "__init__.py" then
      seen[rel] = true
      table.insert(probes, rel)
    end
  end

  return probes
end

---How often the project spells any of `dotted_names` in a real import statement
---
---Both `import a.b.c` / `from a.b.c import x` and the `from a.b import c` form
---count, since either fixes where the name starts. One search covers every
---spelling of one candidate root, so a directory costs one scan per candidate.
---@param project_root string
---@param dotted_names string[]
---@return integer
local function count_spellings(project_root, dotted_names)
  local alts = {}
  for _, dotted in ipairs(dotted_names) do
    local escaped = dotted:gsub("%.", "\\.")
    table.insert(
      alts,
      "^[[:space:]]*(from|import)[[:space:]]+" .. escaped .. "([[:space:],.]|$)"
    )
    local prefix, tail = utils.split_dotted_tail(dotted)
    if prefix ~= "" then
      table.insert(
        alts,
        "^[[:space:]]*from[[:space:]]+"
          .. prefix:gsub("%.", "\\.")
          .. "[[:space:]]+import[[:space:]]+.*\\b"
          .. tail:gsub("([^%w_])", "\\%1")
          .. "\\b"
      )
    end
  end

  local output, err = search.run {
    "rg",
    "--count-matches",
    "-g",
    "*.py",
    "-e",
    table.concat(alts, "|"),
    "--",
    project_root,
  }
  if not output then
    error(err)
  end
  local total = 0
  for _, line in ipairs(output) do
    total = total + (tonumber(line:match ":(%d+)$") or 0)
  end
  return total
end

---Directory a module is named from, decided by what the codebase already writes
---
---The package chain alone cannot separate a source root from a PEP 420
---namespace package: `src/mypkg/` and `ns/pkg/` look identical on disk, and only
---`sys.path` tells them apart. What does distinguish them is how the rest of the
---project already spells modules there -- `from mypkg.utils import f` fixes the
---root at `src/`, `from ns.pkg.utils import f` fixes it at the project root. So
---each candidate root is scored by how often its spelling actually appears, and
---the most frequent wins. With no import to learn from, the package chain
---decides and the answer is flagged as inferred.
---@param project_root string
---@param rel_path string Module or package path relative to the project root
---@param is_package boolean Whether `rel_path` names a directory
---@return string import_root
---@return boolean inferred Set when no import in the project settled it
---@return string[] rivals Other spellings the project also uses
function M.find_import_root(project_root, rel_path, is_package)
  local trimmed = rel_path:gsub("/+$", "")
  local rel_dir = is_package and trimmed or (trimmed:match "^(.*)/[^/]*$" or "")

  local candidates = candidate_roots(project_root, rel_dir)
  if #candidates == 1 then
    -- Only one place this can be named from; nothing to weigh
    return candidates[1], false, {}
  end

  local probes = probe_modules(project_root, rel_dir, trimmed)
  local best, best_count, scored = nil, 0, {}
  for _, candidate in ipairs(candidates) do
    local spellings = {}
    for _, probe in ipairs(probes) do
      local dotted = utils.strip_root(probe, candidate):gsub("%.py$", "")
      if dotted ~= "" then
        table.insert(spellings, (dotted:gsub("/", ".")))
      end
    end

    local count = #spellings > 0 and count_spellings(project_root, spellings)
      or 0
    scored[candidate] = count
    -- Ties go to the shallower root, which is the one already in `best`
    if count > best_count then
      best, best_count = candidate, count
    end
  end

  if not best then
    return structural_import_root(project_root, rel_dir), true, {}
  end

  local rivals = {}
  for candidate, count in pairs(scored) do
    if count > 0 and candidate ~= best then
      local spelling = utils.strip_root(trimmed, candidate):gsub("%.py$", "")
      table.insert(rivals, (spelling:gsub("/", ".")))
    end
  end
  return best, false, rivals
end

---Import root a module or package is named from, memoised per directory
---@param project_root string
---@param rel_path string Module or package path relative to the project root
---@param is_package boolean Whether `rel_path` names a directory
---@return string import_root
---@return boolean inferred
---@return string[] rivals
function M.resolve_import_root(project_root, rel_path, is_package)
  local configured = config.options.move.import_root
  if configured then
    return (configured:gsub("/+$", "")), false, {}
  end

  local trimmed = rel_path:gsub("/+$", "")
  local rel_dir = is_package and trimmed or (trimmed:match "^(.*)/[^/]*$" or "")
  local key = string.format("%s\0%s\0%s", project_root, rel_dir, is_package)

  local hit = root_cache[key]
  if hit then
    return hit[1], hit[2], hit[3]
  end

  local import_root, inferred, rivals =
    M.find_import_root(project_root, rel_path, is_package)
  root_cache[key] = { import_root, inferred, rivals }
  return import_root, inferred, rivals
end

---Path of a module relative to its own import root, as Python spells it
---
---Never searches. An importer under a root already settled for this move is
---named from it, and anything outside falls back to the package chain -- asking
---how often the project imports a test module would cost a scan per directory
---to learn nothing, since nothing imports it.
---@param project_root string
---@param file string Absolute path of a `.py` file
---@return string
function M.import_relative_path(project_root, file)
  local rel_path = Path:new(file):make_relative(project_root)

  local configured = config.options.move.import_root
  if configured then
    return utils.strip_root(rel_path, (configured:gsub("/+$", "")))
  end

  if decided.project_root == project_root then
    -- The deepest settled root containing the file wins; the project root
    -- matches everything, so a flat project settles every importer outright
    local best = nil
    for _, root in ipairs(decided.roots) do
      local contains = root == "" or rel_path:sub(1, #root + 1) == root .. "/"
      if contains and (not best or #root > #best) then
        best = root
      end
    end
    if best then
      return utils.strip_root(rel_path, best)
    end
  end

  local rel_dir = rel_path:match "^(.*)/[^/]*$" or ""
  return utils.strip_root(
    rel_path,
    structural_import_root(project_root, rel_dir)
  )
end

---@class MoveNames
---@field old_dotted string Dotted name of the module being moved
---@field new_dotted string Dotted name of its destination
---@field inferred string[] Import roots no import in the project confirmed
---@field rivals string[] Spellings the project also uses for the moved module

---Derive the dotted names of both sides of a move
---
---Each side is resolved against its own import root: moving out of `src/` into
---a flat package changes what Python calls the module on the way, so one root
---cannot serve both. The destination does not exist yet and so has no imports of
---its own to be recognised by; it is named from whatever root the modules
---already living around it are named from, and inherits the source's when
---nothing lives there yet.
---@param project_root string
---@param old_name string Source path relative to the project root
---@param new_name string Destination path relative to the project root
---@return MoveNames
function M.resolve_move_names(project_root, old_name, new_name)
  local is_package = (Path:new(project_root) / old_name):is_dir()
  local old_root, old_inferred, rivals =
    M.resolve_import_root(project_root, old_name, is_package)

  local trimmed_new = new_name:gsub("/+$", "")
  local new_dir = is_package and trimmed_new
    or (trimmed_new:match "^(.*)/[^/]*$" or "")
  local new_root, new_inferred
  if (Path:new(project_root) / new_dir):exists() then
    new_root, new_inferred =
      M.resolve_import_root(project_root, new_name, is_package)
  else
    -- Nothing lives where this is going, so there is nothing to learn the root
    -- from. A move that does not say otherwise stays in the root it came from
    new_root, new_inferred = old_root, old_inferred
  end

  local inferred, seen = {}, {}
  for _, entry in ipairs {
    { old_root, old_inferred },
    { new_root, new_inferred },
  } do
    -- The project root is never a guess: it is where naming starts by default
    if entry[2] and entry[1] ~= "" and not seen[entry[1]] then
      seen[entry[1]] = true
      table.insert(inferred, entry[1])
    end
  end

  decided = { project_root = project_root, roots = { old_root, new_root } }

  return {
    old_dotted = utils.path_to_dotted_name(
      utils.strip_root(old_name, old_root)
    ),
    new_dotted = utils.path_to_dotted_name(
      utils.strip_root(new_name, new_root)
    ),
    inferred = inferred,
    rivals = rivals,
  }
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
    return false, "Destination path already exists: " .. tostring(new_full_path)
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
  if new_full_path:exists() then
    return false, "Destination path already exists: " .. tostring(new_full_path)
  end
  local renamed, rename_error =
    vim.uv.fs_rename(tostring(old_full_path), tostring(new_full_path))
  if renamed then
    log.info("Successfully moved: " .. old_path .. " -> " .. new_path)
    return true, nil
  else
    return false, "Failed to move file/directory: " .. tostring(rename_error)
  end
end

return M
