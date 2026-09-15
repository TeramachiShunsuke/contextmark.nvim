# contextmark.nvim feedback sandbox

この文書は、行Noteとprompt生成を試すためのサンプルです。
本文を編集しても、Note自体はこのMarkdownへ書き込まれません。

## Storage

Noteはリポジトリ外のsidecar JSONへ保存されます。
そのため、Noteを追加してもこのファイルのGit diffは変わりません。

## Anchoring

Visual modeでこの段落を選択し、Noteを追加してみてください。
選択範囲の前へ新しい行を挿入して保存しても、Noteは本文を使って追従します。

## Prompt delivery

一件、現在ファイル全件、プロジェクト全件、チェックUIで選んだ一部をprompt化できます。
Sidekickが使える場合はAgent欄へ直接入力し、使えなければclipboardへ退避します。

## Feedback points

- Note入力windowの大きさと操作感
- 行末virtual textと範囲highlightの見やすさ
- Note選択UIの分かりやすさ
- Orca形式promptの過不足
- キーマップの覚えやすさ
