#!/bin/sh
# remap セットアップ: ビルド → LaunchAgent 登録 → ログイン時自動起動。
# リポジトリの場所を自動取得するので、どこに clone しても動く。
# 再実行しても安全（既存を停止してから入れ直す）。
set -e

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
APP_BIN="$REPO_DIR/remap.app/Contents/MacOS/remap"
LABEL="com.local.remap"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 1. ビルド（remap.app を生成）
sh "$REPO_DIR/build.sh"

# 2. 既存エージェント / プロセスを停止
launchctl unload "$PLIST" 2>/dev/null || true
pkill -f "remap.app/Contents/MacOS/remap" 2>/dev/null || true

# 3. LaunchAgent plist を生成（実行ファイルの絶対パスを埋め込む）
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <!-- ログイン時に起動する remap 本体 -->
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- KeepAlive は付けない: メニューの Quit で明示終了できるようにするため -->
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF
echo "LaunchAgent を生成: $PLIST"

# 4. adhoc 署名は再ビルドで署名ハッシュが変わり権限が外れるため、
#    念のため権限エントリを掃除しておく（このあと付与し直す）。
tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true

# 5. 読み込み（RunAtLoad で即起動）
launchctl load -w "$PLIST"

cat <<'MSG'

==================================================================
セットアップ完了。

初回のみアクセシビリティ権限の付与が必要です:
  システム設定 > プライバシーとセキュリティ > アクセシビリティ
  で remap を許可してください。
  → 許可した瞬間に自動で有効化されます（再起動・再ログイン不要）。

以降はログインのたびに自動で常駐します。
メニューバーの ⌨ アイコンから ON/OFF・終了ができます。

コードを変更して再ビルドしたとき（adhoc 署名のため署名が変わる場合）は
このスクリプトを再実行し、権限を付与し直してください。
==================================================================
MSG
