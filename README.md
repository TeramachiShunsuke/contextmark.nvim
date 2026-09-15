# contextmark.nvim

Markdown の選択範囲に、本文を変更せず Note を付ける Neovim プラグインです。
Note はリポジトリ外の sidecar JSON に保存し、Orca と同じ形の prompt として
まとめて、または一部だけ取り出せます。

## できること

- Markdown の現在行、Visual文字範囲、Visual行範囲に Note を追加
- sign、範囲ハイライト、行末 virtual text で Note を表示
- 同じ行の複数 Note は1つの件数マーカーにまとめ、カーソル停止時に全文を hover 表示
- 編集中は extmark で追従し、再読込時は本文と前後文脈から再アンカー
- Note の編集、削除、移動、Quickfix 一覧
- `current` / `buffer` / `all` / 複数選択で prompt を生成
- sidecar は既定で `stdpath("state")/contextmark/` に保存（本文に diff は出ません）

## 必要環境

- Neovim 0.11+

## LazyVim / lazy.nvim

公開リポジトリとして使う場合の例です。

```lua
return {
  "TeramachiShunsuke/contextmark.nvim",
  ft = { "markdown", "markdown.mdx" },
  opts = {},
}
```

ローカル開発中は `dir` を指定できます。

```lua
return {
  dir = "/path/to/contextmark.nvim",
  ft = { "markdown", "markdown.mdx" },
  opts = {},
}
```

## 操作

| キー | 動作 |
| --- | --- |
| `<leader>mc` | 現在行 / Visual 選択へ Note を追加 |
| `<leader>me` | カーソル位置の Note を編集 |
| `<leader>md` | カーソル位置の Note を確認後に削除 |
| `<leader>mh` | カーソル位置の全 Note を hover 表示 |
| `]m` / `[m` | 次 / 前の Note |
| `<leader>ml` | プロジェクトの Note を Quickfix に表示 |
| `<leader>mpc` | カーソル位置の1件を prompt 化 |
| `<leader>mpb` | 現在の Markdown の全件を prompt 化 |
| `<leader>mpa` | プロジェクトの全件を prompt 化 |
| `<leader>mps` | チェック UI で一部を選んで prompt 化 |

同じ操作はコマンドでも使えます。

```vim
:ContextMarkAdd
:ContextMarkEdit
:ContextMarkDelete
:ContextMarkShow
:ContextMarkList
:ContextMarkSend current
:ContextMarkSend buffer
:ContextMarkSend all
:ContextMarkSend select
```

hover は既定で有効です。同じ行に複数の Note がある場合、行末には
`󰍩 6 notes` のように1つだけ表示されます。カーソルをその行で停止するか
`<leader>mh` / `:ContextMarkShow` を実行すると、折り返し付きのウィンドウで
全内容を確認できます。移動すると自動で閉じます。

```lua
opts = {
  display = {
    hover = true,
    hover_max_width = 88,
    hover_max_height = 18,
  },
}
```

生成した prompt の配信は既定で `auto` です。直接送信adapterが利用可能なら
直接送り、未設定・利用不能・例外・拒否の場合は system clipboard へ退避します。

```vim
:ContextMarkSend all auto
:ContextMarkSend all direct
:ContextMarkSend all clipboard
:ContextMarkSend all both
:ContextMarkSendDirect buffer
:ContextMarkSendClipboard select
```

`direct` も既定ではclipboard fallbackが有効です。直接送信以外にも必ず手元へ
残したい場合は `both` を使います。

## Prompt 形式

```text
File: aidd-on-the-loop-summary.md
Source: markdown

Lines 29-32
Excerpt:
> 「人が見る対象を絞る」は既に決定済みで、未反映のまま放置されている。
User comment: "これは反映したいのですが、手続きを計画してほしい。"

Line 50
Excerpt:
> 2. 13段の現在地
User comment: "話がかなり飛躍していてきつい。\nまずは現状の問題点を洗い出したい"
```

`Line` / `Lines`、引用形式、コメントの JSON 文字列化（改行は `\n`）を
Orca の出力に合わせています。複数ファイルでは `File` と `Source` の組が
ファイルごとに繰り返されます。

通常のVisual mode (`v`) では選択文字列だけが `Excerpt` になります。Linewise
Visual (`V`) はVim本来の行選択なので、選択した行全体が `Excerpt` になります。

## 設定

```lua
require("contextmark").setup({
  filetypes = { "markdown", "markdown.mdx" },
  storage = {
    -- nil の場合: stdpath("state") .. "/contextmark"
    dir = nil,
    context_lines = 2,
  },
  delivery = {
    mode = "auto", -- auto | direct | clipboard | both
    fallback_to_clipboard = true,
    direct = {
      -- auto はsidekick.nvimを検出。"sidekick"で明示、"none"で無効化
      adapter = "auto",
      name = nil, -- "codex" / "claude"。nilならSidekick側で選択
      focus = true,
      submit = false, -- FB中に内容を確認してからEnterする
    },
    clipboard = {
      register = "+",
      -- system clipboardがないheadless/SSH環境ではNeovim内のregisterへ退避
      fallback_register = '"',
    },
  },
  keymaps = {
    add = "<leader>mc",
    edit = "<leader>me",
    delete = "<leader>md",
    next = "]m",
    prev = "[m",
    list = "<leader>ml",
    prompt_current = "<leader>mpc",
    prompt_buffer = "<leader>mpb",
    prompt_all = "<leader>mpa",
    prompt_select = "<leader>mps",
  },
})
```

`delivery.direct` は Sidekick、CodeCompanion、terminal/tmux などへの接続点です。
同梱adapterは `sidekick.nvim` を自動検出します。Sidekickへは生のtext構造を渡すため、
Noteに含まれる `{selection}` などがテンプレート展開されることはありません。

独自adapterでは `is_available` と `send` 関数を直接設定できます。`send` は `false, reason`
または `{ accepted = false, reason = "..." }` で失敗を通知できます。戻り値なし、`true`、
`{ accepted = true }` は成功として扱います。

## 保存とアンカー

保存先はプロジェクトルートの絶対パスを SHA-256 で識別した JSON です。
リポジトリ内へファイルを追加しないため、Note の追加で Git diff は発生しません。

アンカーは次の順で復元します。

1. 保存行の本文が一致
2. ファイル内の選択本文を検索し、前後文脈と元の行に近い候補を採用
3. 前後文脈だけで一意に特定
4. 特定できない場合は元の行に `stale` として表示

## 既存プラグインとの違い

調査メモは [docs/design.md](docs/design.md) にまとめています。最も近い
`annotate.nvim` と `haunt.nvim` は有力ですが、Orca 形式と任意の部分選択を
同時には満たさないため、このプラグインでは prompt 選択を中心機能にしています。

## テスト

```sh
nvim --headless -i NONE -u tests/minimal_init.lua -l tests/run.lua
```
