# Phase 1 試用ランブック（組む・ほぼ作らない）

期間の目安: **1週間**。ゴールは「常用できるか」と「Linear 貼り付けが痛いか」の記録。  
作成（Phase 2 glue）は、このログを見てから決める。

全体図: [target-shape.md](target-shape.md)

## この Phase で入れるもの

| 部品 | 入れ方 | 役割 |
| --- | --- | --- |
| render-markdown + snacks.image | `lang.markdown` + `snacks-image.lua` | 読む |
| contextmark | 本体プラグイン | Note → Orca prompt |
| sidekick | `ai.sidekick` extra | 単発 agent CLI |
| octo | `util.octo` + `editor.snacks_picker` | GitHub Issue/PR |
| hangar | `hangar.lua` | 並列 worktree（本 Phase の選択） |
| Linear | **ブラウザのまま** | 手数計測のみ |

workmux は使わない（hangar を1本に絞る）。

## Cloud デモ機での有効化（済／このランブック適用時）

```bash
# plugins already under ~/.config/nvim/lua/plugins/
# extras imported from lua/config/lazy.lua
nvim  # :Lazy sync if needed
```

手元 LazyVim なら:

1. `:LazyExtras` → `lang.markdown` / `editor.snacks_picker` / `util.octo` / `ai.sidekick`
2. `contrib/lazyvim-eval/` の `snacks-image.lua` `hangar.lua` `contextmark` 設定をコピー
3. agent CLI（`claude` 推奨）を PATH に

## 毎日の触り方（チェック）

### A. 文書フィードバック（本線）

- [ ] Markdown を読んで render が邪魔にならない
- [ ] Note を付けて `:ContextMarkSend` / `<leader>mp*` で Sidekick か clipboard に届く
- [ ] Sidekick CLI（`<leader>aa` など）が開ける（CLI が無ければ「未導入」と記す）

### B. GitHub（octo）

- [ ] `<leader>gp` で PR 一覧が出る
- [ ] 1件開けて diff / comment まで触れる
- [ ] 「ブラウザの方が速い」と感じたらその旨をメモ（採用見送り可）

### C. 並列（hangar）

- [ ] `:Hangar` ダッシュボードが開く
- [ ] `:Hangar spawn --safe <短いタスク>` が1本走る（要 claude 等）
- [ ] 可能なら `--n 2` で race を1回
- [ ] diff → merge / discard の手触りを一言

### D. Linear（ブラウザのみ・作らない）

1回の作業ごとに手数を書く:

```text
日付:
issue:
手順: 開く → コピー → hangar/sidekick に貼る → 起動
手数（キー/クリック概算）:
痛さ (0-5):
「glue が欲しい」?: yes/no
```

週の終わりに:

- 痛さ平均が **3未満** または 週1回未満 → **Phase 2 作らない**
- 痛さ **4以上が週3+** → Phase 2 で極小 glue を検討

## 記録用テンプレ（コピーして追記）

```markdown
## Week of YYYY-MM-DD

### Stack health
- sidekick CLI available:
- hangar spawn worked:
- octo usable:

### Linear friction log
| date | issue | steps | pain | want glue? |
| --- | --- | --- | --- | --- |
|  |  |  |  |  |

### Decision
- Continue hangar? yes/no
- Keep octo? yes/no
- Phase 2 glue? yes/no / later
```

## 意図的にやらないこと

- Linear プラグイン導入（この Phase ではノイズ）
- Agent Valley
- contextmark への Linear 統合
- Design Mode / Mobile
