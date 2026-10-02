-- Phase 1: enable LazyVim extras used by the trial stack.
-- Prefer `:LazyExtras` on a personal machine; this file is for reproducible demos.
return {
  { import = "lazyvim.plugins.extras.lang.markdown" },
  { import = "lazyvim.plugins.extras.editor.snacks_picker" },
  { import = "lazyvim.plugins.extras.util.octo" },
  { import = "lazyvim.plugins.extras.ai.sidekick" },
}
