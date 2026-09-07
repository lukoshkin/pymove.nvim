local h = require "tests.helpers"
local fx = require "tests.fixtures"
local move = require "move"
local preview = require "move.preview"
local keymaps = require "move.preview.keymaps"
local apply = require "move.preview.apply"
local preview_state = require "move.preview.state"

---@param root string
---@return table<string, string[]>
local function snapshot(root)
  local tree = {}
  for _, file in ipairs(vim.fn.glob(root .. "/**/*", false, true)) do
    if vim.fn.filereadable(file) == 1 then
      tree[file:sub(#root + 2)] = vim.fn.readfile(file, "b")
    end
  end
  return tree
end

---@param root string
---@param old_name string
---@param new_name string
---@return table? state
---@return string? error
local function open_preview(root, old_name, new_name)
  local state, failure
  local setup, notify = keymaps.setup_keymaps, vim.notify
  keymaps.setup_keymaps = function(value, callback)
    state = value
    setup(value, callback)
  end
  vim.notify = function(message, level)
    if level == vim.log.levels.ERROR then
      failure = message
    end
  end
  local ok, err = pcall(
    preview.show_interactive_preview,
    old_name,
    new_name,
    root,
    { use_git = false }
  )
  if ok then
    vim.wait(2000, function()
      return state ~= nil or failure ~= nil
    end, 10)
  end
  keymaps.setup_keymaps, vim.notify = setup, notify
  if not ok then
    error(err)
  end
  return state, failure
end

---@param state table
---@return boolean
---@return string?
local function accept(state)
  for _, change in ipairs(state.changes) do
    if change.status == "pending" then
      change.status = "accepted"
    end
  end
  return apply.apply_accepted_changes(state)
end

---@param mode string
---@param root string
---@param old_name string
---@param new_name string
---@return boolean
---@return string?
local function perform(mode, root, old_name, new_name)
  if mode == "direct" then
    return move.move_module_or_package(
      old_name,
      new_name,
      root,
      { use_git = false }
    )
  end
  local state, err = open_preview(root, old_name, new_name)
  if not state then
    return false, err
  end
  return accept(state)
end

---@param root string
---@param code string
---@param path_entry string?
local function runtime(root, code, path_entry)
  local result = vim
    .system({ "python3", "-c", code }, {
      cwd = root,
      env = { PYTHONPATH = path_entry and (root .. "/" .. path_entry) or root },
      text = true,
    })
    :wait()
  h.check(
    "Python behavior: " .. code,
    { result.code, result.stderr },
    { 0, "" }
  )
end

---@param label string
---@param root string
---@param before table<string, string[]>
---@param ok boolean
local function unchanged(label, root, before, ok)
  h.check(label .. ": refused", ok, false)
  h.check(label .. ": entire tree unchanged", snapshot(root), before)
end

return function()
  h.section "operation contract"
  for _, mode in ipairs { "direct", "preview" } do
    h.case(mode .. ": spaced path and preserved bindings", function()
      local tree = fx.src()
      tree["src/mypkg/utils.py"] = "def f(): return 7"
      tree["src/mypkg/a.py"] = tree["src/mypkg/a.py"]
        .. "\ndef run(): return f() + g() + utils.f()"
      local root = h.project(mode .. " sp ace", tree)
      h.check(
        "move succeeded",
        perform(mode, root, "src/mypkg/utils.py", "src/mypkg/helpers.py"),
        true
      )
      h.check(
        "source removed",
        vim.fn.filereadable(root .. "/src/mypkg/utils.py"),
        0
      )
      h.check(
        "relative name keeps its binding",
        h.lines(root .. "/src/mypkg/a.py")[3],
        "from mypkg import helpers as utils"
      )
      runtime(root, "import mypkg.a; assert mypkg.a.run() == 21", "src")
    end)

    h.case(mode .. ": outward relative imports refuse a module move", function()
      local root = h.project(mode .. "_outward_module", {
        ["pyproject.toml"] = "",
        ["pkg/__init__.py"] = false,
        ["other/__init__.py"] = false,
        ["pkg/sibling.py"] = "VALUE = 7",
        ["pkg/mod.py"] = "from .sibling import VALUE",
        ["consumer.py"] = "from pkg.mod import VALUE",
      })
      local before = snapshot(root)
      unchanged(
        mode,
        root,
        before,
        perform(mode, root, "pkg/mod.py", "other/mod.py")
      )
    end)

    h.case(
      mode .. ": outward relative imports refuse a package move",
      function()
        local root = h.project(mode .. "_outward_package", {
          ["pyproject.toml"] = "",
          ["pkg/__init__.py"] = false,
          ["other/__init__.py"] = false,
          ["pkg/sub/__init__.py"] = false,
          ["pkg/sibling.py"] = "VALUE = 7",
          ["pkg/sub/mod.py"] = "from ..sibling import VALUE",
          ["consumer.py"] = "from pkg.sub.mod import VALUE",
        })
        local before = snapshot(root)
        unchanged(
          mode,
          root,
          before,
          perform(mode, root, "pkg/sub", "other/sub")
        )
      end
    )

    h.case(
      mode .. ": a rename follows imports that name the moved package",
      function()
        local root = h.project(mode .. "_self_reference", fx.self_reference())
        h.check(
          "move succeeded",
          perform(mode, root, "pkg/old", "pkg/new"),
          true
        )
        local moved = h.lines(root .. "/pkg/new/mod.py")
        h.check(
          "climb-and-return import follows the rename",
          moved[1],
          "from pkg.new.util import VALUE"
        )
        h.check(
          "import travelling with the subtree is untouched",
          moved[2],
          "from .util import VALUE as DIRECT"
        )
        h.check(
          "import reaching outside the subtree is untouched",
          moved[3],
          "from ..sibling import OTHER"
        )
        runtime(root, "import consumer; assert consumer.total() == 19")
      end
    )

    h.case(
      mode .. ": punctuation in the path cannot bypass the guard",
      function()
        -- `globpath()` reads its first argument as a comma-separated list of
        -- directories, so a comma here split the source into two paths that do
        -- not exist, the guard saw no files, and the move went ahead
        local root = h.project(mode .. "_comma,root", {
          ["pyproject.toml"] = "",
          ["pkg/__init__.py"] = false,
          ["other/__init__.py"] = false,
          ["pkg/sub/__init__.py"] = false,
          ["pkg/sibling.py"] = "VALUE = 7",
          ["pkg/sub/mod.py"] = "from ..sibling import VALUE",
          ["consumer.py"] = "from pkg.sub.mod import VALUE",
        })
        local before = snapshot(root)
        unchanged(
          mode,
          root,
          before,
          perform(mode, root, "pkg/sub", "other/sub")
        )
      end
    )

    h.case(mode .. ": discovery failure refuses the move", function()
      local root = h.project(mode .. "_search_failure", fx.flat())
      local shim = h.project(
        mode .. "_bad_search",
        { rg = "#!/bin/sh\nexit 2", grep = "#!/bin/sh\nexit 2" }
      )
      vim.fn.setfperm(shim .. "/rg", "rwxr-xr-x")
      vim.fn.setfperm(shim .. "/grep", "rwxr-xr-x")
      local before, path = snapshot(root), vim.env.PATH
      vim.env.PATH = shim .. ":" .. path
      local called, ok =
        pcall(perform, mode, root, "mypkg/utils.py", "mypkg/helpers.py")
      vim.env.PATH = path
      assert(called, ok)
      unchanged(mode, root, before, ok)
    end)

    h.case(mode .. ": parser failure refuses the move", function()
      local root = h.project(mode .. "_parser_failure", fx.flat())
      local before, get_parser = snapshot(root), vim.treesitter.get_parser
      vim.treesitter.get_parser = function()
        return nil
      end
      local called, ok =
        pcall(perform, mode, root, "mypkg/utils.py", "mypkg/helpers.py")
      vim.treesitter.get_parser = get_parser
      assert(called, ok)
      unchanged(mode, root, before, ok)
    end)

    h.case(mode .. ": rewrite preparation failure refuses the move", function()
      local root = h.project(mode .. "_write_failure", fx.flat())
      local before, open = snapshot(root), io.open
      -- luacheck: push ignore 122
      io.open = function(file, access)
        if
          file:sub(1, #root + 1) == root .. "/"
          and (access:find("w", 1, true) or access:find("+", 1, true))
        then
          return nil, "injected write failure"
        end
        return open(file, access)
      end
      local called, ok =
        pcall(perform, mode, root, "mypkg/utils.py", "mypkg/helpers.py")
      io.open = open
      -- luacheck: pop
      assert(called, ok)
      unchanged(mode, root, before, ok)
    end)

    h.case(
      mode .. ": late write failure is reported without truncating the importer",
      function()
        local root = h.project(mode .. "_late_write_failure", fx.flat())
        local importer = h.lines(root .. "/mypkg/a.py")
        local open = io.open
        -- Inject a write failure after permission checks have succeeded.
        -- luacheck: push ignore 122
        io.open = function(file, access)
          local fd, err = open(file, access)
          if
            fd
            and file:sub(1, #root + 1) == root .. "/"
            and access:find("w", 1, true)
          then
            return {
              write = function()
                return nil, "injected disk full"
              end,
              close = function()
                return fd:close()
              end,
            }
          end
          return fd, err
        end
        local called, ok =
          pcall(perform, mode, root, "mypkg/utils.py", "mypkg/helpers.py")
        io.open = open
        -- luacheck: pop
        assert(called, ok)
        h.check("failure is not success", ok, false)
        h.check(
          "importer was not truncated",
          h.lines(root .. "/mypkg/a.py"),
          importer
        )
      end
    )

    h.case(mode .. ": no importers is a valid move", function()
      local root = h.project(
        mode .. "_no_imports",
        { ["pyproject.toml"] = "", ["old.py"] = "VALUE = 7" }
      )
      h.check("move succeeded", perform(mode, root, "old.py", "new.py"), true)
      h.check("source removed", vim.fn.filereadable(root .. "/old.py"), 0)
      h.check(
        "destination content",
        h.lines(root .. "/new.py"),
        { "VALUE = 7" }
      )
    end)

    h.case(
      mode .. ": source rename failure leaves importers unchanged",
      function()
        local root = h.project(mode .. "_rename_failure", fx.flat())
        local before, rename = snapshot(root), vim.uv.fs_rename
        vim.uv.fs_rename = function(source, destination)
          if source == root .. "/mypkg/utils.py" then
            return nil, "injected rename failure"
          end
          return rename(source, destination)
        end
        local called, ok =
          pcall(perform, mode, root, "mypkg/utils.py", "mypkg/helpers.py")
        vim.uv.fs_rename = rename
        assert(called, ok)
        unchanged(mode, root, before, ok)
      end
    )
  end

  h.case(
    "cross-root module move has identical behavior in both paths",
    function()
      local tree = fx.src()
      tree["flatpkg/__init__.py"] = false
      local direct, shown =
        h.project("cross_root_direct", tree),
        h.project("cross_root_preview", tree)
      h.check(
        "direct cross-root move",
        perform("direct", direct, "src/mypkg/utils.py", "flatpkg/helpers.py"),
        true
      )
      h.check(
        "preview cross-root move",
        perform("preview", shown, "src/mypkg/utils.py", "flatpkg/helpers.py"),
        true
      )
      h.check("identical trees across roots", snapshot(shown), snapshot(direct))
      runtime(direct, "import mypkg.a, mypkg.sub.b, flatpkg.helpers", "src")
      runtime(shown, "import mypkg.a, mypkg.sub.b, flatpkg.helpers", "src")
    end
  )

  h.case("preview spelling toggle matches direct preserve mode", function()
    local direct, shown =
      h.project("preserve_direct", fx.src()),
      h.project("preserve_preview", fx.src())
    h.check(
      "direct preserve",
      move.move_module_or_package(
        "src/mypkg/utils.py",
        "src/mypkg/helpers.py",
        direct,
        { use_git = false, relative_imports = "preserve" }
      ),
      true
    )
    local state =
      assert(open_preview(shown, "src/mypkg/utils.py", "src/mypkg/helpers.py"))
    preview_state.set_relative_strategy(state, "preserve")
    h.check("preview preserve", accept(state), true)
    h.check("identical preserved imports", snapshot(shown), snapshot(direct))
    h.check(
      "relative spelling preserved",
      h.lines(shown .. "/src/mypkg/a.py")[2],
      "from .helpers import f as g"
    )
  end)

  h.case(
    "preview applies only accepted edits when the move is declined",
    function()
      local root = h.project("selective_preview", fx.flat())
      local state =
        assert(open_preview(root, "mypkg/utils.py", "mypkg/helpers.py"))
      for _, change in ipairs(state.changes) do
        change.status = change.type ~= "file_move"
            and change.line_num == 1
            and "accepted"
          or "declined"
      end
      h.check(
        "selective apply succeeds",
        apply.apply_accepted_changes(state),
        true
      )
      h.check(
        "source stays put",
        vim.fn.filereadable(root .. "/mypkg/utils.py"),
        1
      )
      h.check(
        "only accepted line changes",
        h.lines(root .. "/mypkg/a.py"),
        { "from mypkg.helpers import f", "from .utils import f as g" }
      )
    end
  )

  h.case("preview and direct package rename produce identical trees", function()
    local tree = fx.flat()
    tree["consumer.py"] = "from mypkg.a import f"
    local direct, shown =
      h.project("package_direct", tree), h.project("package_preview", tree)
    h.check(
      "direct package rename",
      perform("direct", direct, "mypkg", "renamed"),
      true
    )
    local state = assert(open_preview(shown, "mypkg", "renamed"))
    h.check(
      "preview has not changed files",
      snapshot(shown),
      snapshot(h.project("package_original", tree))
    )
    h.check("preview package rename", accept(state), true)
    h.check("identical trees", snapshot(shown), snapshot(direct))
    runtime(direct, "import consumer, renamed.a")
    runtime(shown, "import consumer, renamed.a")
  end)

  h.case("stale preview refuses before moving or rewriting any file", function()
    local root = h.project("stale_preview", fx.src())
    local state =
      assert(open_preview(root, "src/mypkg/utils.py", "src/mypkg/helpers.py"))
    vim.fn.writefile(
      { "# changed after preview", "from mypkg.utils import f" },
      root .. "/src/mypkg/a.py"
    )
    local before = snapshot(root)
    unchanged("stale preview", root, before, accept(state))
  end)

  h.case("missing Python cannot pass an interpreter check", function()
    local executable = vim.fn.executable
    vim.fn.executable = function(name)
      return name == "python3" and 0 or executable(name)
    end
    local ok = h.imports_cleanly("/tmp", { "anything" })
    local bootstrapped = h.bootstrap()
    vim.fn.executable = executable
    h.check("missing Python fails", ok, false)
    h.check("runner refuses missing Python", bootstrapped, false)
  end)
end
