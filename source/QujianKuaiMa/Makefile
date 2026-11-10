# ============================================================================
#  取件快码 Assit  —  Theos project
#  Author : AssitDev
#
#  无根 (rootless, Dopamine / palera1n):
#      make clean && make package THEOS_PACKAGE_SCHEME=rootless
#  隐根 (roothide / Dopamine-RootHide):
#      bash build.sh roothide
#      # 等价于: make package THEOS_PACKAGE_SCHEME=roothide \
#      #              THEOS_MODULE_PATH="$(pwd)/mod" ARCHS=arm64e
#
#  注意: 源码里没有任何硬编码的 /var/jb 路径，所有文件读写都基于
#        NSHomeDirectory() / NSUserDefaults，因此同一份源码可直接产出两种包。
# ============================================================================

export TARGET := iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME ?= rootless

INSTALL_TARGET_PROCESSES = SpringBoard

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS = arm64e
else
ARCHS = arm64
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QujianKuaiMa

QujianKuaiMa_FILES = Tweak.m QKMConfig.m QKMBubble.m
QujianKuaiMa_CFLAGS = -I$(THEOS_PROJECT_DIR)/include -I$(THEOS)/vendor/lib/CydiaSubstrate.framework/Headers -I$(THEOS)/vendor/include -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
QujianKuaiMa_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore UserNotifications

# 本机 theos 把 libroot.a 放在 vendor/lib；roothide scheme 默认搜索路径里没有它
QujianKuaiMa_LDFLAGS = -L$(THEOS)/vendor/lib -L$(THEOS)/vendor/lib/iphone/rootless -F$(THEOS)/vendor/lib/iphone/rootless

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
QujianKuaiMa_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/roothide.entitlements
endif

include $(THEOS_MAKE_PATH)/tweak.mk
