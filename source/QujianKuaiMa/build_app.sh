#!/usr/bin/env bash
# 取件快码 Assit — 编译桌面 App（Author: AssitDev）
# 统一编 arm64：A12+ 的普通 App 进程可以运行 arm64，两个包共用同一份二进制。
set -e
cd "$(dirname "$0")"

THEOS_DIR="${THEOS:-$HOME/theos}"
SDK="$(ls -d "$THEOS_DIR"/sdks/iPhoneOS*.sdk 2>/dev/null | grep -v Simulator | tail -1)"
[ -n "$SDK" ] || { echo "找不到 iPhoneOS SDK"; exit 1; }

APP="layout/Applications/QujianKuaiMa.app"
mkdir -p "$APP"
cp app/Resources/Info.plist "$APP/Info.plist"
cp app/Resources/AppIcon60x60@2x.png "$APP/"
cp app/Resources/AppIcon60x60@3x.png "$APP/"
# 图标别名：不同 iOS 版本查找图标的命名规则不一致，两种都给
cp app/Resources/AppIcon60x60@2x.png "$APP/Icon@2x.png"
cp app/Resources/AppIcon60x60@3x.png "$APP/Icon@3x.png"

xcrun -sdk iphoneos clang \
  -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc \
  -isysroot "$SDK" -F"$SDK/System/Library/Frameworks" \
  -I. -Iapp \
  -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore \
  app/main.m app/QKMRootViewController.m app/QKMCodesViewController.m \
  app/QKMDiagnosticsViewController.m \
  QKMConfig.m QKMParser.m QKMStore.m \
  -o "$APP/QujianKuaiMa"

ldid -S "$APP/QujianKuaiMa"
echo "== App 已编译并签名: $APP/QujianKuaiMa =="
