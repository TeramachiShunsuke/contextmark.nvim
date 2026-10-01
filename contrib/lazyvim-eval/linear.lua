-- Linear issue browse / branch create (NOT worktree, NOT agent spawn).
-- Get a key: https://linear.app/settings/api
-- Telescope is required by this plugin.
return {
  {
    "JoeyMckenzie/linear.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-telescope/telescope.nvim",
    },
    cmd = {
      "LinearIssues",
      "LinearIssuesAll",
      "LinearProjects",
      "LinearBranch",
      "LinearSetContext",
      "LinearContext",
    },
    keys = {
      { "<leader>oi", "<cmd>LinearIssues<cr>", desc = "Linear: my issues" },
      { "<leader>oI", "<cmd>LinearIssuesAll<cr>", desc = "Linear: all issues" },
      { "<leader>ob", "<cmd>LinearBranch<cr>", desc = "Linear: branch from context" },
      { "<leader>oc", "<cmd>LinearContext<cr>", desc = "Linear: show context" },
    },
    opts = {
      -- Prefer env so the key never lands in git:
      --   export LINEAR_API_KEY=lin_api_...
      api_key = vim.env.LINEAR_API_KEY,
    },
  },
}
