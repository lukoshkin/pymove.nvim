---Test scaffolding: a scratch project per case, and assertions that report
---
---Fixtures are written fresh for every case because a move rewrites them in
---place -- a suite that reused one would pass on the first run and fail on the
---second for reasons that have nothing to do with the code.

local M = {}

local passed, failed, failures = 0, 0, {}

---Put plenary on the runtimepath, wherever this machine keeps it
---@return boolean ok
function M.bootstrap()
  vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))

  if pcall(require, "plenary.path") then
    return true
  end

  -- Built by insertion rather than as a literal: a nil first element would
  -- truncate the table and `ipairs` would stop before looking anywhere
  local candidates = {}
  if os.getenv "PLENARY_PATH" then
    table.insert(candidates, os.getenv "PLENARY_PATH")
  end
  for _, suffix in ipairs {
    "/lazy/plenary.nvim",
    "/site/pack/packer/start/plenary.nvim",
    "/plugged/plenary.nvim",
  } do
    table.insert(candidates, vim.fn.stdpath "data" .. suffix)
  end

  for _, dir in ipairs(candidates) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.opt.runtimepath:append(dir)
      if pcall(require, "plenary.path") then
        return true
      end
    end
  end

  print "plenary.nvim not found -- set PLENARY_PATH to its directory"
  return false
end

local session = nil

---Root under which every fixture for this run is written
---@return string
local function scratch_root()
  if not session then
    session = vim.fn.tempname()
    vim.fn.mkdir(session, "p")
  end
  return session
end

---Write a project tree and return its root
---
---Keys are paths relative to the project root; a value of `false` means an
---empty file, which is how `__init__.py` markers are spelled.
---@param name string Fixture name, used as the directory
---@param tree table<string, string|false>
---@return string project_root
function M.project(name, tree)
  local root = scratch_root() .. "/" .. name
  vim.fn.mkdir(root, "p")
  for rel, content in pairs(tree) do
    local abs = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
    vim.fn.writefile(vim.split(content or "", "\n", { plain = true }), abs)
  end
  return root
end

---@param label string
---@param got any
---@param want any
function M.check(label, got, want)
  if vim.deep_equal(got, want) then
    passed = passed + 1
    print("  ok   " .. label)
    return
  end
  failed = failed + 1
  table.insert(failures, label)
  print(
    ("  FAIL %s\n       got  %s\n       want %s"):format(
      label,
      vim.inspect(got):gsub("%s+", " "),
      vim.inspect(want):gsub("%s+", " ")
    )
  )
end

---@param label string
---@param ok boolean
function M.ok(label, ok)
  M.check(label, ok and true or false, true)
end

---Read a file back as one line per entry
---@param path string
---@return string[]
function M.lines(path)
  return vim.fn.readfile(path)
end

---Whether CPython can import the given modules from this tree
---
---The ground truth for every naming question in this plugin: a rewrite that
---does not import is wrong however plausible it reads.
---@param project_root string
---@param modules string[]
---@param path_entry string? Directory to put on `sys.path` (default: the root)
---@return boolean ok
---@return string output
function M.imports_cleanly(project_root, modules, path_entry)
  if vim.fn.executable "python3" == 0 then
    return true, "python3 unavailable, skipped"
  end
  local cmd = ("cd %s && PYTHONPATH=%s python3 -c %s 2>&1"):format(
    vim.fn.shellescape(project_root),
    vim.fn.shellescape(
      path_entry and (project_root .. "/" .. path_entry) or project_root
    ),
    vim.fn.shellescape("import " .. table.concat(modules, ", "))
  )
  local out = vim.fn.system(cmd)
  return vim.v.shell_error == 0, out
end

---@param title string
function M.section(title)
  print("\n== " .. title .. " ==")
end

---@return integer exit_code
function M.report()
  print(("\n%d passed, %d failed"):format(passed, failed))
  if failed > 0 then
    print("failed: " .. table.concat(failures, ", "))
  end
  return failed == 0 and 0 or 1
end

return M
