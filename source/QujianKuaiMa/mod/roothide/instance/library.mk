# roothide 使用 @loader_path/.jbroot 解析动态库依赖
ifneq ($(_LOCAL_LINKAGE_TYPE),static)
_THEOS_INTERNAL_LDFLAGS += -install_name "@loader_path/.jbroot$(LOCAL_INSTALL_PATH)/$(THEOS_CURRENT_INSTANCE)$(TARGET_LIB_EXT)"
endif
