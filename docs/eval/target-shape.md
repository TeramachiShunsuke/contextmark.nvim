# Orca 相当スタックの落とし込み（全体像）

前提: LazyVim。モバイルなし。Orca を真似るのではなく、**同じ仕事を Neovim 寄りの部品で組む**。

## 1. 一枚絵 — 何がどこにあるか

```text
┌─────────────────────────────────────────────────────────────────┐
│                        LazyVim (日常の机)                         │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│  │ Markdown 閲覧 │  │ Note (自前)   │  │ Agent へ渡す           │ │
│  │ render-md    │  │ contextmark  │  │ Sidekick / hangar      │ │
│  │ snacks.image │  │ sidecar JSON │  │ clipboard fallback     │ │
│  └──────────────┘  └──────────────┘  └────────────────────────┘ │
│  ┌──────────────┐  ┌──────────────┐                              │
│  │ GitHub       │  │ Linear 閲覧* │  *成熟度低。ブラウザでも可   │
│  │ octo.nvim    │  │ linear.nvim  │                              │
│  └──────────────┘  └──────────────┘                              │
└──────────────────────────────┬──────────────────────────────────┘
                               │ spawn / worktree
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│              並列実行レイヤ（机の外、または hangar 窓）              │
│   hangar.nvim  … nvim 内ダッシュボード + worktree + best-of-N     │
│   workmux      … CLI + tmux（nvim と併用）                         │
│   Agent Valley … Linear webhook 常駐（完全自動。nvim 非依存）        │
└─────────────────────────────────────────────────────────────────┘
```

**自分たちが「製品として育てる」のは contextmark（Note）だけ。**  
他は LazyVim extras / 既存プラグイン / 外部ランタイムを選ぶ。

---

## 2. Orca 機能 → このスタックでの実体

| Orca | 落とし込み先 | 手触り |
| --- | --- | --- |
| Worktree 並列 | hangar または workmux | 「同じ prompt を N 本」は hangar `--n`。常時作業用 worktree は workmux が楽 |
| Annotate / Notes | **contextmark** | 選択 → Note → Orca 形式 prompt → agent。本文は汚さない |
| Send to agent | Sidekick（単発）+ hangar（並列） | contextmark の delivery が Sidekick / clipboard。並列は hangar 側 |
| Markdown rich preview | `lang.markdown` + snacks.image | バッファ内装飾 + 画像。ブラウザ preview は任意 |
| GitHub / Linear ネイティブ | octo +（任意）linear.nvim | Issue→worktree の一体感は無い |
| issue → agent 自動 | Agent Valley（外）または薄い glue | nvim プラグインで Valley 相当は作らない |
| Design Mode / Computer Use / Mobile | **対象外** | — |

---

## 3. 日常フロー（落としたあとの一日）

### A. 文書を読んでフィードバックする（contextmark 本線）

```text
1. Markdown を開く
   → render-markdown で読みやすい（<leader>um）
   → 画像があれば snacks.image がインライン表示

2. 気になる範囲を Visual 選択
   → <leader>mc で Note（contextmark）
   → 行末に N / 複数なら件数。hover で全文

3. 溜まったら
   → <leader>mps で選んで送る / <leader>mpa で全件
   → Sidekick の agent 欄へ（無ければ clipboard）

4. agent が直したら
   → 同じ Note が追従 or mismatch 警告
   → 必要なら再送 / 削除
```

ここが **Orca の Annotate loop の代替**。すでに実装済み。

### B. Issue 起点で直す（Linear / GitHub）

```text
今（組むだけ・手作業あり）:

  Linear/GitHub で issue を読む
       │  コピー or octo/linear で開く
       ▼
  hangar spawn / workmux add に本文を貼る
       │
       ▼
  worktree で agent が働く → diff → merge/PR
       │
       ▼
  （任意）contextmark でレビュー Note を付けて再送

将来（刺さったらだけ）:

  :SomethingFromLinear ENG-123
       │  薄い glue（未作成）
       ▼
  hangar spawn に title+body+url を流し込む
```

「Issue 管理 UI」は作らない。痛いのは **貼り付け手数** だけ、という前提。

### C. 同じバグを複数 agent に走らせる

```text
:Hangar spawn --n 3 --safe "fix flaky auth"
  → 3 worktree
  → dashboard で transcript / diff
  → 勝ちを merge、残り discard
```

Orca の「3-agent session」の最短形。Linear とは独立。

### D. 完全自動（nvim を触らない日）

