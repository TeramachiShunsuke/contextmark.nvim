# Cloud デスクトップ確認環境（準備済み）

このエージェント VM 上の LazyVim 実機。手順の本体はホーム側:

- `~/preview-demo/HOWTO.md`
- `~/preview-demo/LAUNCH.sh`
- `~/preview-demo/READY.txt`

## 入っているもの

Neovim 0.12.5 / Kitty / LazyVim（markdown・octo・sidekick・hangar・contextmark） / Claude Code CLI / ImageMagick

## ユーザーがやること（認証だけ）

```bash
export PATH="$HOME/.local/bin:$PATH"
claude                 # ログイン
claude auth status     # loggedIn true
~/preview-demo/LAUNCH.sh
```

あとは HOWTO の確認メニュー（Sidekick → contextmark 送信 → Hangar sandbox）。
