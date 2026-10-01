# Orca ギャップ評価メモ（Rich previews × Linear）

調査・草案日: 2026-10-01  
前提: LazyVim。モバイルは対象外。作成判断は「既存を組んで足りるか」が先。

## 進め方（このドキュメントの使い方）

1. LazyVim に [contrib/lazyvim-eval](../../contrib/lazyvim-eval/) のスニペットを入れる
2. 下のチェックリストを埋める（○ / △ / × + 一言）
3. 「不足」が **週に何度も手作業で刺さる** ときだけ、薄い glue を検討する

このクラウド環境は `TERM=dumb` で Neovim 未導入のため、**見た目・操作感の最終確認は手元の LazyVim** で行う。

---

## A. Rich previews — どんなふうに見えるか

### A1. 層が3つある（混同しやすい）

| 層 | LazyVim での実体 | 見え方 | 操作感 |
| --- | --- | --- | --- |
| **バッファ内レンダ** | `lang.markdown` extra → `render-markdown.nvim` | 同じバッファのまま見出し色帯・箇条書きアイコン・表枠・callout | Insert では生、Normal では装飾。`<leader>um` で on/off |
| **インライン画像 / PDF** | snacks `image = {}`（**extra では既定オフ**） | Markdown 内の `![]()` や `.pdf` を Kitty 系端末で実表示 | カーソル付近に出る / float。要 ImageMagick + kitty/ghostty/wezterm |
| **ブラウザプレビュー** | 同 extra の `markdown-preview.nvim` | ブラウザで GFM 相当 | `<leader>cp`。編集との往復が増える |

Orca の「Rich repo previews」に一番近いのは **A1+A2（バッファ内 + 画像）**。ブラウザプレビューは別物。

### A2. 見た目の実感（公式デモ）

`render-markdown` は「別ウィンドウのプレビュー」ではなく、**編集画面そのものを綺麗にする**。

<img alt="render-markdown headings" src="/opt/cursor/artifacts/screenshots/render-markdown-heading.png" />

- 左: Insert（生 Markdown）
- 右: Normal（見出しに番号アイコン＋色帯、コードブロックに言語アイコンと背景）

<img alt="render-markdown table" src="/opt/cursor/artifacts/screenshots/render-markdown-table.png" />

- 表の `|` が実線枠に、リンクは URL を隠してアイコン化

<img alt="render-markdown callout" src="/opt/cursor/artifacts/screenshots/render-markdown-callout.png" />

- GitHub / Obsidian 風 `[!NOTE]` などが色付き縦帯＋アイコンになる

<img alt="snacks image" src="/opt/cursor/artifacts/screenshots/snacks-image-demo.png" />

- snacks.image: 端末内に実画像（要 Kitty Graphics Protocol）

### A3. LazyVim での最短enable

```vim
:LazyExtras
" → lang.markdown を有効化
```

画像まで見るなら `~/.config/nvim/lua/plugins/snacks-image.lua`:

```lua
return {
  {
    "folke/snacks.nvim",
    opts = {
      image = {}, -- 既定で markdown/pdf 等
    },
  },
}
```

依存: `magick`（ImageMagick）、端末は kitty / ghostty / wezterm（zellij 不可）。

試用ファイル: [examples/preview-sandbox.md](../../examples/preview-sandbox.md)

### A4. 手元チェックリスト（操作感）

- [ ] `<leader>um` で render の on/off が直感的か
- [ ] Insert 中に装飾が邪魔にならないか（行単位で生に戻るか）
- [ ] 表・callout・長いコードブロックでスクロールが重くないか
- [ ] snacks.image でローカル画像が出るか（`:checkhealth snacks`）
- [ ] PDF を開いた／Markdown からリンクしたときの待ち時間は許容か
- [ ] `<leader>cp` のブラウザプレビューは「編集中に要るか」（多くの場合不要）
- [ ] contextmark の sign / virtual text と見た目が衝突しないか

### A5. 作成判断

| 結論 | 条件 |
| --- | --- |
| **作らない** | 上のチェックがほぼ ○（想定どおり） |
| **設定だけ磨く** | LazyVim 既定の見出しアイコン無しなどが気に入らない |
| **別プラグインを足す** | ブラウザ級 / Mermaid 本格が必要 → remark-preview / mdviewer |
| **新規作成** | ほぼ無い。Orca Artifacts 公開リンク相当が欲しい場合のみ別議論 |

---

## B. Linear — 「何が無いのか」を考える枠

### B1. Orca がやっている一連の流れ

```
Linear issue を見る
  → その issue から worktree を切る
  → agent を起動し、issue 本文を渡す
  → 進捗を issue に戻す（任意）
  → review / merge / PR
```

Neovim エコシステムはここを **分断** している。

### B2. 既存パーツと穴

