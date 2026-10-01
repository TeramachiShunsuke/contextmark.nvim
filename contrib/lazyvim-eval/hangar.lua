-- Phase 1: hangar for parallel worktree agents (Linear-unaware).
-- Needs at least one of: claude | codex | gemini | opencode on PATH.
return {
  {
    "yal212/hangar.nvim",
    cmd = "Hangar",
    keys = {
      { "<leader>oh", "<cmd>Hangar<cr>", desc = "Hangar dashboard" },
      {
        "<leader>os",
        function()
          vim.ui.input({ prompt = "Hangar spawn (safe): " }, function(prompt)
            if not prompt or prompt == "" then
              return
            end
            vim.cmd("Hangar spawn --safe " .. prompt)
          end)
        end,
        desc = "Hangar spawn --safe",
      },
    },
    opts = {
      -- Prefer explicit --safe / --yolo per spawn during the trial week.
      default_permission = nil,
      adapter = "claude_code",
    },
  },
}
