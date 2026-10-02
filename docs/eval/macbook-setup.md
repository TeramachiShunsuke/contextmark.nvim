# MacBook での使用感確認手順（Phase 1）

対象: いま使っている Mac。Cloud VM ではなく **日常の LazyVim** で触る用。  
ゴール: render / contextmark / sidekick / hangar / octo の操作感を短時間で確かめる。

関連: [phase1-runbook.md](phase1-runbook.md) / [target-shape.md](target-shape.md)

---

## 0. 前提チェック（ターミナルで）

```bash
sw_vers
uname -m
nvim --version | head -2          # 0.11+ 必須（推奨 0.12+）
echo "TERM=$TERM"
command -v kitty ghostty wezterm  # 画像プレビュー用（どれか1つ）
command -v magick || command -v convert
command -v git gh
command -v claude
test -d ~/.config/nvim && echo "nvim config: yes" || echo "nvim config: no"
```

不足があれば下の「足りないときの入れ方」へ。

---

## 1. 足りないときの入れ方（Homebrew 想定）

### Neovim

```bash
brew install neovim
nvim --version | head -1
```

### 端末（snacks.image 用）

どれか1つ:

```bash
brew install --cask kitty
# または
brew install --cask ghostty
# または
brew install --cask wezterm
```

**iTerm2 / Terminal.app では画像インラインは期待しない。** 確認は Kitty 等から `nvim` を起動する。

### ImageMagick

```bash
brew install imagemagick
magick -version | head -1
```

### GitHub CLI（octo 用・未導入なら）

```bash
brew install gh
gh auth login
```

### Claude Code（sidekick / hangar 用）

```bash
curl -fsSL https://claude.ai/install.sh | bash
# または公式ドキュメントの最新手順
claude --version
claude                  # 初回ログイン
claude auth status      # loggedIn: true
```

---

## 2. LazyVim の用意

### すでに LazyVim がある場合

そのまま次へ（設定を足すだけ）。

### まだ無い場合

```bash
# 既存設定があるなら退避
mv ~/.config/nvim ~/.config/nvim.bak.$(date +%Y%m%d) 2>/dev/null || true

git clone https://github.com/LazyVim/starter ~/.config/nvim
rm -rf ~/.config/nvim/.git
nvim   # 初回プラグイン同期。終わったら一度終了してよい
```

---

## 3. contextmark を置く

公開リポとして使う場合:

```lua
-- ~/.config/nvim/lua/plugins/contextmark.lua
return {
  {
    "TeramachiShunsuke/contextmark.nvim",
    ft = { "markdown", "markdown.mdx" },
    opts = {
      delivery = {
        mode = "auto",
        direct = { adapter = "sidekick", submit = false },
      },
    },
  },
}
```

ローカル開発（clone して触る）場合:

```bash
mkdir -p ~/projects
git clone https://github.com/TeramachiShunsuke/contextmark.nvim.git ~/projects/contextmark.nvim
# 評価ブランチを見るなら:
# cd ~/projects/contextmark.nvim && git fetch && git checkout cursor/orca-gap-eval-ed3f
```

```lua
-- ~/.config/nvim/lua/plugins/contextmark.lua
return {
  {
    dir = vim.fn.expand("~/projects/contextmark.nvim"),
    name = "contextmark.nvim",
    ft = { "markdown", "markdown.mdx" },
    opts = {
      delivery = {
        mode = "auto",
        direct = { adapter = "sidekick", submit = false },
      },
    },
  },
}
```

---

## 4. Phase 1 プラグインを足す

### 4-A. LazyExtras（推奨）

nvim を開いて:

```vim
:LazyExtras
```

次を Enable:

- `lang.markdown`
- `editor.snacks_picker`
- `util.octo`
- `ai.sidekick`

### 4-B. 追加ファイルをコピー

リポの `contrib/lazyvim-eval/` から:

```bash
# clone 済みなら
CONF=~/projects/contextmark.nvim/contrib/lazyvim-eval
# または raw を curl でも可

mkdir -p ~/.config/nvim/lua/plugins
cp "$CONF/snacks-image.lua" ~/.config/nvim/lua/plugins/
cp "$CONF/hangar.lua"       ~/.config/nvim/lua/plugins/
cp "$CONF/octo-tune.lua"    ~/.config/nvim/lua/plugins/
```

`linear.lua` は Phase 1 では **入れない**（ブラウザで手数を測る）。

### 4-C. 同期

```vim
:Lazy sync
```

確認:

```vim
:checkhealth contextmark
:checkhealth hangar
:checkhealth sidekick
:checkhealth snacks
```

---

## 5. 使用感チェック（30–60分）

デモ用 Markdown（リポ内）:

```bash
nvim ~/projects/contextmark.nvim/examples/preview-sandbox.md
# または
nvim ~/projects/contextmark.nvim/examples/feedback.md
```

