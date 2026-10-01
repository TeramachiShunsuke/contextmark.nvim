# LazyVim 評価用スニペット

Orca ギャップ調査（Rich previews / Linear）用。  
本番設定に混ぜる前に、コピーして試すこと。

詳細な観点は [docs/eval/orca-gaps.md](../../docs/eval/orca-gaps.md)。

## 入れ方

LazyVim の `~/.config/nvim/lua/plugins/` に、使いたいファイルだけ置く。

| ファイル | 目的 |
| --- | --- |
| `phase1-extras.lua` | Phase 1 extras（markdown / snacks_picker / octo / sidekick） |
| `markdown-extra.lua` | `lang.markdown` のみ（単体用） |
| `snacks-image.lua` | インライン画像 / PDF |
| `hangar.lua` | 並列 worktree agent（Phase 1 本線） |
| `linear.lua` | Linear 閲覧（**Phase 2 検討用。Phase 1 では使わない**） |

## 最小手順

1. `:LazyExtras` → `lang.markdown` を Enable（`markdown-extra.lua` は不要になる）
2. `snacks-image.lua` を置き、端末が kitty/ghostty/wezterm であることと `magick` を確認
3. このリポの `examples/preview-sandbox.md` を開く
4. `<leader>um` / `<leader>cp` / 画像行への移動を試す
5. Linear を試すなら `LINEAR_API_KEY` を用意して `linear.lua`
6. 並列を試すなら `hangar.lua`（agent CLI が PATH にあること）

## 注意

- `linear.nvim` は Telescope 前提。LazyVim 既定の Snacks picker とは別 UI になる
- hangar の `--yolo` は権限バイパス。評価時は使い捨てブランチで
- Agent Valley / workmux は Neovim プラグインではない（別プロセス）
