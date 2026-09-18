# contextmark.nvim

選択範囲に、本文を変更せず Note を付ける Neovim プラグインです。
Note はリポジトリ外の sidecar JSON に保存し、Orca と同じ形の prompt として
まとめて、または一部だけ取り出せます。

既定の対象は Markdown ですが、選択範囲の記録やアンカー追従は filetype に依存しないため、
`filetypes` を変えれば任意の filetype で同じように使えます（prompt の `Source:` 行だけは
Markdown 系を `markdown` に揃えます）。

## できること

- 現在行、Visual文字範囲、Visual行範囲に Note を追加
- sign、範囲ハイライト、行末 virtual text で Note を表示
- 同じ行の複数 Note は1つの件数マーカーにまとめ、カーソル停止時に全文を hover 表示
- 編集中は extmark で追従し、再読込時は本文と前後文脈から再アンカー
- Note の編集、削除、移動、Quickfix 一覧
- `current` / `buffer` / `all` / 複数選択で prompt を生成
- sidecar は既定で `stdpath("state")/contextmark/` に保存（本文に diff は出ません）
- ファイルが差し替わったことを検知し、別ファイルへの誤アタッチを警告（prompt にも伝播）
- エディタ内のリネーム（`:saveas` / LSP rename）に追従し、外部でのリネームは
  記録した内容の指紋から移動先を探せる

## 必要環境

- Neovim 0.11+

## アップグレード時の注意（破壊的変更）

Note の紐付けキーの決め方を変えたため、次に当てはまる既存 Note は
`:ContextMarkAdopt` で取り込み直す必要があります。sidecar JSON は消していないので、
Note そのものは失われていません。

- **`.git` が無いツリーの Note** — 以前は cwd からプロジェクトルートを決めていたため、
  `:cd` するだけで紐付けが変わり、cwd 外のファイルは同名ファイルとキーを共有していました。
  今はファイル自身のディレクトリを root にします

該当ファイルを開くと、未接続の sidecar がある旨を1度だけ通知します。
`:ContextMarkAdopt` は、Note ごとに「そのファイルが今このプロジェクトに属するか」を確かめて
取り込みます。同じ名前のファイルがあるだけの別プロジェクトの Note は取り込みません。

次の場合は自動で移行されるので、操作は不要です。

- プロジェクトルート自体を symlink 経由で開いていた場合の sidecar は、そのプロジェクトを
  初めて開いたときに統合されます
- 同じプロジェクト内でファイル自体が symlink だった Note（`alias.md -> real.md`）は、
  そのプロジェクトのファイルを初めて開いたときに実ファイルのキーへ付け替えます

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
| `<leader>mpb` | 現在のバッファの全件を prompt 化 |
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

ファイルの移動やリネームに対応するコマンドもあります。

```vim
:ContextMarkMove docs/old.md docs/new.md  " Note の紐付け先を手で付け替える
:ContextMarkRelocate                     " 消えたファイルの移動先を内容から探す
:ContextMarkReanchor                     " 今このパスにあるファイルを正しいものとして受け入れる
:ContextMarkAdopt                        " 別の root に記録された sidecar を取り込む
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

## 対象 filetype

`filetypes` は次の3つの書き方を受け付けます。

```lua
-- 完全一致
filetypes = { "markdown", "markdown.mdx", "lua", "python" }

-- glob（"*" が任意の文字列にマッチ）
filetypes = { "markdown*", "*script*" }

-- すべての filetype
filetypes = { "*" }

-- 述語関数
filetypes = function(filetype)
  return filetype ~= "" and filetype ~= "help"