| # | 何を見る | 操作 |
| --- | --- | --- |
| 1 | Markdown の見た目 | Normal で装飾、`i` で生に戻るか。`<Space>u m` で toggle |
| 2 | 画像 | Kitty 等から開く。だめなら `:lua Snacks.image.hover()` |
| 3 | Note | `V` → `<Space>m c` → 入力 → `Ctrl-s` |
| 4 | Sidekick | `<Space>a a` で claude を開く |
| 5 | Note 送信 | `<Space>m p c` または `<Space>m p b`（Sidekick / clipboard） |
| 6 | Octo | `<Space>g p` または `:Octo pr list` |
| 7 | Hangar | 下のサンドボックスで `:Hangar spawn --safe ...` |

### Hangar 用の使い捨てリポ（本リポを汚さない）

```bash
mkdir -p ~/preview-demo && cd ~/preview-demo
git init -b main hangar-sandbox && cd hangar-sandbox
echo '# hangar sandbox' > README.md
echo 'local M = {} return M' > main.lua
git add . && git commit -m init
nvim README.md
```

```vim
:Hangar spawn --safe add a hello function to main.lua
:Hangar
```

`d` diff / `x` discard まで触る。余裕があれば `--n 2`。

---

## 6. Linear（ブラウザのみ）

プラグインは入れない。1回だけ手数をメモ:

```text
issue を開く → 本文コピー → hangar か sidekick に貼る → 起動
手数: ___
痛さ 0-5: ___
glue が欲しい?: yes/no
```

記録先の例: リポの `docs/eval/phase1-log.md`

---

## よくある詰まり

| 症状 | 対処 |
| --- | --- |
| **`<Space>a a` が無い** | Sidekick が入っていない。下の「キーが無いとき」を実施 |
| **`<Space>m p b` が無い** | Markdown バッファ以外では効かない。contextmark 未ロードも疑う |
| **`:Hangar` / `:Octo` が unknown** | プラグイン未インストール。`phase1-stack.lua` を入れて `:Lazy sync` |
| 画像が出ない | Kitty/Ghostty/WezTerm から起動。`magick` と `:checkhealth snacks` |
| Sidekick に claude が無い | `which claude`。nvim をターミナルから起動（PATH） |
| Hangar spawn 失敗 | `claude auth status`。`:checkhealth hangar` |
| Octo Projects エラー | `octo-tune.lua` または `phase1-stack.lua`（projects v2 off） |

### キーが無いとき（いちばん多い）

`:LazyExtras` だけだとうまく入らないことがある。**明示ファイルで入れる:**

```bash
REPO=~/projects/contextmark.nvim
mkdir -p ~/.config/nvim/lua/plugins

# Sidekick / Octo / Hangar / snacks.image を一括
cp "$REPO/contrib/lazyvim-eval/phase1-stack.lua" ~/.config/nvim/lua/plugins/

# contextmark
cp "$REPO/contrib/lazyvim-eval/contextmark.lua" ~/.config/nvim/lua/plugins/
# dir パスが違う場合は contextmark.lua を編集
```

nvim で:

```vim
:Lazy sync
:Lazy
" sidekick.nvim / octo.nvim / hangar.nvim / contextmark.nvim があるか見る
```

確認コマンド:

```vim
:lua =require("lazy.core.config").plugins["sidekick.nvim"] ~= nil
:lua =require("lazy.core.config").plugins["octo.nvim"] ~= nil
:lua =require("lazy.core.config").plugins["hangar.nvim"] ~= nil
:lua =require("lazy.core.config").plugins["contextmark.nvim"] ~= nil
```

すべて `true` になったら:

| 操作 | キー / コマンド | 注意 |
| --- | --- | --- |
| Sidekick | `<Space>a a` | which-key で `+ai` が出るはず |
| CLI 選択 | `<Space>a s` | installed のみ |
| Note 送信（buffer） | `<Space>m p b` | **markdown ファイルを開いた状態で** |
| または | `:ContextMarkSend buffer` | filetype 不問の確認用 |
| Octo PR | `<Space>g p` または `:Octo pr list` | `gh auth status` が OK なこと |
| Hangar | `<Space>o h` または `:Hangar` | spawn は小さな git リポで |

`which-key` で `<Space>` のあと `a` / `m` / `o` / `g` グループが見えなければ、まだロード失敗です。`:messages` と `:Lazy` のエラーを確認してください。

---

## 8. 完了の目安

次ができたら「Mac での使用感確認」は一通り完了:

- [ ] render on/off の感触が分かった
- [ ] Note 追加〜送信まで1回通った
- [ ] Sidekick で claude と話した
- [ ] Hangar を1回 spawn した（成功 or 原因が分かった）
- [ ] Octo で PR 一覧を見た（任意）
- [ ] Linear 貼り付けの痛さを1行書いた

その結果で Phase 2（glue を作るか）を決める。
