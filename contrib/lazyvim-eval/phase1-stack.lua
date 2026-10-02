-- Phase 1 stack for LazyVim / lazy.nvim (Mac feel-check).
-- Drop this ONE file into ~/.config/nvim/lua/plugins/phase1-stack.lua
-- then restart nvim and run :Lazy sync
--
-- Does NOT depend on :LazyExtras succeeding.
-- Safe alongside LazyExtras (duplicate specs merge).

return {
  ---------------------------------------------------------------------------
  -- Sidekick (Space a a)
  ---------------------------------------------------------------------------
  {
    "folke/sidekick.nvim",
    opts = {
      -- NES needs Copilot LSP; CLI works without it.
      nes = { enabled = false },
    },
    keys = {
      { "<leader>a", "", desc = "+ai", mode = { "n", "v" } },
      {
        "<leader>aa",
        function()
          require("sidekick.cli").toggle()
        end,
        desc = "Sidekick Toggle CLI",
      },
      {
        "<leader>as",
        function()
          require("sidekick.cli").select({ filter = { installed = true } })
        end,
        desc = "Sidekick Select CLI",
      },
      {
        "<c-.>",
        function()
          require("sidekick.cli").focus()
        end,
        mode = { "n", "t", "i", "x" },
        desc = "Sidekick Focus",
      },
    },
  },

  ---------------------------------------------------------------------------
  -- Octo (GitHub PR/Issue) — needs gh auth
  ---------------------------------------------------------------------------
  {
    "pwntester/octo.nvim",
    cmd = "Octo",
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
    opts = {
      enable_builtin = true,
      default_to_projects_v2 = false,
      default_merge_method = "squash",
      -- LazyVim default picker is often snacks; fall back gracefully
      picker = "snacks",
    },
    keys = {
      { "<leader>gi", "<cmd>Octo issue list<CR>", desc = "List Issues (Octo)" },
      { "<leader>gp", "<cmd>Octo pr list<CR>", desc = "List PRs (Octo)" },
      { "<leader>gP", "<cmd>Octo pr search<CR>", desc = "Search PRs (Octo)" },
    },
  },

  ---------------------------------------------------------------------------
  -- Hangar (parallel agents)
  ---------------------------------------------------------------------------
  {
    "yal212/hangar.nvim",
    cmd = "Hangar",
    keys = {
      { "<leader>oh", "<cmd>Hangar<cr>", desc = "Hangar dashboard" },
      {
        "<leader>os",
        function()
          vim.ui.input({ prompt = "Hangar spawn --safe: " }, function(prompt)
            if prompt and prompt ~= "" then
              vim.cmd("Hangar spawn --safe " .. prompt)
            end
          end)
        end,
        desc = "Hangar spawn --safe",
      },
    },
    opts = {
      default_permission = nil,
      adapter = "claude_code",
    },
  },

  ---------------------------------------------------------------------------
  -- snacks.image (optional rich preview)
  ---------------------------------------------------------------------------
  {
    "folke/snacks.nvim",
    opts = {
      image = {
        enabled = true,
        doc = { enabled = true, inline = true, float = true },
      },
    },
  },
}
