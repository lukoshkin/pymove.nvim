local Path = require "plenary.path"

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
    return input
  end
end

---Convert a relative dotted import path to an absolute one
---@param rel_path string Relative file path
---@param rel_dotted_path string Relative import path (e.g., ".module")
---@return string Absolute dotted path
function M.absolute_dotted_path(rel_path, rel_dotted_path)
  local suffix = rel_dotted_path:gsub("^%.+", "")
  local parent_lvl = rel_dotted_path:len() - suffix:len()
  if parent_lvl == 0 then
    parent_lvl = 1
  end

  local parents = Path:new(rel_path):parents()
  local prefix = parents[parent_lvl]
  local _, max_lvl = rel_path:gsub("/", "")
  max_lvl = max_lvl + 1
  if parent_lvl > max_lvl then
    error "The rel_dotted_path leads outside of the project!"
  end
  local _prefix = parents[max_lvl]
  prefix = Path:new(prefix):make_relative(_prefix)
  return M.path_to_dotted_name(prefix) .. "." .. suffix
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
---@param change string[] Changed components
---@return string Regex pattern
function M.file_change_pattern(change)
  change = table.concat(change, ".*")
  return "import.*" .. change .. "|" .. change .. ".*import"
end

return M