| 段階 | 既存 | 穴 |
| --- | --- | --- |
| Issue 一覧・詳細 | `JoeyMckenzie/linear.nvim` / `rmanocha/linear-nvim` / `linear-ls` | 成熟度が低い。Snacks picker 前提の定番が無い |
| Branch 名を切る | linear.nvim の `:LinearBranch` | **worktree ではなく branch** |
| Worktree + 並列 agent | `hangar.nvim` / `workmux` | Linear を知らない（prompt は手で渡す） |
| Issue → 自動で agent | **[Agent Valley](https://github.com/first-fluke/agent-valley)** / [pi-linear-worktree](https://github.com/therapys/pi-linear-worktree) | Neovim 外。Valley は webhook 常駐、pi は Pi agent 専用 |
| Note を agent に返す | **contextmark** | Linear とは無関係（それでよい） |

### B3. 「無いもの」の整理（思考用）

足りないのは Linear UI 全体ではなく、だいたい次のどれか。

1. **起動の橋**  
   `issue を選ぶ → hangar/workmux に title+description を渡して spawn`  
   手数が 1〜2 なら glue 不要。毎回 5 手以上なら薄いコマンドが効く。

2. **隔離の橋**  
   Orca / hangar のように **worktree** で切るか、linear.nvim のように **同一 tree の branch** で足りるか。  
   並列 agent をやるなら worktree 必須。一人で順にやるなら branch で足りることが多い。

3. **帰還の橋**  
   完了コメント・状態遷移を Linear に戻すか。  
   戻さないなら PR + ブラウザで十分。戻すなら Agent Valley 側の仕事に近い。

4. **文脈の橋**  
   issue 本文・コメント・関連 issue を prompt に載せるか。  
   hangar にコピペでも回るが、ここが「薄い glue」の本丸になりやすい。

### B4. 新しいプロダクト（Neovim プラグイン以外）

| 名前 | 何か | LazyVim との関係 |
| --- | --- | --- |
| **Agent Valley** | Linear/GitHub webhook → worktree → Claude/Codex/Gemini → merge/PR | エディタ外のオーケストレータ。nvim で「作る」対象ではない。常駐が許容なら最強に近い |
| **pi-linear-worktree** | Pi の `/linear ENG-123` で issue fetch + worktree | Pi ユーザ向け。汎用 LazyVim スタックではない |
| **workmux** | CLI で worktree+tmux+agent | LazyVim と併用しやすい。Linear 橋は自作 or スクリプト |
| **hangar.nvim** | nvim 内ダッシュボードで並列 worktree agent | LazyVim に載せやすい。Linear 連携は未着手 |

### B5. 推奨の試し順（作成前）

1. **手作業ベースラインを測る**（30分）  
   Linear Web → 本文コピー → `:Hangar spawn --yolo ...` または `workmux add ... -p "..."`  
   手数とストレスを記録。
2. **linear.nvim だけ入れる**  
   一覧・preview・branch 作成の操作感。Telescope 依存に注意（LazyVim は Snacks picker 既定）。
3. **まだ刺さるなら glue の最小仕様だけ書く**（実装しない）  
   - 入力: Linear issue id  
   - 出力: hangar spawn prompt（title + description + url）  
   - やらない: webhook、状態遷移、自動 merge
4. **並列を外で回したい**なら Agent Valley を評価し、nvim プラグイン化は避ける

### B6. Linear 手元チェックリスト

- [ ] 週に何回「issue → agent」をやるか（1未満なら作らない）
- [ ] 並列 worktree が必要か、単一 branch で足りるか
- [ ] linear.nvim の Telescope UI が LazyVim で許容か
- [ ] hangar / workmux のどちらを本線にするか
- [ ] 完了を Linear に自動で戻したいか（Yes なら Valley 寄り）
- [ ] API key を nvim に置く運用が許容か

---

## C. マージした判断表

| 領域 | 今すぐ | 試してから | 作るなら |
| --- | --- | --- | --- |
| Rich preview | `lang.markdown` + snacks.image | 操作感チェック A4 | ほぼ作らない |
| Linear 閲覧 | linear.nvim or ブラウザ | B6 | UI 全体は作らない |
| Linear → agent | 手作業 or Valley | 手数計測 | **薄い spawn glue のみ** |
| 並列 orchestration | hangar / workmux | 実機 | 再実装しない |
| Notes | contextmark 継続 | — | 既に本線 |

---

## D. 次のアクション（このリポ内）

- [ ] 手元 LazyVim に `contrib/lazyvim-eval/` を入れる
- [ ] `examples/preview-sandbox.md` で A4 を埋める
- [ ] Linear は B5 の手作業ベースラインを1回やる
- [ ] 結果をこのファイルのチェックに追記してから作成可否を決める
