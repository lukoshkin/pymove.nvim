#!/usr/bin/env -S nvim -l

---Run every spec: `nvim -l tests/run.lua [spec ...]`
---
---With no arguments every spec runs. Names may be given with or without the
---`_spec` suffix, so `nvim -l tests/run.lua import_root` works.

local here = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h")
package.path = here .. "/../?.lua;" .. package.path

local h = dofile(here .. "/helpers.lua")
package.loaded["tests.helpers"] = h
package.loaded["tests.fixtures"] = dofile(here .. "/fixtures.lua")

if not h.bootstrap() then
  os.exit(1)
end

-- The plugin narrates every move through `vim.notify`, which would bury the
-- assertions. Set PYMOVE_TEST_VERBOSE=1 to watch it work.
if not os.getenv "PYMOVE_TEST_VERBOSE" then
  vim.notify = function() end
  require("plenary.log").new({ plugin = "pymove-refactor" }).level = "error"
end

local specs = { "import_root", "move" }
if #arg > 0 then
  specs = {}
  for _, name in ipairs(arg) do
    table.insert(specs, (name:gsub("_spec$", "")))
  end
end

for _, name in ipairs(specs) do
  local path = ("%s/%s_spec.lua"):format(here, name)
  if vim.fn.filereadable(path) == 0 then
    print("no such spec: " .. name)
    os.exit(1)
  end
  print("\n### " .. name)
  dofile(path)()
end

os.exit(h.report())
