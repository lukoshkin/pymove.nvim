local M = {}

---Split a Python dotted import path into components
---@param dotted_name string
---@return string[]
function M.split_python_import_path(dotted_name)
  local components = {}
  local leading_dots = dotted_name:match "^[%.]+"
  if leading_dots then
    table.insert(components, leading_dots)
  end
  for component in dotted_name:gmatch "([^%.]+)" do
    table.insert(components, component)
  end
  return components
end

---Convert a filesystem path to a Python dotted import name
---@param input string
---@return string
function M.path_to_dotted_name(input)
  local chopped = input:gsub("%.py$", "")
  -- Strip trailing slashes
  chopped = chopped:gsub("/+$", "")

  if
    chopped:find "\\"
    or input:find "/" and chopped:find "%."
    or chopped:find "%." and chopped:find "-"
  then
    error "The broken Python's import path!"
  end

  if string.find(chopped, "/") then
    chopped = chopped:gsub("-", "_")
    local chopped = chopped:gsub("/", ".")
    return chopped
  else
    return chopped
  end
end

---Rename a dotted import path if it refers to the moved module
---
---Matching is done on whole dotted components, so `src.utils` renames
---`src.utils` and `src.utils.deep` but leaves `src.utils_legacy` alone.
---@param name string Dotted name as written in the source
---@param old_dotted string Dotted name of the module being moved
---@param new_dotted string Dotted name of its destination
---@return string? renamed Nil when `name` does not refer to the moved module
function M.rename_dotted_prefix(name, old_dotted, new_dotted)
  if name == old_dotted then
    return new_dotted
  end
  if name:sub(1, #old_dotted + 1) == old_dotted .. "." then
    return new_dotted .. name:sub(#old_dotted + 1)
  end
  return nil
end

---Package components of the module living at `rel_path`
---
---`src/pkg/a.py` lives in package `src.pkg`, so this returns `{"src", "pkg"}`.
---A module at the project root has no package and yields an empty list.
---@param rel_path string Path relative to the project root
---@return string[]
function M.package_parts(rel_path)
  local dir = rel_path:gsub("/+$", ""):match "^(.*)/[^/]*$"
  if not dir or dir == "" or dir == "." then
    return {}
  end
  local parts = {}
  for part in dir:gmatch "[^/]+" do
    table.insert(parts, part)
  end
  return parts
end

---Split a dotted path into everything before the last component and that component
---@param dotted string
---@return string prefix Empty when `dotted` has a single component
---@return string tail
function M.split_dotted_tail(dotted)
  local prefix, tail = dotted:match "^(.*)%.([^.]+)$"
  if not prefix then
    return "", dotted
  end
  return prefix, tail
end

---Convert a relative dotted import path to an absolute one
---
---Resolution follows Python: one dot means the importer's own package, each
---further dot climbs one package above it.
---@param rel_path string Importer path relative to the project root
---@param rel_dotted_path string Relative import path (e.g. ".module", "..pkg.mod")
---@return string Absolute dotted path
function M.absolute_dotted_path(rel_path, rel_dotted_path)
  local dots = rel_dotted_path:match "^%.+"
  if not dots then
    return rel_dotted_path
  end

  local suffix = rel_dotted_path:sub(#dots + 1)
  local parts = M.package_parts(rel_path)
  local climb = #dots - 1
  if climb > #parts then
    error "The rel_dotted_path leads outside of the project!"
  end

  local base = table.concat(vim.list_slice(parts, 1, #parts - climb), ".")
  if base == "" then
    return suffix
  end
  if suffix == "" then
    return base
  end
  return base .. "." .. suffix
end

---Express an absolute dotted path relatively to the importer's package
---
---Returns nil when no valid relative form exists -- that is, when reaching the
---target would mean climbing above the project root, which is not a package.
---@param importer_rel_path string Importer path relative to the project root
---@param target_dotted string Absolute dotted path of the target
---@return string? relative
function M.relative_dotted_path(importer_rel_path, target_dotted)
  local parts = M.package_parts(importer_rel_path)
  local target = M.split_python_import_path(target_dotted)

  local common = 0
  while
    common < #parts
    and common < #target
    and parts[common + 1] == target[common + 1]
  do
    common = common + 1
  end

  if common == 0 then
    return nil
  end

  local suffix = table.concat(vim.list_slice(target, common + 1, #target), ".")
  return string.rep(".", #parts - common + 1) .. suffix
end

---Rename a `from <prefix> import <name>` statement whose imported name moved
---
---Handles both a relative prefix (`from . import utils`) and a package prefix
---(`from src import utils`); the two differ only in how the prefix resolves.
---@param prefix string Text of the `module_name:` field ("." / "..pkg" / "src")
---@param imported_name string Text of one `name:` field entry
---@param old_dotted string Dotted name of the module being moved
---@param new_dotted string Dotted name of its destination
---@param importer_rel_path string Importer path relative to the project root
---@return string? new_prefix Absolute dotted prefix after the move
---@return string? new_name
function M.rename_from_import(
  prefix,
  imported_name,
  old_dotted,
  new_dotted,
  importer_rel_path
)
  local abs_prefix = prefix:find "^%."
      and M.absolute_dotted_path(importer_rel_path, prefix)
    or prefix
  local full = abs_prefix == "" and imported_name
    or abs_prefix .. "." .. imported_name

  local renamed = M.rename_dotted_prefix(full, old_dotted, new_dotted)
  if not renamed then
    return nil
  end
  return M.split_dotted_tail(renamed)
end

---Estimate what components changed between old and new dotted names
---@param old_dotted string
---@param new_dotted string
---@return string[] Changed components
function M.estimate_change(old_dotted, new_dotted)
  local old_table = M.split_python_import_path(old_dotted)
  local new_table = M.split_python_import_path(new_dotted)
  local changes = {}
  local new_set = {}

  for _, value in ipairs(new_table) do
    new_set[value] = true
  end

  for _, value in ipairs(old_table) do
    if not new_set[value] then
      table.insert(changes, value)
    end
  end

  if #changes == 0 then
    return old_table
  end

  return changes
end

---Generate a regex pattern to find files that might contain the import
---
---A cross-package move makes the component-based pattern demand the old
---package, which no relative import spells out, so relative forms of the
---moved module are matched separately. Over-matching only costs a parse.
---@param change string[] Changed components
---@param old_dotted string? Dotted name of the module being moved
---@return string Regex pattern
function M.file_change_pattern(change, old_dotted)
  change = table.concat(change, ".*")
  local pattern = "import.*" .. change .. "|" .. change .. ".*import"

  if old_dotted then
    local _, tail = M.split_dotted_tail(old_dotted)
    pattern = pattern
      -- from .utils import f / from ..pkg.utils import f
      .. "|from[[:space:]]+\\.[^[:space:]]*"
      .. tail
      -- from . import utils
      .. "|from[[:space:]]+\\.+[[:space:]]+import.*"
      .. tail
      -- from .pkg import utils -- a dotted relative prefix cannot be crossed by
      -- the first alternative, which stops at the space before `import`
      .. "|from[[:space:]]+\\.[^[:space:]]*[[:space:]]+import.*"
      .. tail
  end

  return pattern
end

return M
