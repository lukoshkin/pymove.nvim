local M = {}

---Run a search without conflating no matches (1) with a failed scan (2+).
---@param argv string[]
---@return string[]? matches
---@return string? error
function M.run(argv)
  local output = vim.fn.systemlist(argv)
  local status = vim.v.shell_error
  if status == 1 then
    return {}
  end
  if status ~= 0 then
    return nil,
      string.format(
        "%s search failed (exit %d): %s",
        argv[1],
        status,
        table.concat(output, "\n")
      )
  end
  return output
end

return M
