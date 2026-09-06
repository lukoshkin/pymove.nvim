---Whole moves, checked by what the files say afterwards and by CPython
---
---The rewritten text is the intermediate claim; whether Python can import the
---result is the one that matters, so every layout is run through the interpreter
---as well.

local h = require "tests.helpers"
local fx = require "tests.fixtures"

local config = require "pymove.config"
local move = require "move"

---Run a real move and compare the files it touched
---@param label string
---@param project_root string
---@param old_name string
---@param new_name string
---@param expect table<string, string[]>
local function moves(label, project_root, old_name, new_name, expect)
  local ok = move.move_module_or_package(
    old_name,
    new_name,
    project_root,
    { use_git = false }
  )
  h.ok(label .. ": reported success", ok)
  for rel, want in pairs(expect) do
    h.check(label .. ": " .. rel, h.lines(project_root .. "/" .. rel), want)
  end
end

return function()
  h.section "src layout"
  local src = h.project("move_src", fx.src())
  moves("src", src, "src/mypkg/utils.py", "src/mypkg/helpers.py", {
    ["src/mypkg/a.py"] = {
      "from mypkg.helpers import f",
      "from mypkg.helpers import f as g",
      -- `from . import utils` binds `utils`; the alias keeps call sites working
      "from mypkg import helpers as utils",
      "import mypkg.helpers",
    },
    ["src/mypkg/sub/b.py"] = { "from mypkg.helpers import f" },
  })
  h.ok("src: imports under python3", (h.imports_cleanly(src, { "mypkg.a", "mypkg.sub.b" }, "src")))

  h.section "src layout spelled from the project root"
  local dotted = h.project("move_src_dotted", fx.src_dotted())
  moves("root-spelled", dotted, "src/mypkg/utils.py", "src/mypkg/helpers.py", {
    ["tests/test_a.py"] = {
      "from src.mypkg.helpers import f",
      "import src.mypkg.helpers",
    },
  })
  h.ok("root-spelled: imports under python3", (h.imports_cleanly(dotted, { "tests.test_a" })))

  h.section "flat package"
  local flat = h.project("move_flat", fx.flat())
  moves("flat", flat, "mypkg/utils.py", "mypkg/helpers.py", {
    ["mypkg/a.py"] = {
      "from mypkg.helpers import f",
      "from mypkg.helpers import f as g",
    },
  })
  h.ok("flat: imports under python3", (h.imports_cleanly(flat, { "mypkg.a" })))

  h.section "module colliding with a stdlib name"
  local clash = h.project("move_clash", fx.stdlib_clash())
  moves("clash", clash, "mypkg/logging.py", "mypkg/logs.py", {
    -- Only the package-qualified import moves; `import logging` is the stdlib
    ["mypkg/a.py"] = {
      "import logging",
      "from mypkg.logs import LOG",
      "",
      "log = logging.getLogger(__name__)",
    },
    ["mypkg/b.py"] = { "import logging", "log = logging.getLogger(__name__)" },
    ["tests/test_a.py"] = { "import logging" },
  })
  h.ok("clash: imports under python3", (h.imports_cleanly(clash, { "mypkg.a", "mypkg.b" })))

  h.section "namespace package wrapping a regular one"
  local wrap = h.project("move_ns_wrapping", fx.ns_wrapping())
  moves("ns-wrapping", wrap, "ns/pkg/utils.py", "ns/pkg/helpers.py", {
    ["ns/pkg/a.py"] = {
      "import ns.pkg.helpers",
      "from ns.pkg.helpers import f",
      "from ns.pkg import helpers as utils",
      "from ns.pkg.helpers import f as f2",
    },
    ["ns/pkg/sub/b.py"] = { "from ns.pkg.helpers import f" },
  })
  h.ok("ns-wrapping: imports under python3", (h.imports_cleanly(wrap, { "ns.pkg.a", "ns.pkg.sub.b" })))

  h.section "top-level namespace package"
  local top = h.project("move_ns_top", fx.ns_top())
  moves("ns-top", top, "nspkg/utils.py", "nspkg/helpers.py", {
    ["nspkg/a.py"] = {
      "from nspkg import helpers as utils",
      "from nspkg.helpers import f",
    },
    ["nspkg/sub/b.py"] = { "from nspkg.helpers import f" },
  })
  h.ok("ns-top: imports under python3", (h.imports_cleanly(top, { "nspkg.a", "nspkg.sub.b" })))

  h.section "non-package directory between packages"
  local deep = h.project("move_deep", fx.deep())
  moves("deep", deep, "a/b/c/utils.py", "a/b/c/helpers.py", {
    ["a/b/c/mod.py"] = {
      "import a.b.c.helpers",
      "from a.b.c import helpers as utils",
    },
  })
  h.ok("deep: imports under python3", (h.imports_cleanly(deep, { "a.b.c.mod" })))

  h.section "explicit move.import_root"
  local nsdir = h.project("move_nsdir", fx.ns_dir())
  config.options.move.import_root = ""
  moves("configured root", nsdir, "mypkg/utils.py", "mypkg/helpers.py", {
    ["mypkg/a.py"] = { "from mypkg import helpers as utils" },
  })
  config.options.move.import_root = nil
  h.ok("configured root: imports under python3", (h.imports_cleanly(nsdir, { "mypkg.a" })))

  h.section "search cost"
  -- Resolving a root costs one project scan per candidate. Importers must not
  -- add any: asking how often the project imports a test module always answers
  -- zero, and doing it per directory made a move quadratic in the tree.
  local wide = h.project("move_wide", fx.wide(40, 200))
  local shim = h.project("rgshim", {})
  local log = shim .. "/rg.log"
  vim.fn.writefile({
    "#!/bin/sh",
    ('echo x >> %s'):format(vim.fn.shellescape(log)),
    ('exec %s "$@"'):format(vim.fn.exepath "rg"),
  }, shim .. "/rg")
  vim.fn.setfperm(shim .. "/rg", "rwxr-xr-x")

  local path = vim.env.PATH
  vim.env.PATH = shim .. ":" .. path
  vim.fn.writefile({}, log)
  move.move_module_or_package(
    "src/mypkg/utils.py",
    "src/mypkg/helpers.py",
    wide,
    { use_git = false }
  )
  vim.env.PATH = path

  local scans = #vim.fn.readfile(log)
  h.ok(
    ("40 importer directories cost %d scans (want <= 6)"):format(scans),
    scans <= 6
  )
end
