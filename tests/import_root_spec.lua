---Where a dotted name starts, and the arithmetic that depends on it

local h = require "tests.helpers"
local fx = require "tests.fixtures"

local config = require "pymove.config"
local filesystem = require "move.filesystem"
local refactor = require "move.refactor"
local utils = require "move.utils"

---@return string import_root
---@return boolean inferred
local function root_of(project_root, rel_path, is_package)
  filesystem.reset_root_cache()
  local root, inferred =
    filesystem.resolve_import_root(project_root, rel_path, is_package)
  return root, inferred
end

local function names(project_root, old_name, new_name)
  filesystem.reset_root_cache()
  return filesystem.resolve_move_names(project_root, old_name, new_name)
end

return function()
  h.section "strip_root"
  h.check("no root strips nothing", utils.strip_root("mypkg/utils.py", ""), "mypkg/utils.py")
  h.check("root is removed", utils.strip_root("src/mypkg/utils.py", "src"), "mypkg/utils.py")
  h.check("trailing slash tolerated", utils.strip_root("src/mypkg/", "src"), "mypkg")
  h.check("unrelated path untouched", utils.strip_root("tests/t.py", "src"), "tests/t.py")

  h.section "climb guard"
  -- CPython raises "attempted relative import beyond top-level package" rather
  -- than resolving these, so a rewrite of them would not run
  h.check("`.` at the import root", pcall(utils.absolute_dotted_path, "a.py", ".utils"), false)
  h.check("`..` at the import root", pcall(utils.absolute_dotted_path, "a.py", "..utils"), false)
  h.check("`..` out of the top package", pcall(utils.absolute_dotted_path, "mypkg/a.py", "..utils"), false)
  h.check("`.` inside a package", utils.absolute_dotted_path("mypkg/a.py", ".utils"), "mypkg.utils")
  h.check("`..` from a subpackage", utils.absolute_dotted_path("mypkg/sub/b.py", "..utils"), "mypkg.utils")

  h.section "import root per layout"
  local src = h.project("src", fx.src())
  h.check("src layout module", { root_of(src, "src/mypkg/utils.py", false) }, { "src", false })
  h.check("src layout package", { root_of(src, "src/mypkg", true) }, { "src", false })
  h.check("destination not created yet", { root_of(src, "src/mypkg/new/helpers.py", false) }, { "src", true })

  local flat = h.project("flat", fx.flat())
  h.check("flat layout", { root_of(flat, "mypkg/utils.py", false) }, { "", false })
  -- One candidate means one possible answer, which is not a guess
  h.check("module at the project root", { root_of(flat, "setup.py", false) }, { "", false })

  local dotted = h.project("src_dotted", fx.src_dotted())
  h.check("src layout spelled from the root", { root_of(dotted, "src/mypkg/utils.py", false) }, { "", false })

  local wrap = h.project("ns_wrapping", fx.ns_wrapping())
  h.check("namespace wrapping a package", { root_of(wrap, "ns/pkg/utils.py", false) }, { "", false })

  local top = h.project("ns_top", fx.ns_top())
  h.check("top-level namespace package", { root_of(top, "nspkg/utils.py", false) }, { "", true })

  local nsdir = h.project("ns_dir", fx.ns_dir())
  h.check("non-package directory", { root_of(nsdir, "mypkg/utils.py", false) }, { "", true })

  local deep = h.project("deep", fx.deep())
  -- `a/` is a package, so `a/b` cannot be a source root: decidable from the tree
  h.check("non-package between packages", { root_of(deep, "a/b/c/utils.py", false) }, { "", false })

  h.section "dotted names for a move"
  h.check("src rename", { names(src, "src/mypkg/utils.py", "src/mypkg/helpers.py").old_dotted }, { "mypkg.utils" })
  h.check("flat rename", { names(flat, "mypkg/utils.py", "mypkg/helpers.py").old_dotted }, { "mypkg.utils" })
  h.check("root-spelled rename", { names(dotted, "src/mypkg/utils.py", "src/mypkg/helpers.py").old_dotted }, { "src.mypkg.utils" })
  h.check("namespace wrapping", { names(wrap, "ns/pkg/utils.py", "ns/pkg/helpers.py").old_dotted }, { "ns.pkg.utils" })
  h.check("non-package between packages", { names(deep, "a/b/c/utils.py", "a/b/c/helpers.py").old_dotted }, { "a.b.c.utils" })

  local n = names(src, "src/mypkg", "src/renamed")
  h.check("package rename", { n.old_dotted, n.new_dotted }, { "mypkg", "renamed" })

  n = names(src, "src/mypkg/utils.py", "flatpkg/helpers.py")
  h.check("cross-root move", { n.old_dotted, n.new_dotted }, { "mypkg.utils", "flatpkg.helpers" })

  -- A package directory can never be the import root; offering it as a
  -- candidate spells this module `logging`, and every `import logging` in the
  -- project then votes for renaming the stdlib
  local clash = h.project("stdlib_clash", fx.stdlib_clash())
  n = names(clash, "mypkg/logging.py", "mypkg/logs.py")
  h.check("stdlib name collision", { n.old_dotted, n.new_dotted, n.inferred }, { "mypkg.logging", "mypkg.logs", {} })

  -- The neighbours pin the root even though nothing imports this module yet
  local fresh = h.project("fresh_module", fx.fresh_module())
  n = names(fresh, "src/mypkg/brandnew.py", "src/mypkg/renamed.py")
  h.check("module nothing imports yet", { n.old_dotted, n.inferred }, { "mypkg.brandnew", {} })

  -- Both spellings have to keep working; only the majority is rewritten, so the
  -- other has to be named rather than left quietly stale
  local mixed = h.project("mixed", fx.mixed())
  n = names(mixed, "src/mypkg/utils.py", "src/mypkg/helpers.py")
  h.check("mixed spellings", { n.old_dotted, n.rivals }, { "src.mypkg.utils", { "mypkg.utils" } })

  -- An unquoted search root here returned nothing under `--no-messages`, so
  -- every count silently fell to zero. This layout is the one that notices:
  -- its evidence says the project root while the package chain says `src`
  local spaced = h.project("sp ace", fx.src_dotted())
  h.check("project path with a space", { names(spaced, "src/mypkg/utils.py", "src/mypkg/helpers.py").old_dotted }, { "src.mypkg.utils" })

  h.section "importer paths"
  filesystem.reset_root_cache()
  filesystem.resolve_move_names(src, "src/mypkg/utils.py", "src/mypkg/helpers.py")
  h.check("importer under the settled root", filesystem.import_relative_path(src, src .. "/src/mypkg/sub/b.py"), "mypkg/sub/b.py")
  h.check("importer outside it", filesystem.import_relative_path(src, src .. "/setup.py"), "setup.py")

  -- Roots settled for one project must not be reused for the next. The flat
  -- project settles the project root, which matches every path there is, so a
  -- leak would strip nothing from a file in a src layout
  filesystem.reset_root_cache()
  filesystem.resolve_move_names(flat, "mypkg/utils.py", "mypkg/helpers.py")
  h.check("no leak across projects", filesystem.import_relative_path(src, src .. "/src/mypkg/sub/b.py"), "mypkg/sub/b.py")

  h.section "explicit move.import_root"
  config.options.move.import_root = "src"
  filesystem.reset_root_cache()
  h.check("override wins over inference", { root_of(dotted, "src/mypkg/utils.py", false) }, { "src", false })
  h.check("override drives naming", { names(dotted, "src/mypkg/utils.py", "src/mypkg/helpers.py").old_dotted }, { "mypkg.utils" })
  h.check("override drives importer paths", filesystem.import_relative_path(dotted, dotted .. "/src/mypkg/utils.py"), "mypkg/utils.py")
  config.options.move.import_root = nil

  h.section "discovery"
  filesystem.reset_root_cache()
  n = names(src, "src/mypkg/utils.py", "src/mypkg/helpers.py")
  local change = utils.estimate_change(n.old_dotted, n.new_dotted)
  local found = refactor.find_files_with_pattern(
    utils.file_change_pattern(change, n.old_dotted),
    src,
    "*.py"
  )
  table.sort(found)
  h.check("both importers are collected", found, {
    src .. "/src/mypkg/a.py",
    src .. "/src/mypkg/sub/b.py",
  })
end
