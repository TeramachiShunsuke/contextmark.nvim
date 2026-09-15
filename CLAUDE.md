# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

Markdown の選択範囲に、本文を変更せず Note を付ける Neovim プラグイン。Note はリポジトリ外の
sidecar JSON に保存し、Orca 互換の prompt として AI agent へ送る。Neovim 0.11+ / Lua。

## コマンド

```sh
# テスト（必ずリポジトリルートから実行。minimal_init が cwd を runtimepath に prepend する）
nvim --headless -i NONE -u tests/minimal_init.lua -l tests/run.lua

# フォーマット
stylua .
stylua --check .
```

テストは `tests/run.lua` 内の `test(name, callback)` を登録順に全件実行する単一ファイル方式で、
フィルタ機構はない。1件だけ動かしたい場合は末尾のループを一時的に絞る。失敗時は `vim.cmd.cquit`
で非0終了するので CI がそのまま検知する。

CI は `.github/workflows/ci.yml`（Neovim v0.11.0 / stable / nightly + stylua）。

## アーキテクチャ

データの流れは一方向:

```
selection.current()  →  anchor.capture()  →  store（sidecar JSON）
                                                  ↓
                                            render（extmark 描画）
                                                  ↓
                                   prompt.build()  →  delivery.send()  →  adapter / clipboard
```

`init.lua` がこれらを束ねる唯一の場所で、各モジュールは互いを直接呼ばない（`render` → `anchor`/`store`
の依存を除く）。

### 位置情報の二重管理（最重要）

同じ Note の位置が2か所にある。

- **sidecar JSON の `anchor`** — ディスク上の真実。ファイルを開いていないときの位置
- **buffer の extmark** — buffer が開いている間の真実。編集に追従する

この2つを橋渡しするのが `render.lua` の2関数:

- `render.render(bufnr)` — ファイル本文から `anchor.resolve()` で位置を再計算し、extmark を張り直す。
  解決結果が保存値とずれていたら sidecar を更新する
- `render.sync(bufnr)` — extmark の現在位置を読み、`anchor.capture()` し直して sidecar へ書き戻す

**位置を参照する処理は必ず先に `render.sync_all()` を呼ぶこと。** `init.lua` の `comments_for()` と
`list()` がそうしている。忘れると編集中の buffer の Note が古い行番号で出力される。

### アンカー解決の優先順位（`anchor.lua`）

`M.resolve()` は次の順で位置を決め、`status` を返す。

1. 保存された行・列で excerpt が一致 → `exact`
2. ファイル全体から excerpt を検索し、前後文脈（`before`/`after`）と行内の `prefix`/`suffix` で
   スコア付け、同点タイが無ければ最上位を採用 → `moved`
3. 決められない → 元の行に留めて `stale`
4. ファイルが空 → `orphaned`

`stale` / `orphaned` は表示上「警告色」として同じ扱いになる（`render.lua` の `stale` 変数）。

### 列はバイトオフセット

`start_col` / `end_col` は **0-based バイト、end-exclusive**。文字数ではない。
`selection.lua` は inclusive な Visual 選択をバイト end-exclusive へ変換する際、
`end_of_character()` で末尾文字のバイト長ぶん伸ばしている。マルチバイト（日本語）の
テストがあるので、この変換を触るときは必ず確認する。

Linewise Visual (`V`) と blockwise (`<C-v>`) は `kind = "line"` に落とし、列を行全体へ広げる。
通常の Visual (`v`) のみ `kind = "char"`。

### 保存先

`stdpath("state")/contextmark/<プロジェクト名>-<root の SHA-256 先頭16桁>.json`。
プロジェクトルートは `vim.fs.root(path, { ".git" })`。

リポジトリ内にファイルを作らないのが設計上の要件（Note 追加で Git diff を出さない）。
保存先をリポジトリ配下へ移す変更は、この前提を崩すので慎重に。

`store.lua` は root ごとに state をメモリキャッシュする。テストや複数 root をまたぐ処理では
`store.reset_cache()` が必要。書き込みは temp ファイル + `os.rename` の atomic replace。

### Prompt 形式は外部契約

`prompt.build()` の出力は Orca の形式に合わせた契約で、テストが文字列一致で検証している。

```text
File: <相対パス>
Source: <markdown | filetype>

Lines 29-32
Excerpt:
> 引用行
User comment: "JSON 文字列化した本文"
```

- 1行なら `Line N`、複数行なら `Lines N-M`（`util.range_label()`）
- 空行の引用は `> ` ではなく `>` 単体
- 本文は `vim.json.encode()` で囲む（改行が `\n` になる）
- 同一ファイルの Note は `File`/`Source` を繰り返さず、空行区切りで連結する

Excerpt は保存値ではなく **その時点のファイル本文から再抽出する**（`comment_excerpt()`）。
読めない場合のみ保存済み excerpt にフォールバックする。

### Delivery（`delivery.lua`）

core は agent を知らない。prompt 文字列を作り、router に渡すところまでが責務。

mode は `auto` / `direct` / `clipboard` / `both`。`auto` は direct 成功なら direct のみ、
失敗時に clipboard へ退避する。clipboard は system clipboard が無い headless/SSH 環境で
unnamed register (`"`) へ二段フォールバックする。

adapter の契約:

- `is_available() -> boolean, reason?`
- `send(text, comments, opts) -> ?`
  - 失敗: `false, reason` または `{ accepted = false, reason = "..." }`
  - 成功: 戻り値なし / `true` / `{ accepted = true }`

adapter 呼び出しは全て `pcall` で包み、例外も失敗理由として扱う。新しい adapter は
`lua/contextmark/adapters/<name>.lua` に置けば `delivery.direct.adapter = "<name>"` で解決される
（`auto` が自動検出するのは `sidekick` のみ）。

adapter へは prompt を **原文のまま**渡す。Sidekick の context template を通すと Note 内の
`{selection}` などが展開されてしまうため、`sidekick.lua` は行ごとの text 構造へ変換して渡している。

### 混雑した行の描画（`render.lua`）

同じ開始行に複数の Note がある場合、sign と行末 virtual text は先頭1件（`primary`）にだけ付け、
`󰍩 N notes` に集約する。個々の Note は範囲ハイライト用 extmark を必ず張る（アンカー追従のため）。
全文は `ui.hover()` の float で見せる。

### 起動経路

`plugin/contextmark.lua` は `vim.g.loaded_contextmark` ガード付きでコマンドだけを定義し、
実装は遅延 `require` する。highlight / autocmd / buffer-local keymap は
`require("contextmark").setup()` が張る。コマンドは setup なしでも動くが、描画は走らない。

## 変更時の注意

- 新しいモジュールは `init.lua` から呼ぶ。モジュール間の相互 require を増やさない
- `anchor` / `prompt` / `delivery` を変えたら必ずテストを流す。この3つに既存テストが集中している
- sidecar の JSON スキーマを変える場合は `store.lua` の `version = 1` と読み込み時の
  バージョンチェックを更新する（現在は version 不一致なら空 state として無視する）
