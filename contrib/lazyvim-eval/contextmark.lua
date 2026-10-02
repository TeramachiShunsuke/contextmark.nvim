-- contextmark for Phase 1 feel-check on Mac.
-- Copy to ~/.config/nvim/lua/plugins/contextmark.lua
--
-- Prefer local clone during eval:
--   git clone ... ~/projects/contextmark.nvim

return {
  {
    dir = vim.fn.expand("~/projects/contextmark.nvim"),
    name = "contextmark.nvim",
    -- Don't rely only on ft lazy-load; ensure commands/keys exist after setup.
    event = "VeryLazy",
    ft = { "markdown", "markdown.mdx" },
    opts = {
      delivery = {
        mode = "auto",
        direct = {
          adapter = "sidekick",
          submit = false,
        },
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
    },
  },
}
