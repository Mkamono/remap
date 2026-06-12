#!/bin/sh
# remap のアンインストール: 自動起動を解除し、常駐を止め、Caps Lock を元に戻す。
set -e

LABEL="com.local.remap"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 1. エージェントを停止・登録解除
launchctl unload "$PLIST" 2>/dev/null || true
pkill -f "remap.app/Contents/MacOS/remap" 2>/dev/null || true

# 2. plist を削除
rm -f "$PLIST"

# 3. Caps Lock のリマップを解除（アプリ終了時にも戻すが念のため明示的に）
/usr/bin/hidutil property --set '{"UserKeyMapping":[]}' >/dev/null 2>&1 || true

echo "アンインストール完了: 自動起動の解除・常駐停止・Caps Lock 復元 を行いました。"
echo "アクセシビリティ権限の登録も消すには:"
echo "  tccutil reset Accessibility $LABEL"
