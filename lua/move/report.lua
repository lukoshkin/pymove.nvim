---Report import sites that were kept working by a synthesized alias
---
---Renaming the module in `from . import utils` would rebind `utils`, so the old
---name is preserved as an alias. The import keeps working, but call sites still
---spell the old name; this module hands the user the list so they can rename
---those too -- interactively with `:cdo`, or with an external tool reading the
---emitted file.

local filesystem = require "move.filesystem"

local M = {}

local log = require("plenary.log").new {
  plugin = "pymove-report",
  use_console = true,
}

---Pick the relative-import spelling that will actually import
---
---An absolute dotted name is only importable when every directory between the
---project root and the module is a package. In a src layout it is not: the root
---is found by `pyproject.toml` one level above `src/`, so `src.mypkg.helpers`
---names nothing. Rather than write a line that cannot run, keep such imports
---relative and say why.
---@param configured "absolute"|"preserve"
---@param project_root string
---@param new_rel_path string Destination path relative to the project root
---@return "absolute"|"preserve" strategy
function M.resolve_strategy(configured, project_root, new_rel_path)
  if configured ~= "absolute" then
    return configured
  end

  local offender = filesystem.first_non_package_dir(project_root, new_rel_path)
  if not offender then
    return "absolute"
  end

  local msg = string.format(
    "`%s/` has no __init__.py, so an absolute import of %s would not resolve.\n"
      .. "Keeping relative imports relative (relative_imports=\"preserve\" for "
      .. "this move).\nImports with no relative form are still written "
      .. "absolutely -- check those.",
    offender,
    new_rel_path
  )
  log.warn(msg)
  vim.notify(msg, vim.log.levels.WARN)

  return "preserve"
end

---@param entries table[] {file, line_num, aliased_name, aliased_to}
---@return string? path File the report was written to
local function write_report(entries)
  local dir = vim.fn.resolve(os.getenv "TMPDIR" or "/tmp")
  local path =
    string.format("%s/pymove-aliases-%s.txt", dir, os.date "%Y%m%d-%H%M%S")

  local fd = io.open(path, "w")
  if not fd then
    log.warn("Could not write alias report to " .. path)
    return nil
  end

  fd:write "# pymove: modules kept working by a synthesized alias\n"
  fd:write "# file:line:old_name:new_name\n"
  for _, entry in ipairs(entries) do
    fd:write(
      string.format(
        "%s:%d:%s:%s\n",
        entry.file,
        entry.line_num,
        entry.aliased_name,
        entry.aliased_to
      )
    )
  end
  fd:close()

  return path
end

---Publish the aliased sites as a quickfix list and a file under TMPDIR
---@param changes table[] Applied changes, some carrying aliased_name
function M.publish_aliases(changes)
  local entries = {}
  for _, change in ipairs(changes) do
    if change.aliased_name then
      table.insert(entries, {
        file = change.file,
        line_num = change.line_num,
        aliased_name = change.aliased_name,
        aliased_to = change.aliased_to,
      })
    end
  end

  if #entries == 0 then
    return
  end

  local qf = {}
  for _, entry in ipairs(entries) do
    table.insert(qf, {
      filename = entry.file,
      lnum = entry.line_num,
      col = 1,
      type = "W",
      text = string.format(
        "aliased `%s` -> `%s`; call sites still use `%s`",
        entry.aliased_to,
        entry.aliased_name,
        entry.aliased_name
      ),
    })
  end
  vim.fn.setqflist({}, " ", { title = "pymove: synthesized aliases", items = qf })

  local path = write_report(entries)
  local msg = string.format(
    "%d import(s) kept working via an alias -- :copen to review, "
      .. "`:cdo s/\\<old\\>/new/gc` to rename call sites",
    #entries
  )
  if path then
    msg = msg .. "\nReport: " .. path
  end

  log.info(msg)
  vim.notify(msg, vim.log.levels.WARN)
end

return M
