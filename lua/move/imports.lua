---@class ImportMatch
---@field line_num integer 1-indexed line the rewritten span starts on
---@field old_import string Text of the span being rewritten
---@field new_import string Replacement under the active strategy
---@field new_import_absolute string Replacement spelled absolutely
---@field new_import_relative string? Replacement kept relative, nil when none exists
---@field node_range integer[] {start_row, start_col, end_row, end_col}
---@field unfixable boolean? Set when the statement must be edited by hand
---@field reason string? Why it is unfixable
---@field aliased_name string? Name kept alive by a synthesized alias
---@field aliased_to string? Module name it now aliases

local utils = require "move.utils"
local Path = require "plenary.path"

local M = {}

---Statements are walked field-by-field in Lua rather than matched by a
---field-constrained query: `module_name:` holds a `dotted_name` for absolute
---imports but a `relative_import` for relative ones, and the module being moved
---can sit in either that field or the `name:` field.
local QUERY = [[
  (import_from_statement) @from_stmt
  (import_statement) @import_stmt
]]

local query_cache = {}

---@return vim.treesitter.Query
local function get_query()
  if not query_cache.python then
    query_cache.python = vim.treesitter.query.parse("python", QUERY)
  end
  return query_cache.python
end

---@param node TSNode
---@param bufnr integer
---@return string
local function text(node, bufnr)
  return vim.treesitter.get_node_text(node, bufnr)
end

---Unwrap `x as y` into the imported name node and the ` as y` suffix
---@param node TSNode A `name:` field entry
---@param bufnr integer
---@return TSNode name_node
---@return string alias_suffix
local function unwrap_alias(node, bufnr)
  if node:type() ~= "aliased_import" then
    return node, ""
  end
  local name_node = node:field("name")[1]
  local alias = node:field("alias")[1]
  return name_node, alias and (" as " .. text(alias, bufnr)) or ""
end

---@param node TSNode
---@return integer[]
local function range_of(node)
  local start_row, start_col, end_row, end_col = node:range()
  return { start_row, start_col, end_row, end_col }
end

---Where the importer itself ends up, when it lives inside the moved subtree
---
---Only the package components are ever read back out of this, so the renamed
---dotted name is spelled straight into a path rather than rebuilt from the
---original one.
---@param importer_rel_path string
---@param old_dotted string
---@param new_dotted string
---@return string? destination Nil when the importer stays where it is
local function importer_destination(importer_rel_path, old_dotted, new_dotted)
  local ok, dotted = pcall(utils.path_to_dotted_name, importer_rel_path)
  if not ok then
    return nil
  end
  local moved = utils.rename_dotted_prefix(dotted, old_dotted, new_dotted)
  if not moved then
    return nil
  end
  return (moved:gsub("%.", "/")) .. ".py"
end

---Whether a relative import in a moving file still reaches the same module
---
---A relative import travels with its subtree only while both ends of it do.
---`from ..old.util import VALUE` inside `pkg/old` climbs out to `pkg` and names
---the package it just left, so renaming `pkg/old` to `pkg/new` strands it even
---though the module it asks for moved along with the importer.
---@param importer_rel_path string
---@param destination_rel_path string Importer's path after the move
---@param module_text string Text of the `module_name:` field
---@param old_dotted string
---@param new_dotted string
---@return boolean
local function relative_import_survives(
  importer_rel_path,
  destination_rel_path,
  module_text,
  old_dotted,
  new_dotted
)
  local resolved, before =
    pcall(utils.absolute_dotted_path, importer_rel_path, module_text)
  local reresolved, after =
    pcall(utils.absolute_dotted_path, destination_rel_path, module_text)
  if not resolved or not reresolved then
    return false
  end
  local wanted = utils.rename_dotted_prefix(before, old_dotted, new_dotted)
  return after == (wanted or before)
end

---Collect `import a.b` / `import a.b as c` renames
---@param stmt TSNode
---@param bufnr integer
---@param old_dotted string
---@param new_dotted string
---@param matches ImportMatch[]
local function collect_plain_import(
  stmt,
  bufnr,
  old_dotted,
  new_dotted,
  matches
)
  for _, entry in ipairs(stmt:field "name") do
    local name_node = unwrap_alias(entry, bufnr)
    if name_node and name_node:type() == "dotted_name" then
      local name = text(name_node, bufnr)
      local renamed = utils.rename_dotted_prefix(name, old_dotted, new_dotted)
      if renamed then
        local range = range_of(name_node)
        table.insert(matches, {
          line_num = range[1] + 1,
          old_import = name,
          new_import = renamed,
          new_import_absolute = renamed,
          new_import_relative = nil,
          node_range = range,
        })
      end
    end
  end
