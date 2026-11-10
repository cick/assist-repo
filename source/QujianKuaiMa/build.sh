#!/usr/bin/env bash
# 取件快码 Assit — 一键构建（Author: AssitDev）
#
#   bash build.sh            # 无根 rootless，产出 *_iphoneos-arm64.deb
#   bash build.sh roothide   # 隐根 roothide，产出 *_iphoneos-arm64e.deb
#
# 需要 Xcode + theos（默认 $THEOS，或 ~/theos）。
set -e
cd "$(dirname "$0")"

export THEOS="${THEOS:-$HOME/theos}"
SCHEME="${1:-rootless}"

# 本机 theos 没有内置 roothide scheme 模块，用项目自带的 mod/roothide 补上；
# 若你装的是官方 roothide/theos，则不需要 THEOS_MODULE_PATH，命令会自动兼容。
restore_control=0
if [ "$SCHEME" = "roothide" ]; then
  cp control /tmp/qkm.control.rootless.$$
  cp control.roothide control
  restore_control=1
  trap 'mv /tmp/qkm.control.rootless.$$ "$(pwd)/control"' EXIT
fi

make clean >/dev/null 2>&1 || true

if [ "$SCHEME" = "roothide" ]; then
  make package FINALPACKAGE=1 \
       THEOS_PACKAGE_SCHEME=roothide \
       THEOS_MODULE_PATH="$(pwd)/mod"
else
  make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
fi

echo
echo "== 产物 =="
ls -lh packages/*.deb | tail -5
echo
echo "把对应 .deb 放进源的 debs/ 目录后运行 python3 gen_repo.py 即可发布。"
if [ "$restore_control" = "1" ]; then
  mv /tmp/qkm.control.rootless.$$ control
  trap - EXIT
fi
