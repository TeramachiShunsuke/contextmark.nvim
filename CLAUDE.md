# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

選択範囲に、本文を変更せず Note を付ける Neovim プラグイン。Note はリポジトリ外の
sidecar JSON に保存し、Orca 互換の prompt として AI agent へ送る。Neovim 0.11+ / Lua。

既定の対象は Markdown だが、選択・アンカー・描画・保存に Markdown 固有の処理は無い。
唯一の例外は `prompt.lua` の `source_name()` で、filetype が `markdown` / `markdown.mdx`
またはファイル名が `.md` / `.mdx` の Note を `Source: markdown` に揃える。対象は
`config.filetypes` だけで決まり、完全一致 / glob / 述語関数を受け付ける
（`util.is_filetype_allowed()`）。filetype 判定を追加する場合はこの関数を通すこと。
autocmd 側で `pattern` による絞り込みをしてはいけない（glob と関数で挙動が分かれるため、
`FileType` autocmd も `pattern = "*"` + `is_filetype_allowed()` で揃えてある）。

## コマンド

```sh
# テスト（必ずリポジトリルートから実行。minimal_init が cwd を runtimepath に prepend する）
nvim --headless -i NONE -u tests/minimal_init.lua -l tests/run.lua

# フォーマット
stylua .
stylua --check .

# テストが本当に対策を守っているかの確認（対策を1つずつ戻して赤くなるか見る）
python3 tests/mutation_check.py
```

`tests/mutation_check.py` は `$TMPDIR` に使い捨てコピーを作って各対策を1つずつ元に戻し、
どのテストが捕まえるかを表示する。`SURVIVED` が出たテストは何も守っていない。
同一性・アンカー・sync ガードを変えたら必ず流す（対策のパターン文字列を直書きしているので、
整形でずれたら `SKIP` と出る。その場合はパターンを現在のコードに合わせて更新する）。

テストは `tests/run.lua` 内の `test(name, callback)` を登録順に全件実行する単一ファイル方式で、
フィルタ機構はない。1件だけ動かしたい場合は末尾のループを一時的に絞る。失敗時は `vim.cmd.cquit`
で非0終了するので CI がそのまま検知する。

CI は `.github/workflows/ci.yml`（Neovim v0.11.0 / stable / nightly + stylua）。

## アーキテクチャ

データの流れは一方向:

```
selection.current()  →  anchor.capture()  →  store（sidecar JSON）
                                                  ↓
                            render（identity.compare で同一性判定 → extmark 描画）
                                                  ↓
                                   prompt.build()  →  delivery.send()  →  adapter / clipboard
```

`init.lua` がこれらを束ねる唯一の場所で、各モジュールは互いを直接呼ばない（`render` →
`anchor`/`identity`/`store` の依存を除く）。`util.lua` と `identity.lua` は他モジュールを
require しない葉。

### ファイルとの紐付け（最重要）

Note とファイルの対応は `comment.file`（root 相対パス）の文字列一致だけで決まる
（`store.lua` の `comment.file == relative_file`）。パスは同一性の**名前**にすぎないので、
「そのパスにあるファイルが本当にこの Note のファイルか」は別に判定する必要がある。

キーを決める唯一の入口が `util.buffer_context(bufnr)`。ここで弾かれた buffer は Note を
持てない。**Note の位置やキーを扱う処理は必ずこれを通すこと。**

- `buftype ~= ""` を拒否（`nofile` / `help` など）
- `oil://` `fugitive://` `term://` のような scheme 付き buffer 名を拒否
- root 外のパスを拒否（`relative_path` が nil を返す）。**basename へのフォールバックを
  復活させてはいけない** — 無関係な同名ファイルがキーを共有する
- パスは `normalize()` で symlink 解決済み。ただし root は未解決パスから `vim.fs.root()` で
  決める（解決を先にすると repo 外を指す symlink が別プロジェクトの sidecar に入る）
- `.git` が無ければファイル自身のディレクトリを root にする（cwd 依存を作らない）

### 位置情報の三重管理

同じ Note の位置と同一性が3か所にある。

- **sidecar JSON の `anchor`** — ディスク上の真実。ファイルを開いていないときの位置
- **buffer の extmark** — buffer が開いている間の真実。編集に追従する
- **sidecar JSON の `files[relative]`** — ファイル内容の指紋。「このパスのファイルが
  Note を書いた対象のままか」の判断材料（`identity.lua`）

橋渡しするのが `render.lua` の2関数:

