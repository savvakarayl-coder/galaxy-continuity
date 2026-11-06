#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "===> Сборка Galaxy Continuity в Release-режиме..."
cd "$PROJECT_DIR"
swift build -c release

APP_NAME="Galaxy Continuity"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "===> Создание бандла $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Скопировать исполняемый файл
cp "$PROJECT_DIR/.build/release/GalaxyContinuity" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Скопировать Info.plist
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Скопировать иконку
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Подписание ad-hoc
echo "===> Подписание приложения..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "===> Проверка подписи..."
codesign -vvv "$APP_BUNDLE"

echo "✅ Приложение успешно собрано: $APP_BUNDLE"

# Установка в /Applications
echo "===> Установка в /Applications/$APP_NAME.app..."
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
echo "✅ Приложение установлено в /Applications/$APP_NAME.app"
