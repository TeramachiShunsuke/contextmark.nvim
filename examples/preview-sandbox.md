# Preview sandbox（LazyVim 操作感用）

`lang.markdown` と snacks.image の見た目確認用。contextmark の Note も同じファイルに付けて衝突を見られる。

## Headings

### H3 sample

#### H4 sample

## Lists and links

- top level
  - nested item with [inline link](https://example.com)
  - inline `code`
* alternate bullet
+ plus bullet

## Table

| Status | Meaning | Wanted? |
| --- | --- | --- |
| exact | anchor ok | keep |
| stale | unresolved | warn |
| mismatch | wrong file? | warn |

## Callouts

> [!NOTE]
> Buffer-local render should feel like reading, not like a second window.

> [!TIP]
> Toggle with `<leader>um`. Browser preview is `<leader>cp`.

> [!WARNING]
> Image inline needs kitty/ghostty/wezterm + `magick`.

## Code

```lua
local function hello(name)
  return ("hello %s"):format(name)
end
```

## Image / PDF slots

ローカルに置いたらパスを直す:

![diagram](../docs/eval/fixtures/sample.png)

PDF を試すなら（snacks.image）:

- 同じディレクトリに `sample.pdf` を置き `:e sample.pdf`
- または Markdown から相対リンク

## Checklist for feel

- [ ] Insert 中は生 Markdown に戻るか
- [ ] 表の枠が読みやすいか
- [ ] callout の色がうるさくないか
- [ ] 画像が出るか / 出ない理由が分かるか（`:checkhealth snacks`）
- [ ] contextmark の sign と被らないか