end
```

lazy.nvim の `ft` で遅延ロードしている場合、`ft` に含まれない filetype では
プラグイン自体が読み込まれません。Markdown 以外でも使うなら `ft` も合わせて広げるか、
`ft` を外して `event = "VeryLazy"` などにしてください。

```lua
return {
  "TeramachiShunsuke/contextmark.nvim",
  event = "VeryLazy",
  opts = { filetypes = { "*" } },
}
```

`Source:` 行には filetype がそのまま入ります（Markdown 系のみ `markdown` に正規化）。

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
  display = {
    sign = "N",
    stale_sign = "?", -- stale / orphaned
    mismatch_sign = "!", -- このパスのファイルが別物に見える
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

Note とファイルの紐付けは、プロジェクトルートからの相対パスです。パスは symlink を
解決してから使うため、macOS の `/tmp` のように実体が別の場所にある経路で開いても、
同じファイルは常に同じ sidecar を指します。`.git` が見つからない場合はファイル自身の
ディレクトリを root にするので、`:cd` しても紐付けは変わりません。

以前のバージョンでシンボリックリンク経由のパスで保存した Note は、そのプロジェクトを
初めて開いたときに自動で統合されます。統合元の JSON は `.migrated` を付けて残します。

アンカーは次の順で復元します。

1. 保存行の本文が一致 → `exact`
2. ファイル内の選択本文を検索し、前後文脈と元の行に近い候補を採用 → `moved`
3. 特定できない場合は元の行に留める → `stale`
4. ファイルが空 → `orphaned`

### ファイルが差し替わった場合

パスだけでは「編集された同じファイル」と「同じパスに来た別のファイル」を区別できません。
`## 概要` や `- [ ] TODO` のような定型行は無関係な文書にも現れるため、前後文脈だけでは
判定できないからです。

このため Note を持つファイルごとに内容の指紋（全体のハッシュと、空行を除いた重複しない
行を文書全体から等間隔に採ったサンプル）を記録し、開くたびに照合します。9割以上の行が
入れ替わったときだけ「差し替わった」と判定します。行の比較は空白の量の違い（前後の空白や連続する空白）を無視するので、
保存時の行末空白除去やインデントの一括変更では判定は変わりません。段落単位の指紋も
記録しているので、折り返し幅を変えて全行が変わっても同じファイルとして扱います。短い文書
（有意行が10行未満）は判定材料が足りないため、警告も保証もしません。

同じテンプレートから作った文書（front matter や見出しを共有する ADR など）は、定型行だけで
似て見えます。ファイルの一致が弱いときは Note 側も確認し、どの Note も自分の前後の文章を
見つけられなければ「差し替わった」と判定します。

開いていないファイルも、prompt を作るときにディスク上の内容と照合します。差し替わっていれば
その prompt では `Status: different file? ...` として扱います（sidecar は書き換えません）。

差し替わったと判定した間は、

- Note を `mismatch`（既定の sign は `!`、`ContextMarkMismatch` で強調）として表示
- 保存済みの excerpt と前後文脈を**上書きしない**（`:w` しても失われません）
- prompt に `Status: different file? ...` の行を足し、excerpt は保存済みの本文を使う

元のファイルが同じパスに戻れば、指紋が再び一致して自動的に `exact` へ復帰します。
意図的な全面改稿だった場合は `:ContextMarkReanchor` で今のファイルを受け入れます
（保存済みの excerpt を置き換える操作なので、未保存の変更があるバッファでは実行できません。
置き換え前の値は sidecar の `previous_anchor` に残ります）。

| status | 意味 | 表示 |
| --- | --- | --- |
| `exact` / `moved` | 追従できている | 通常色 |
| `stale` | 本文が編集され位置を決められない | 警告色 `?` |
| `orphaned` | ファイルが空 | 警告色 `?` |
| `mismatch` | このパスのファイルが別物に見える | 強調色 `!` |

### リネームと移動

- `:saveas` や LSP のリネームは、元のファイルが無くなった時点で Note が追従します
  （`:saveas` は元ファイルが残るコピーなので、その Note は元ファイルに留まります）
- 外部の `mv` / `git mv` は検知できないので、`:ContextMarkRelocate` で記録した指紋に
  一致するファイルを探して付け替えます。パスが分かっているなら `:ContextMarkMove` が確実です
- プロジェクトごと移動・改名した場合、sidecar 名のハッシュが変わるため既存 Note は
  参照されなくなります。ファイルは消えていないので `:ContextMarkAdopt` で取り込めます
  （元の場所が無くなっている場合、同じパスのファイルが現在のプロジェクトに実在する Note だけが
  対象です。起動時の通知には含めません）

## 既存プラグインとの違い

調査メモは [docs/design.md](docs/design.md) にまとめています。最も近い
`annotate.nvim` と `haunt.nvim` は有力ですが、Orca 形式と任意の部分選択を
同時には満たさないため、このプラグインでは prompt 選択を中心機能にしています。

## テスト

```sh
nvim --headless -i NONE -u tests/minimal_init.lua -l tests/run.lua
```
