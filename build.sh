#!/bin/sh
# remap を .app バンドルとしてビルドする。
# 素のバイナリ実行ではメニューバー項目が安定して表示されず、アクセシビリティ
# 権限もターミナルに紐づいてしまうため、最小構成の .app にまとめる。
set -e

APP="remap.app"
MACOS_DIR="$APP/Contents/MacOS"

# 1. Swift をコンパイル
swiftc -O src/main.swift -o /tmp/remap-bin

# 2. バンドル構造を組み立て
rm -rf "$APP"
mkdir -p "$MACOS_DIR"
cp /tmp/remap-bin "$MACOS_DIR/remap"
cp Info.plist "$APP/Contents/Info.plist"
rm -f /tmp/remap-bin

# 3. 署名
#    安定した自己署名証明書 "remap-signing" があればそれで署名する。
#    署名の identity が固定されるため、再ビルドで CDHash が変わっても
#    アクセシビリティ権限が維持される（再付与不要）。
#    証明書が無ければ adhoc(-) にフォールバック（この場合は再ビルドごとに再付与が必要）。
SIGN_IDENTITY="remap-signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "署名: 自己署名証明書 '$SIGN_IDENTITY' を使用（権限は再ビルド後も維持）"
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
    echo "署名: adhoc(-) を使用。'$SIGN_IDENTITY' 証明書を作ると権限が永続化されます（手順は README/会話を参照）。"
    codesign --force --sign - "$APP"
fi

echo "ビルド完了: $APP"
echo "起動:   open $APP   (または ./$MACOS_DIR/remap)"
echo "初回はアクセシビリティ権限の付与とアプリ再起動が必要です。"