- `render.render(bufnr)` — `identity.compare()` でファイル同一性を1回判定し、`anchor.resolve()` で
  位置を再計算して extmark を張り直す。差し替わっていれば status を `mismatch` に上書きし、
  **指紋は更新しない**（更新すると元ファイルが戻ったときに復帰できなくなる）
- `render.sync(bufnr)` — extmark の現在位置を読み、`anchor.capture()` し直して sidecar へ書き戻す

**位置を参照する処理は必ず先に `render.sync_all()` を呼ぶこと。** `init.lua` の `comments_for()` と
`list()` がそうしている。忘れると編集中の buffer の Note が古い行番号で出力される。

### sync の証跡保護（壊してはいけない不変条件）

`render.sync` は `comment.anchor` を丸ごと差し替えるので、無条件に走らせると保存済みの
`excerpt` / `before` / `after` が現在のファイル本文で上書きされ、`status` も `exact` に戻る。
誤アタッチした Note がこれを受けると、**元の本文が復元不能に失われたうえ健全に見える**。

そのため次のどちらかなら位置だけ追従し、証跡は温存する。

1. ファイル同一性が `replaced`（Note の status に依らない。健全に見える Note も守る）
2. extmark の範囲が消滅した（対象行が削除され、抽出結果が空白のみ）

**1 を「status が warning なら」に置き換えてはいけない。** status はヒューリスティックの結果で、
判定を外した瞬間にガードごと迂回される。

**逆に、`stale` だけを理由に凍結してもいけない。** Note を付けた文を書き直すのはこのプラグインの
中心的な用途で、そこで凍結すると Note は編集に追従せず、しかも「保存までに render が挟まったか」で
結果が変わる非決定性が出る。`stale` は recapture して追従させる。

位置の代入は `anchor.capture` と同じ規則で clamp する（extmark は buffer 末尾の1行先を返す）。

**`replaced` の間は座標を書き戻さない**（`render.render`）。status は毎回更新するが、座標を
更新すると prompt が「引用は元ファイル、行番号は別ファイル」という混ざったブロックを出し、
Note が元々どこにあったかの記録も消える。凍結中の span は保存済み excerpt の行数から復元する
（extmark の範囲をそのまま使うと、buffer 全体を差し替えた後に1行の excerpt に対して
`Lines 1-61` のような矛盾した範囲が固定される）。

**識別の基準はディスク上の本文からしか採らない**（`vim.bo[bufnr].modified` を見る）。未保存の
下書きを基準にすると、下書きを捨てた瞬間に無変更のファイルが自分自身と一致しなくなる。
指紋が無くかつ既に警告状態の Note がある場合も基準を採らない（どちらのファイルが正しいか
判断材料が無いため、先に開いた方が正解として固定されてしまう）。

### アンカー解決の優先順位（`anchor.lua`）

`M.resolve()` は次の順で位置を決め、`status` を返す。ファイル同一性は見ない（見られない）。

1. 保存された行・列で excerpt が一致 → `exact`
2. ファイル全体から excerpt を検索し、前後文脈（`before`/`after`）と行内の `prefix`/`suffix` で
   スコア付け、同点タイが無ければ最上位を採用 → `moved`
3. 決められない → 元の行に留めて `stale`
4. ファイルが空（`{}` または `{""}`）→ `orphaned`。**非 nil の `start_line` を返すこと** —
   nil を返すと `render.lua` の `if start_line then` で捨てられ、Note が黙って消える

`mismatch` は `anchor.resolve` からは返らない。`render.lua` が `identity.compare` の結果で
上書きする。`stale` / `orphaned` / `mismatch` は警告扱いだが、`mismatch` だけ別の sign と
highlight を持つ（`render.lua` の `severity_of`）。

Note 単位の前後文脈でファイルの差し替えを判定しようとしないこと。空行は無関係な文書でも
一致し、`## 概要` のような定型行も同じで、閾値を緩めれば同一ファイルの見出し改名で誤検知する。
判定は `identity.lua` のファイル単位の指紋で行う。

### ファイル同一性（`identity.lua`）

`M.fingerprint(lines)` は全体のハッシュ、行数、空行を除いた**重複しない**行から最大32件の
サンプル（各行のハッシュ）を返す。`M.compare(stored, lines)` は `same` / `replaced` / `unknown`。

- ハッシュ一致 → `same`（変更なしの最頻ケースを最短で抜ける）
- サンプルの1割以上が残っている → `same`（編集された同じファイル）
- 1割未満 → `replaced`
- サンプルが10件未満 → `unknown`（比率が意味を持たない。短い文書は見出し1行を共有するだけで
  似てしまうので、告発も保証もしない。`:ContextMarkRelocate` が短いファイル同士を総当たりで
  移動先候補に出していたのはこれが原因）
