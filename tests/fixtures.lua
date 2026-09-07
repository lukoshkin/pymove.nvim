---Project layouts the import-root rules have to get right
---
---Each entry is a whole Python project. They exist because every one of them
---broke a version of the resolver at some point; the names below are what the
---rule has to distinguish, not arbitrary variety.

local M = {}

local INIT = false -- an empty `__init__.py`

---A src layout whose codebase spells modules from `src/`
---
---The case in issue #3: `pyproject.toml` sits above `src/`, so naming from the
---filesystem root produced `src.mypkg.utils`, which nothing imports.
function M.src()
  return {
    ["pyproject.toml"] = "",
    ["src/mypkg/__init__.py"] = INIT,
    ["src/mypkg/utils.py"] = "def f(): ...",
    ["src/mypkg/a.py"] = table.concat({
      "from mypkg.utils import f",
      "from .utils import f as g",
      "from . import utils",
      "import mypkg.utils",
    }, "\n"),
    ["src/mypkg/sub/__init__.py"] = INIT,
    ["src/mypkg/sub/b.py"] = "from ..utils import f",
  }
end

---The same tree spelled the other way, as a repo-rooted test run sees it
---
---`from src.mypkg.utils import f` is legal with the project root on `sys.path`,
---which is what pytest's rootdir insertion gives you. Naming this project
---`mypkg.utils` would be exactly as wrong as the original bug.
function M.src_dotted()
  return {
    ["pyproject.toml"] = "",
    ["src/mypkg/__init__.py"] = INIT,
    ["src/mypkg/utils.py"] = "def f(): ...",
    ["tests/test_a.py"] = "from src.mypkg.utils import f\nimport src.mypkg.utils",
  }
end

---A project that uses both spellings; only the more common one is rewritten
function M.mixed()
  return {
    ["pyproject.toml"] = "",
    ["src/mypkg/__init__.py"] = INIT,
    ["src/mypkg/utils.py"] = "def f(): ...",
    ["src/mypkg/a.py"] = "from mypkg.utils import f",
    ["tests/test_a.py"] = "from src.mypkg.utils import f",
    ["tests/test_b.py"] = "from src.mypkg.utils import f",
  }
end

---An ordinary flat package
function M.flat()
  return {
    ["pyproject.toml"] = "",
    ["mypkg/__init__.py"] = INIT,
    ["mypkg/utils.py"] = "def f(): ...",
    ["mypkg/a.py"] = "from mypkg.utils import f\nfrom .utils import f as g",
  }
end

---A module whose basename collides with a stdlib module
---
---`mypkg` is a package, so it can never be the import root -- but a resolver
---that offers it as a candidate scores the bare name `logging`, sees three
---ordinary `import logging` lines vote for it, and renames the stdlib import in
---every file.
function M.stdlib_clash()
  return {
    ["pyproject.toml"] = "",
    ["mypkg/__init__.py"] = INIT,
    ["mypkg/logging.py"] = "LOG = 1",
    ["mypkg/a.py"] = table.concat({
      "import logging",
      "from mypkg.logging import LOG",
      "",
      "log = logging.getLogger(__name__)",
    }, "\n"),
    ["mypkg/b.py"] = "import logging\nlog = logging.getLogger(__name__)",
    ["tests/test_a.py"] = "import logging",
  }
end

---A namespace package wrapping a regular one
---
---`ns/` has no `__init__.py` but is part of the name: CPython imports this as
---`ns.pkg.utils`. Structurally identical to a src layout, so only the imports
---already in the tree separate the two.
function M.ns_wrapping()
  return {
    ["pyproject.toml"] = "",
    ["ns/pkg/__init__.py"] = INIT,
    ["ns/pkg/utils.py"] = "def f(): ...",
    ["ns/pkg/a.py"] = table.concat({
      "import ns.pkg.utils",
      "from ns.pkg.utils import f",
      "from . import utils",
      "from .utils import f as f2",
    }, "\n"),
    ["ns/pkg/sub/__init__.py"] = INIT,
    ["ns/pkg/sub/b.py"] = "from ..utils import f",
  }
end

---A top-level namespace package with only relative imports inside it
function M.ns_top()
  return {
    ["pyproject.toml"] = "",
    ["nspkg/utils.py"] = "def f(): ...",
    ["nspkg/a.py"] = "from . import utils\nfrom .utils import f",
    ["nspkg/sub/__init__.py"] = INIT,
    ["nspkg/sub/b.py"] = "from ..utils import f",
  }
end

---A directory holding modules but carrying no `__init__.py`
function M.ns_dir()
  return {
    ["pyproject.toml"] = "",
    ["mypkg/utils.py"] = "def f(): ...",
    ["mypkg/a.py"] = "from . import utils",
  }
end

---A non-package directory between two packages
---
---`a/` is a package, so `a/b` cannot be a source root -- this one is decidable
---from the tree alone, and a resolver that stops at the first missing
---`__init__.py` walking up gets it wrong.
function M.deep()
  return {
    ["pyproject.toml"] = "",
    ["a/__init__.py"] = INIT,
    ["a/b/c/__init__.py"] = INIT,
    ["a/b/c/utils.py"] = "def f(): ...",
    ["a/b/c/mod.py"] = "import a.b.c.utils\nfrom . import utils",
  }
end

---A src layout containing a module nothing imports yet
---
---Scoring only the module being moved finds no evidence and reports the root as
---a guess, even though its neighbours pin it beyond doubt.
function M.fresh_module()
  return {
    ["pyproject.toml"] = "",
    ["src/mypkg/__init__.py"] = INIT,
    ["src/mypkg/utils.py"] = "def f(): ...",
    ["src/mypkg/brandnew.py"] = "def g(): ...",
    ["src/mypkg/a.py"] = "from mypkg.utils import f\nimport mypkg.utils",
  }
end

---A package whose modules reach a sibling by climbing out and naming it
---
---`from ..old.util import VALUE` reaches the same module as `from .util`, but
---it spells the package it climbed out of. Renaming `pkg/old` moves that target
---along with the importer, so a rule that asks only whether the importer moves
---leaves the statement pointing at a `pkg.old` that no longer exists. The other
---two imports are the cases that must stay untouched: one whose target travels
---with the subtree, one that reaches outside it and the rename never touches.
function M.self_reference()
  return {
    ["pyproject.toml"] = "",
    ["pkg/__init__.py"] = INIT,
    ["pkg/sibling.py"] = "OTHER = 5",
    ["pkg/old/__init__.py"] = INIT,
    ["pkg/old/util.py"] = "VALUE = 7",
    ["pkg/old/mod.py"] = table.concat({
      "from ..old.util import VALUE",
      "from .util import VALUE as DIRECT",
      "from ..sibling import OTHER",
      "",
      "def total(): return VALUE + DIRECT + OTHER",
    }, "\n"),
    ["consumer.py"] = "from pkg.old.mod import total",
  }
end

---Many importer directories outside the source root, for the scan-count guard
---@param importer_dirs integer
---@param padding integer
function M.wide(importer_dirs, padding)
  local tree = {
    ["pyproject.toml"] = "",
    ["src/mypkg/__init__.py"] = INIT,
    ["src/mypkg/utils.py"] = "def f(): ...",
  }
  for i = 1, importer_dirs do
    tree[("tools/d%d/t.py"):format(i)] = "from mypkg.utils import f"
  end
  for i = 1, padding do
    tree[("src/mypkg/pad%d.py"):format(i)] = "x = 1"
  end
  return tree
end

return M
