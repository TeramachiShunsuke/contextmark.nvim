-- Configuration for contextmark.nvim.
local M = {}

local defaults = {
  filetypes = { "markdown", "markdown.mdx" },
  storage = {
    dir = nil,
    context_lines = 2,
  },
  delivery = {
    mode = "auto",
    fallback_to_clipboard = true,
    direct = {
      adapter = "auto",
      is_available = nil,
      send = nil,
      name = nil,
      focus = true,
      submit = false,
    },
    clipboard = {
      register = "+",
      fallback_register = '"',
    },
  },
  display = {
    sign = "N",
    stale_sign = "?",
    mismatch_sign = "!",
    max_virtual_text = 60,
    hover = true,
    hover_max_width = 88,
    hover_max_height = 18,
  },
  keymaps = {
    add = "<leader>mc",
    edit = "<leader>me",
    delete = "<leader>md",
    show = "<leader>mh",
    next = "]m",
    prev = "[m",
    list = "<leader>ml",
    prompt_current = "<leader>mpc",
    prompt_buffer = "<leader>mpb",
    prompt_all = "<leader>mpa",
    prompt_select = "<leader>mps",
  },
}

local current = vim.deepcopy(defaults)

function M.setup(opts)
  current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  return current
end

function M.get()
  return current
end

return M