- サンプルが無い（指紋未記録・空行だけのファイル）→ `unknown`。**`replaced` として扱わない**

`unknown` は指紋導入前の Note が必ず通る経路なので、ここで警告してはいけない。

**2つの誤りのコストは対称ではない。** 見逃した差し替えは excerpt が一致しなくなることで後から
気づけるが、誤検知はユーザーが普通に書き直しているファイルの Note を全部警告色にする。
だから閾値は保守側（9割以上が入れ替わったときだけ）に置く。同じ理由で:

- 行は前後の空白を無視して比較する（`canonical`）。保存時の行末空白除去や一括インデントは、
  1文字も内容を変えずに全行を書き換えるため、素の比較では必ず誤検知する
- サンプルは重複を除く。表やコマンド一覧のような反復構造のファイルは、同じ行の digest で
  サンプルが埋まり、その1行を含む無関係なファイルと一致してしまう
- サンプルは位置で等間隔に配る。`floor` した歩幅で先頭から拾うと、有意行 33〜63 の文書
  （最も普通のサイズ）でサンプルが先頭32行で尽き、導入部の書き直しが `replaced` になり、
  逆にライセンスヘッダを共有する別文書が `same` になる

テストの fixture は必ず**現実的な長さの文書**にする。4行の fixture は攻撃的な閾値しか固定できず、
日常編集の誤検知を直そうとすると逆にテストが邪魔をする。さらにサンプルが10件未満だと判定自体が
`unknown` になり、その分岐を通らない。`tests/run.lua` の `document()` を使う。

判定は buffer 変更（`changedtick`）ごとに1回だけ計算してメモ化する（`render.lua` の
`file_verdict`）。`:w` は sync と render の両方を走らせ、`BufEnter` でも render が走るので、
素朴に呼ぶと1回の操作で文書全体を何度もハッシュする。

### 列はバイトオフセット

`start_col` / `end_col` は **0-based バイト、end-exclusive**。文字数ではない。
`selection.lua` は inclusive な Visual 選択をバイト end-exclusive へ変換する際、
`end_of_character()` で末尾文字のバイト長ぶん伸ばしている。マルチバイト（日本語）の
テストがあるので、この変換を触るときは必ず確認する。

Linewise Visual (`V`) と blockwise (`<C-v>`) は `kind = "line"` に落とし、列を行全体へ広げる。
通常の Visual (`v`) のみ `kind = "char"`。

### 保存先

`stdpath("state")/contextmark/<プロジェクト名>-<root の SHA-256 先頭16桁>.json`。
プロジェクトルートは `vim.fs.root(path, { ".git" })`、見つからなければファイル自身のディレクトリ。

`util.lua` の `normalize()` は `vim.uv.fs_realpath()` でシンボリックリンクを解決する。
これがないと `/tmp/x` と `/private/tmp/x` が別プロジェクト扱いになり、sidecar が分裂する。
存在しないパス（未保存の新規ファイルなど）では `fs_realpath` が nil を返すので、存在する
一番近い親ディレクトリを realpath 化し、残りのパス要素をつなげる。こうしないと
`link/sub/new.md` の相対パスが `new.md` に潰れる。

root を canonical 化する前の sidecar は、symlink 経由の root 表記のハッシュで保存されている。
`store.lua` の `load()` は root を初めて読むとき保存先の `*.json` を走査し、記録された
`root` を realpath 化すると現在の root になるものを id 重複を除いて統合する。統合後は
canonical 側へ保存し、旧ファイルは `.migrated` に rename して残す（削除はしない）。

リポジトリ内にファイルを作らないのが設計上の要件（Note 追加で Git diff を出さない）。
保存先をリポジトリ配下へ移す変更は、この前提を崩すので慎重に。

ファイル名が root 文字列のハッシュなので、**root の決め方を変えると既存 Note が全部参照不能になる**。
sidecar は `state.root` を持っているので、`store.adoptable(root)` が孤立した sidecar を見つけ、
`:ContextMarkAdopt`（`init.lua` の `M.adopt`）が取り込む。候補にする条件は「記録 root が消えている」
「現 root と親子関係にある」「**記録された `file` が現 root に実在する**」のいずれか。3つ目が無いと、
README が案内している「cwd 由来 root からファイル自身のディレクトリへ」という移行ケースが
候補0件になる。root の導出を変える変更は、この移行経路と README の破壊的変更の記述を
必ずセットで更新すること。

