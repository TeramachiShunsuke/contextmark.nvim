# Copilot review instructions

contextmark.nvim は Markdown の選択範囲に Note を付ける Neovim プラグイン（Lua / Neovim 0.11+）。
Note はリポジトリ外の sidecar JSON に保存し、Orca 互換の prompt として AI agent へ送る。

レビューでは以下を優先して確認してほしい。一般的なコーディング規約の指摘より、
このリポジトリ固有の不変条件が壊れていないかを重視する。

## 1. 列はバイトオフセット、文字数ではない

`anchor` の `start_col` / `end_col` は **0-based バイト、end-exclusive**。

- `string.sub` / `#` によるバイト演算と、`vim.fn.strchars` / `vim.fn.strcharpart` による
  文字演算が混在していないか
- 列を扱う新しいコードが、日本語などマルチバイト文字で破綻しないか
- `selection.lua` は inclusive な Visual 選択を end-exclusive バイトへ変換している。
  この変換（`end_of_character()`）を触る変更は特に慎重に見る

## 2. 位置を参照する前に `render.sync_all()` を呼ぶ

Note の位置は2か所にある。

- sidecar JSON の `anchor` — ディスク上の真実
- buffer の extmark — buffer が開いている間の真実（編集に追従する）

buffer を開いたまま prompt 生成や一覧表示を行う処理は、**先に `render.sync_all()` で
extmark の位置を sidecar へ書き戻す必要がある**。呼び忘れると古い行番号が出力される。
`init.lua` の `comments_for()` / `list()` が既存の呼び出し箇所。

`render.render()`（本文から再解決して extmark を張り直す）と
`render.sync()`（extmark から sidecar へ書き戻す）の向きを取り違えていないかも確認する。

## 3. prompt 形式は外部契約

`prompt.build()` の出力は Orca 側と合わせた契約で、`tests/run.lua` が文字列一致で検証している。

- 1行は `Line N`、複数行は `Lines N-M`
- 引用は `> ` 前置。空行だけは `>` 単体
- 本文は `vim.json.encode()` で囲む（改行が `\n` になる）
- 同一ファイルの Note は `File` / `Source` を繰り返さない

空白1つ・改行1つの違いでも契約違反になる。整形の「改善」提案はしない。

## 4. 既定の保存先はリポジトリ外

既定の保存先は `stdpath("state")/contextmark/<name>-<root の SHA-256 先頭16桁>.json`。
**既定設定のままなら Note を追加しても Git diff が出ないこと**が設計要件。

ユーザーが `storage.dir` を明示指定してリポジトリ配下へ置くのは正当な設定であり、
これ自体は指摘しなくてよい。指摘すべきなのは、既定値そのものをリポジトリ配下へ変える、
`storage.dir` の有無にかかわらずリポジトリ内へ書き込む、といった変更。

書き込みは temp ファイル + `os.rename` の atomic replace。これを直接書き込みに変える変更も指摘する。

`store.lua` は root ごとに state をメモリキャッシュする。複数 root をまたぐ処理や
テストで `store.reset_cache()` が必要ないか確認する。

## 5. delivery は agent を知らない

core の責務は prompt 文字列を作って router に渡すまで。agent 固有の**処理**は
`lua/contextmark/adapters/<name>.lua` に閉じ、`delivery.lua` へ持ち込まない。

`delivery.lua` の `resolve_direct()` が `adapter = "auto"` の候補として adapter 名
（現状 `"sidekick"`）を列挙しているのは既存の設計どおりで、これ自体は指摘しない。
指摘すべきなのは、agent の API 呼び出し・引数整形・可用性判定といった実処理が
`delivery.lua` 側へ漏れる変更。

adapter の契約:

- `is_available() -> boolean, reason?`
- `send(text, comments, opts)` — 失敗は `false, reason` または `{ accepted = false, reason }`、
  成功は 戻り値なし / `true` / `{ accepted = true }`

adapter 呼び出しは全て `pcall` で包む。例外が握り潰されず失敗理由として扱われているか確認する。

**ユーザーが指定していない外部 destination へ prompt を送る変更は必ず指摘する。**
adapter へは prompt を原文のまま渡す（context template を通すと Note 内の `{selection}` などが
展開されてしまう）。

## 6. アンカー解決の劣化

`anchor.resolve()` は exact → context スコアによる候補選択 → stale の順に解決し、
`exact` / `moved` / `stale` / `orphaned` の status を返す。スコアリングや同点判定を変える場合、
誤った位置へ確信をもって解決してしまう（本来 `stale` にすべきものを `moved` と誤判定する）
リスクがないか見る。曖昧なら `stale` に倒すのが正しい。

## 7. モジュール構成

core モジュールの `require` は一方向の DAG になっている。

```
init  → anchor, config, delivery, prompt, render, selection, store, ui, util
render → anchor, config, store, util
prompt → anchor, util
ui     → config, util
store  → config
delivery → config
anchor / selection / util → 依存なし
```

**循環 require を作らないこと**が不変条件。上位（`init` / `render`）が下位を呼ぶのは正常で、
下位が上位を呼び返す変更を指摘する。

adapter は `delivery.lua` が実行時に `require("contextmark.adapters." .. name)` で解決するため、
`lua/contextmark/adapters/` への追加は `init.lua` を変更せずに行ってよい。

## 指摘しなくてよいこと

- stylua のフォーマット（CI の `stylua --check` が担保する）
- 変数名を短くする / 早期 return にするといった好みの差
- `vim.api` の呼び出しを別の等価な API に置き換える提案