```text
Linear に Todo を置く → Agent Valley が webhook 受信
  → worktree → agent → PR/merge → Done コメント
```

これは **別製品を採用する話**。LazyVim スタックの中には入れない。

---

## 4. 画面構成のイメージ（LazyVim 上）

```text
┌────────────┬──────────────────────────────┬─────────────────┐
│  explorer  │  markdown buffer             │  sidekick CLI   │
│            │  (render-markdown 装飾)       │  or hangar dash │
│            │  contextmark sign / virttext │                 │
│            │                              │                 │
├────────────┴──────────────────────────────┴─────────────────┤
│  statusline: git | hangar 2● | linear CTX? | contextmark?   │
└─────────────────────────────────────────────────────────────┘
```

- 左: いつもどおりのファイル
- 中央: **読む・Note を付ける場所**（preview + contextmark）
- 右: **agent と話す / 並列を見る場所**（Sidekick or Hangar）
- GitHub review が要る日だけ octo の review tab

Orca のような「worktree 一覧が左サイドバーの主役」にはしない。  
LazyVim のまま、**中央の Note と右の agent** が本線。

---

## 5. 所有境界（これが落とし込みの核）

| 層 | 所有 | 状態 |
| --- | --- | --- |
| Note / Orca prompt / sidecar | **このリポ（contextmark）** | 本番相当 |
| Markdown 見た目・画像 | LazyVim extras + snacks | 設定だけ |
| GitHub PR/Issue | octo | 採用 |
| Linear 一覧 | linear.nvim またはブラウザ | 試用 |
| 並列 worktree | hangar または workmux | 試用 |
| issue → spawn | **作るなら最小 glue のみ** | 未着手・要測定 |
| webhook 自動実行 | Agent Valley 等 | 採用判断（別リポ） |

```text
         作る                         組む                      外に置く
┌──────────────────┐    ┌─────────────────────────┐    ┌─────────────────┐
│ contextmark      │    │ render-md / snacks.image│    │ Agent Valley    │
│ (必要なら)        │    │ octo / sidekick         │    │ (常駐自動化)     │
│ Linear→hangar    │    │ hangar or workmux       │    │                 │
│ 1コマンド glue   │    │ linear.nvim（任意）      │    │                 │
└──────────────────┘    └─────────────────────────┘    └─────────────────┘
```

---

## 6. 「完成形」の定義（これで十分と言う線）

次を満たせば Orca 相当の **自分用 ADE** としては完成とみなす。

1. Markdown がバッファ内で読める（画像含む）
2. 範囲 Note → Orca 形式 → agent へバッチ送信ができる（**済み**）
3. 単発 agent は Sidekick、並列は hangar/workmux で回せる
4. GitHub の PR review は octo で足りる
5. Linear は「見る・たまに branch」まで。自動派遣は Valley か手作業
6. Design Mode / Mobile / Computer Use は諦めている（明示的）

満たさないもの（意図的）:

- Orca 一体感のある「issue カードから worktree が生える UI」
- ブラウザ Design Mode
- アカウント hot-swap / usage HUD（agent CLI 側に任せる）

---

## 7. 段階ロードマップ（作成判断付き）

```text
Phase 0  完了（Cloud デモで操作感確認済み）
  contextmark を本線として使う
  lang.markdown + snacks.image を有効化して読む体験を揃える

Phase 1  今ここ — 組む（コードほぼ無し）
  詳細: [phase1-runbook.md](phase1-runbook.md)
  octo / sidekick を常用
  並列は hangar に一本化して1週間試す（workmux は使わない）
  Linear はブラウザのまま手数を数える

Phase 2  測ってからだけ作る
  Linear→hangar の手数が週N回・毎回痛い
    → :ContextMark とは別の極小コマンド（issue id → spawn prompt）
  痛くない
    → 作らない

Phase 3  自動化が欲しくなったら
  Agent Valley を別プロセスで採用（nvim プラグイン化しない）
```

---

## 8. このリポにおける次の成果物

| 成果物 | 役割 |
| --- | --- |
| contextmark（本体） | Note 本線 |
| [orca-gaps.md](orca-gaps.md) | Rich preview / Linear の試用チェック |
| [contrib/lazyvim-eval/](../../contrib/lazyvim-eval/) | Phase 1 の差し込み設定 |
| この文書 | **全体の落とし込み図** |

実装 PR を増やすのは Phase 2 で「作る」が決まったあとのみ。
