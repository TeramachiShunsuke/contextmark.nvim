-- Parallel agent worktrees inside Neovim (Orca-like race), Linear-unaware.
-- Needs: git + at least one of claude|codex|gemini|opencode on PATH.
return {
  {
    "yal212/hangar.nvim",
    cmd = "Hangar",
    keys = {
      { "<leader>oh", "<cmd>Hangar<cr>", desc = "Hangar dashboard" },
    },
    opts = {
      -- During eval, prefer being explicit per spawn:
      --   :Hangar spawn --safe fix flaky auth
      --   :Hangar spawn --n 2 --safe same prompt race
      default_permission = nil,
      adapter = "claude_code",
    },
  },
}
