---Report import sites that were kept working by a synthesized alias
---
---Renaming the module in `from . import utils` would rebind `utils`, so the old
---name is preserved as an alias. The import keeps working, but call sites still
---spell the old name; this module hands the user the list so they can rename
---those too -- interactively with `:cdo`, or with an external tool reading the
---emitted file.

local M = {}

local log = require("plenary.log").new {
  plugin = "pymove-report",
  use_console = true,
}

---Report an import root nothing in the project confirmed, and pick a spelling
---
---A directory holding modules but no `__init__.py` reads two ways -- a source
---root, whose contents are top-level, or a PEP 420 namespace package, whose name
---is part of every dotted name below it -- and only `sys.path` separates them.
---Normally the codebase settles it: some import already spells the module one
---way or the other. When none does, the package chain is all there is, so say
---which reading was taken -- and point at `move.import_root`, which settles it
---outright -- while keeping the move relative where it can be, since a relative
---import is right under either reading.
---@param configured "absolute"|"preserve"
---@param inferred_roots string[] Import roots no import in the project confirmed
---@return "absolute"|"preserve" strategy
function M.resolve_strategy(configured, inferred_roots)
  if #inferred_roots == 0 then
    return configured
  end

  local msg = string.format(
    "Nothing in the project imports anything under `%s`, so its role could not "
      .. "be read off the code. Treating it as an import root, which names its "
      .. "contents as top-level modules; if it is a PEP 420 namespace package "
      .. "instead, every dotted name here is one component short.\nSet "
      .. "`move.import_root` to say which, and this stops being a guess.",
    table.concat(inferred_roots, "`, `")
  )
  if configured == "absolute" then
    msg = msg
      .. "\nFalling back to relative_imports=\"preserve\" for this move, since "
      .. "a relative import is right under either reading. Imports with no "
      .. "relative form are still written absolutely; check those."
  end
  log.warn(msg)
  vim.notify(msg, vim.log.levels.WARN)

  return configured == "absolute" and "preserve" or configured
end

---Report spellings of the moved module that this pass will not touch
---
---A project that names the same module two ways -- `mypkg.utils` in the package,
---`src.mypkg.utils` in tests that run from the repo root -- has two sets of
---imports that both have to keep working. Only the more common one is rewritten,
---so name the other rather than leave it quietly stale.
---@param rivals string[] Dotted spellings the project also uses
---@param new_dotted string What the winning spelling was rewritten to
function M.warn_rival_spellings(rivals, new_dotted)
  if #rivals == 0 then
    return
  end

  local msg = string.format(
    "The project also imports this module as `%s`, which this move does not "
      .. "rewrite -- only the more common spelling (`%s`) was. Search for the "
      .. "others and fix them by hand, or set `move.import_root` and run again.",
    table.concat(rivals, "`, `"),
    new_dotted
  )
  log.warn(msg)
  vim.notify(msg, vim.log.levels.WARN)
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