end

---Collect a rename where the moved module sits in the `module_name:` field
---
---`from src.utils import f` and `from .utils import f` both land here; only the
---module name node is rewritten, so aliases and imported names stay untouched.
---@return boolean matched
local function collect_prefix_rename(ctx, matches)
  local abs_prefix = ctx.abs_prefix
  local renamed =
    utils.rename_dotted_prefix(abs_prefix, ctx.old_dotted, ctx.new_dotted)
  if not renamed then
    return false
  end

  local relative = nil
  if ctx.is_relative then
    relative = utils.relative_dotted_path(ctx.destination_rel_path, renamed)
  end

  local range = range_of(ctx.module_node)
  table.insert(matches, {
    line_num = range[1] + 1,
    old_import = ctx.module_text,
    new_import = renamed,
    new_import_absolute = renamed,
    new_import_relative = relative,
    node_range = range,
  })
  return true
end

---Collect a rename where the moved module sits in the `name:` field
---
---`from . import utils` names the module in `name:`, so both halves of the
---statement change and the whole statement is the rewritten span.
local function collect_name_rename(ctx, matches)
  local entries = ctx.stmt:field "name"
  local stmt_range = range_of(ctx.stmt)

  local function mark_unfixable(reason)
    table.insert(matches, {
      line_num = stmt_range[1] + 1,
      old_import = text(ctx.stmt, ctx.bufnr),
      new_import = text(ctx.stmt, ctx.bufnr),
      new_import_absolute = text(ctx.stmt, ctx.bufnr),
      new_import_relative = nil,
      node_range = stmt_range,
      unfixable = true,
      reason = reason,
    })
  end

  for _, entry in ipairs(entries) do
    local name_node, alias_suffix = unwrap_alias(entry, ctx.bufnr)
    if name_node and name_node:type() == "dotted_name" then
      local imported = text(name_node, ctx.bufnr)
      local new_prefix, new_name = utils.rename_from_import(
        ctx.module_text,
        imported,
        ctx.old_dotted,
        ctx.new_dotted,
        ctx.importer_rel_path
      )

      if new_prefix then
        if #entries > 1 then
          mark_unfixable(
            "statement imports several names; move `"
              .. imported
              .. "` onto its own line first"
          )
          return
        end
        if stmt_range[1] ~= stmt_range[3] then
          mark_unfixable "statement spans several lines; join it first"
          return
        end
        if new_prefix == "" then
          mark_unfixable(
            "`"
              .. new_name
              .. "` now lives at the import root; use `import "
              .. new_name
              .. "` instead"
          )
          return
        end

        -- `from . import utils` binds `utils`; renaming the module would
        -- rebind it and break every `utils.foo()` in the file, so keep the
        -- original name alive as an alias. An explicit alias already does that.
        local synthesized = nil
        if alias_suffix == "" and new_name ~= imported then
          alias_suffix = " as " .. imported
          synthesized = imported
        end

        local absolute = string.format(
          "from %s import %s%s",
          new_prefix,
          new_name,
          alias_suffix
        )

        local relative = nil
        local rel_prefix =
          utils.relative_dotted_path(ctx.destination_rel_path, new_prefix)
        if rel_prefix then
          relative = string.format(
            "from %s import %s%s",
            rel_prefix,
            new_name,
            alias_suffix
          )
        end

        table.insert(matches, {
          line_num = stmt_range[1] + 1,
          old_import = text(ctx.stmt, ctx.bufnr),
          new_import = absolute,
          new_import_absolute = absolute,
          new_import_relative = relative,
          node_range = stmt_range,
          aliased_name = synthesized,
          aliased_to = synthesized and new_name or nil,
        })
        return
      end
    end
  end
end

