# roothide 原生包使用 arm64e 架构
ifneq ($(THEOS_PACKAGE_ARCH),iphoneos-arm64e)
	THEOS_PACKAGE_ARCH := iphoneos-arm64e
endif