**読めない sidecar は絶対に上書きしない。** `read_state_file` は「無い」と「読めない」を
区別し、読めないとき（JSON 壊れ・未知 version）は `M.save` が理由付きで失敗を返す。
ここを区別しないと、切り詰められた sidecar が「空のプロジェクト」として読まれ、次の1回の保存で
全 Note が消える。`file:write` / `file:close` の戻り値も必ず検査する（ディスク満杯は open では
なく write で失敗するので、捨てると「成功」と報告しながら中身を壊す）。anchor が壊れた Note は
捨てずに最小の anchor を与えて残す（本文はユーザーが書いたものなので失わせない）。

`store.lua` は root ごとに state をメモリキャッシュするが、`load()` は sidecar の
size + mtime を毎回照合し、他の Neovim が書き換えていれば読み直す。未保存のローカル編集が
あるとき（`pending`）は読み直さず、`save()` が disk の内容を merge する。**この3つが無いと
nvim を2窓開いているだけで片方の Note が消える。** `remove()` した id はセッション中
tombstone として記録し、merge や読み直しで復活させない。

3つ目は `save()` の排他ロック（`<sidecar>.lock` を `fs_open(..., "wx")` で取る）。atomic rename が
守るのは「読み手が半端なファイルを見ない」ことだけで、2つのインスタンスがそれぞれ
read → merge → write を走らせると後の rename が先の結果を捨てる。ロックが取れなければ
**黙って上書きせず失敗を返す**。5秒より古いロックはクラッシュの置き土産として奪う。

`pending` は**変更が実際に入ったときだけ**立てる。`update()` / `remove()` が
「comment not found」で早期 return する経路で立てていると、そのインスタンスは以後
sidecar を一切読み直さず、次の保存で他インスタンスの変更を巻き戻す。

書き込みは temp ファイル + `os.rename` の atomic replace。テストや複数 root をまたぐ処理では
`store.reset_cache()` が必要（キャッシュ・stamp・pending・tombstone をまとめて捨てる）。

sidecar のトップレベルは `version` / `root` / `comments` / `files`。`files` は追加専用フィールドで、
`load()` が未知キーをそのまま往復させるので `version = 1` のままでよい。

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

ただし status が warning のときは例外で、**保存済みの excerpt を使い**、範囲ラベルの直後に
`Status: ...` の1行（`util.status_note()`）を挿入する。誤アタッチした Note を無印で agent に
渡すと、別ファイルの行を「ユーザーが選んだ範囲」として扱われるため。健全な Note の出力は
1バイトも変えない（既存の文字列一致テストがそれを固定している）。

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

リネーム追従（`BufFilePre` / `BufFilePost`）も `setup()` が張る autocmd。`:saveas` は2つの
buffer 分イベントが飛ぶので、記録は必ず `event.buf` でキーを付ける。そして **旧パスがまだ
存在するなら Note を動かしてはいけない** — `:saveas` と `:file` はコピー・改名であって
元ファイルは残り、その Note は元ファイルのものだから。LSP のリネームは書き込み後に旧ファイルを
削除するので、判定は `BufWritePost` と `BufEnter` でも再試行する（`settle_rename`）。

移動先が既に Note か指紋を持っているときは自動で動かさず通知に留める。名前の変更は
「その buffer が誰の本文を持っているか」を教えてくれないので、2つのファイルの Note を
黙って混ぜるより放置するほうがまだ良い。

再試行する以上、**リネームの意図には寿命が必要**（`rename_ttl_ns`、60秒）。`:file` が正しく
何もしなかった記録が残り続けると、数時間後の無関係な削除で「リネームがやっと完了した」と
誤読して、別ファイルの Note を巻き込んで動かす。あわせて、追従の前に buffer の内容が旧パスの
指紋と一致することを確認する（`identity.compare ~= "replaced"`）。

## 変更時の注意

- 新しいモジュールは `init.lua` から呼ぶ。モジュール間の相互 require を増やさない
- `anchor` / `identity` / `prompt` / `delivery` を変えたら必ずテストを流す。テストはここに集中している
- 同一性・アンカー・sync ガードを変えたら `python3 tests/mutation_check.py` も流す。
  テストが緑でも対策が死んでいることがある
- sidecar の JSON スキーマを変える場合は `store.lua` の `version = 1` と読み込み時の
  バージョンチェックを更新する（現在は version 不一致なら空 state として無視する）。
  追加専用フィールドなら version は据え置ける
- 判定を足すときは「警告が出る誤検知」と「サイレントな誤アタッチ」を同じ重さで扱わない。
  後者だけが証跡を失わせる。迷ったら警告側に倒す