---@param stmt TSNode
---@param bufnr integer
---@param importer_rel_path string
---@param old_dotted string
---@param new_dotted string
---@param matches ImportMatch[]
local function collect_from_import(
  stmt,
  bufnr,
  importer_rel_path,
  old_dotted,
  new_dotted,
  matches
)
  local module_node = stmt:field("module_name")[1]
  if not module_node then
    return
  end

  local module_text = text(module_node, bufnr)
  local is_relative = module_node:type() == "relative_import"

  -- An importer inside the moved subtree carries its relative imports along,
  -- but only those whose target travels with it
  local destination =
    importer_destination(importer_rel_path, old_dotted, new_dotted)
  if
    is_relative
    and destination
    and relative_import_survives(
      importer_rel_path,
      destination,
      module_text,
      old_dotted,
      new_dotted
    )
  then
    return
  end

  local abs_prefix = module_text
  if is_relative then
    local ok, resolved =
      pcall(utils.absolute_dotted_path, importer_rel_path, module_text)
    if not ok then
      return
    end
    abs_prefix = resolved
  end

  local ctx = {
    stmt = stmt,
    bufnr = bufnr,
    module_node = module_node,
    module_text = module_text,
    abs_prefix = abs_prefix,
    is_relative = is_relative,
    importer_rel_path = importer_rel_path,
    -- The statement is resolved from where the importer is now, but a new
    -- relative spelling has to be written for where it will be
    destination_rel_path = destination or importer_rel_path,
    old_dotted = old_dotted,
    new_dotted = new_dotted,
  }

  if collect_prefix_rename(ctx, matches) then
    return
  end

  -- Only the relative form is in scope here; `from src import utils` is issue #2
  if is_relative then
    collect_name_rename(ctx, matches)
  end
end

---Find every import in a parsed buffer that refers to the moved module
---@param bufnr integer
---@param importer_rel_path string Buffer's path relative to its import root
---@param old_dotted string Dotted name of the module being moved
---@param new_dotted string Dotted name of its destination
---@return ImportMatch[]
function M.find_matches(bufnr, importer_rel_path, old_dotted, new_dotted)
  local parser = vim.treesitter.get_parser(bufnr, "python")
  if not parser then
    error "Python treesitter parser is required"
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    error "Python treesitter parser returned no syntax tree"
  end

  local root = trees[1]:root()
  if root:has_error() then
    error "Python syntax tree contains errors"
  end
  local query = get_query()
  local matches = {}

  for id, node in query:iter_captures(root, bufnr) do
    local capture = query.captures[id]
    if capture == "from_stmt" then
      collect_from_import(
        node,
        bufnr,
        importer_rel_path,
        old_dotted,
        new_dotted,
        matches
      )
    elseif capture == "import_stmt" then
      collect_plain_import(node, bufnr, old_dotted, new_dotted, matches)
    end
  end

  return matches
end

---Cross-package relative imports need source and destination contexts. Until
---that transformation is supported, refuse rather than changing their meaning.
---@param source string Absolute module or package path
---@param old_dotted string
---@param new_dotted string
---@return boolean valid
---@return string? error
function M.validate_relocation(source, old_dotted, new_dotted)
  if
    utils.split_dotted_tail(old_dotted) == utils.split_dotted_tail(new_dotted)
  then
    return true
  end
  -- Walked rather than globbed: `globpath()` reads its first argument as a
  -- comma-separated list of directories, so a comma anywhere in the path split
  -- the source into two that do not exist and the guard silently saw no files
  local files = Path:new(source):is_dir()
      and vim.fs.find(function(name)
        return name:sub(-3) == ".py"
      end, { path = source, type = "file", limit = math.huge })
    or { source }
  for _, file in ipairs(files) do
    local fd, read_error = io.open(file, "r")
    if not fd then
      return false, file .. ": " .. read_error
    end
    local content, content_error = fd:read "*a"
    fd:close()
    if not content then
      return false, file .. ": " .. content_error
    end
    local ok, parser =
      pcall(vim.treesitter.get_string_parser, content, "python")
    if not ok or not parser then
      return false,
        "Cannot check relative imports in "
          .. file
          .. "; Python treesitter parser is required"
    end
    local trees = parser:parse()
    if not trees or not trees[1] or trees[1]:root():has_error() then
      return false, "Cannot parse " .. file
    end
    for id, node in get_query():iter_captures(trees[1]:root(), content) do
      if get_query().captures[id] == "from_stmt" then
        local module_node = node:field("module_name")[1]
        if module_node and module_node:type() == "relative_import" then
          return false,
            string.format(
              "%s:%d: cross-package moves containing relative imports are not supported; convert these imports to absolute form first",
              file,
              node:start() + 1
            )
        end
      end
    end
  end
  return true
end

---Point `new_import` at the spelling the strategy asks for
---
---Imports written absolutely carry no relative candidate, so they render the
---same either way.
---@param match ImportMatch
---@param strategy "absolute"|"preserve"
function M.select_strategy(match, strategy)
  if strategy ~= "absolute" and strategy ~= "preserve" then
    error(
      'move.relative_imports must be "absolute" or "preserve", got '
        .. vim.inspect(strategy)
    )
  end
  if match.unfixable then
    return
  end
  if strategy == "preserve" and match.new_import_relative then
    match.new_import = match.new_import_relative
  else
    match.new_import = match.new_import_absolute
  end
end

return M
