-- Inline images / PDF via Kitty Graphics Protocol.
-- Needs: kitty | ghostty | wezterm, and ImageMagick (`magick`).
-- Check: :checkhealth snacks
return {
  {
    "folke/snacks.nvim",
    opts = {
      image = {
        -- defaults already include png/jpg/pdf/etc.
        -- set doc.inline = false to prefer floating previews only
      },
    },
  },
}
