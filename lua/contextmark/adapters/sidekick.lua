-- Sidekick delivery adapter for contextmark.nvim.
local M = {}

function M.is_available()
  local ok, cli = pcall(require, "sidekick.cli")
  if not ok or type(cli.send) ~= "function" then
    return false, "sidekick.nvim is unavailable"
  end
  return true
end

function M.to_text(text)
  local result = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    result[#result + 1] = { { line } }
  end
  return result
end

function M.send(text, _, opts)
  local cli = require("sidekick.cli")
  cli.send({
    text = M.to_text(text),
    name = opts.name,
    focus = opts.focus,
    submit = opts.submit,
  })
  return { accepted = true }
end

return M
