# Design notes

調査日: 2026-09-15

## 結論

近い Neovim プラグインは存在するが、次の4条件をすべて満たすものは確認できなかった。

1. 任意の Markdown 本文・行範囲への Note
2. 本文を変更しない sidecar 保存
3. 全件だけでなく任意の複数 Note を選べる
4. Orca 互換の `File / Source / Lines / Excerpt / User comment` prompt

## 既存候補

| Plugin | 良い点 | 今回の不足 |
| --- | --- | --- |
| [DaniilSinitsyn/annotate.nvim](https://github.com/DaniilSinitsyn/annotate.nvim) | diff 非依存、Visual 範囲、JSON sidecar、Agent 用 export | export は全件のみ。Orca 形式ではなく excerpt も含まない。永続位置は行番号中心 |
| [TheNoeTrevino/haunt.nvim](https://github.com/TheNoeTrevino/haunt.nvim) | リポジトリ外 JSON、extmark、picker、buffer/all の clipboard、Sidekick 連携、テストが豊富 | Note は現在行単位。任意範囲と任意複数選択、Orca prompt がない |
| [rsmenon/inline-review.nvim](https://github.com/rsmenon/inline-review.nvim) | Markdown/Text の範囲コメント UI が近い | Roughdraft markup を本文へ保存するため Git diff が発生する |
| [vuki656/review.nvim](https://github.com/vuki656/review.nvim) | 複数コメントと Agent への Markdown export | Git diff review が前提で通常の Markdown Note ではない |
| [georgeguimaraes/review.nvim](https://github.com/georgeguimaraes/review.nvim) | AI-ready Markdown export | codediff.nvim の review annotation が前提 |
| [Sahas-Ananth/code_annotate.nvim](https://github.com/Sahas-Ananth/code_annotate.nvim) | SQLite と extmark で本文を汚さない | Agent prompt の部分選択フローがない |

`annotate.nvim` を小さく拡張する案もあるが、公開 API の安定性・テスト・部分選択 UI
が不足している。`haunt.nvim` は基盤として成熟しているものの、そのデータモデルは
bookmark（1行）であり、Markdown の行範囲を第一級にすると変更が広い。このため、
MVP は独立実装とする。

## データモデル

sidecar はプロジェクトごとに1ファイルとする。

```json
{
  "version": 1,
  "root": "/absolute/project/root",
  "comments": [
    {
      "id": "cm-0123456789abcdef",
      "file": "docs/example.md",
      "filetype": "markdown",
      "body": "User comment",
      "created_at": "2026-09-15T06:00:00Z",
      "updated_at": "2026-09-15T06:00:00Z",
      "anchor": {
        "start_line": 29,
        "end_line": 32,
        "excerpt": ["selected text"],
        "before": ["context before"],
        "after": ["context after"],
        "status": "exact"
      }
    }
  ],
  "files": {
    "docs/example.md": {
      "digest": "<内容全体のハッシュ>",
      "lines": 120,
      "significant": 96,
      "sample": ["<空行を除いた重複しない行のハッシュ最大32件>"]
    }
  }
}
```

`files` は Note を持つファイルごとの内容の指紋で、追加専用フィールドのため `version` は
1 のまま。パスは同一性の名前にすぎず、「そのパスにあるファイルが Note を書いた対象のままか」を
パスからは判定できないため、これを別に記録する。Note 単位の前後文脈では判定できない
（空行や定型行は無関係な文書にも一致し、閾値を緩めれば同一ファイルの見出し改名で誤検知する）。

行番号に加えて0-based byte列の `start_col` / `end_col`（end-exclusive）を保存する。
通常のVisual選択では選択文字列だけを `excerpt` とし、Linewise Visualでは行全体を
保存する。これにより位置表示はOrcaと同じ行単位のまま、Excerptは人が選んだ範囲に
限定できる。

## 保存場所

既定値は `stdpath("state")/contextmark/<project>-<hash>.json`。

- Markdown と Git index を汚さない
- `.gitignore` の追加すら不要
- プロジェクト名が同じでも絶対パス hash で衝突しない

チーム共有は別要件とし、将来 `storage.dir` をプロジェクト配下へ明示設定できる。

ファイル名が root 絶対パスの hash である代償として、プロジェクトを移動・改名すると既存の
sidecar が参照されなくなる。sidecar 自身が `root` を保持しているので、storage ディレクトリを
走査すれば孤立した sidecar を特定でき、`:ContextMarkAdopt` で取り込める。削除はしない
（取り込みは加算のみで、やり直しも手作業の復元もできる）。

プロジェクトルートは `.git` を上方探索し、見つからなければ**ファイル自身のディレクトリ**とする。
cwd フォールバックは `:cd` で紐付けが変わり、cwd 外のファイルが同名ファイルとキーを共有する
ため採らない。

## Prompt delivery

core は prompt 文字列を生成し、delivery routerへ渡すところまでを責務とする。
Agent への直接送信は `delivery.direct.send(text, comments)` に委譲する。

これにより Sidekick、CodeCompanion、Claude Code、Codex、tmux などの違いを core
へ持ち込まず、ユーザーが指定していない外部 destination へ誤送信しない。

delivery modeは次の4つ。

- `auto`: direct成功時はdirectのみ。利用不能・失敗時はclipboard
- `direct`: directを試す。既定では失敗時にclipboard fallback
- `clipboard`: directを呼ばずclipboardのみ
- `both`: directの成否にかかわらずclipboardにも保存

system clipboardがないheadless/SSH環境では、最後の退避先としてNeovimの unnamed
registerを使う。これも失敗した場合だけ、promptを未配信としてエラーにする。

最初の同梱adapterは、LazyVimでも導入しやすい `sidekick.nvim` とする。Sidekickの
`cli.send({ text = ... })` を利用し、context templateを通さず原文を渡す。既定の
`submit = false` により、Agentへ送信確定する前に人がpromptを確認できる。

## MVP 後の候補

- resolved/open state と resolved Note の表示切替
- 選択列を含むアンカー
- fuzzy matcher（本文そのものが編集された場合）
- Snacks picker adapter
- Agent ごとの公式 delivery adapter
- Note thread / reply

リネーム検出は Git ではなく内容の指紋で実装した（`identity.lua` / `:ContextMarkRelocate`）。
未コミットの本文への Note が主要ユースケースなので blob oid が存在しないのが普通であり、
素の `mv` はステージ前には `R` として現れず、`.git` の無いツリーも対象に含むため。
`git ls-files` で走査対象を絞る程度の最適化なら将来の候補。

## 混雑した行の表示

同じ開始行に複数の Note がある場合、行末 virtual text と sign は1件に集約する。
個々の extmark はアンカー追従のため維持し、表示だけを `󰍩 N notes` にまとめる。
カーソル停止時または `:ContextMarkShow` で、その行に属する全 Note を折り返し付きの
floatへ表示する。stale範囲は警告色で示し、取り消し線は使わない。
