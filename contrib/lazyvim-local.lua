return {
  {
    dir = "/Users/steramac/develop/github.com/TeramachiShunsuke/contextmark.nvim",
    name = "contextmark.nvim",
    ft = { "markdown", "markdown.mdx" },
    opts = {
      delivery = {
        mode = "auto",
        fallback_to_clipboard = true,
        direct = {
          adapter = "sidekick",
          name = nil,
          focus = true,
          submit = false,
        },
      },
      keymaps = {
        add = "<leader>ma",
        edit = "<leader>me",
        delete = "<leader>md",
        show = "<leader>mh",
        next = "]m",
        prev = "[m",
        list = "<leader>ml",
        prompt_current = "<leader>mrc",
        prompt_buffer = "<leader>mrb",
        prompt_all = "<leader>mra",
        prompt_select = "<leader>mrs",
      },
    },
  },
  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>mr", group = "markdown review" },
      },
    },
  },
}
