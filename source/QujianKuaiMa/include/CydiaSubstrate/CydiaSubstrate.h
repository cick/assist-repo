#pragma once
/*
 * 构建用转发头（取件快码 Assit）
 *
 * theos 的 substrate.h 会 #include <CydiaSubstrate/CydiaSubstrate.h>，
 * 但本机 theos 只把真正的声明放在 CydiaSubstrate.framework/Headers 里，
 * 而 vendor/include/CydiaSubstrate.h 是一个会绕回来的转发，
 * 在 arm64e / clang modules 下会拿到一份「空声明」导致 MSHookMessageEx 未定义。
 *
 * 这里用引号包含同目录下的真实头（来自 theos 自带 CydiaSubstrate.framework，
 * 保留原版权与许可声明），保证 arm64 和 arm64e 两种构建都能拿到完整声明。
 */
#include <objc/runtime.h>
#include "CydiaSubstrate_real.h"
