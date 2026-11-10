# 取件快码 Assit — 源码

**Author: AssitDev** · 包名 `com.assitdev.qujiankuaima` · v1.0.0

一个 iOS 越狱插件：把散落在短信 / 微信 / 菜鸟 / 丰巢等通知里的取件码，
在本机解析后收进桌面悬浮球，按驿站归类，点一下复制。

## 功能

| 模块 | 说明 |
|---|---|
| 自动抓码 | Hook `BBServer -publishBulletin:…`（SpringBoard），把通知标题/副标题/正文拼起来跑正则 |
| 解析规则 | `取件码/取餐码/货架号/口令/验证码` + 自定义关键词；三段式货架号 `3-2-1056`；`凭 XXXX 取件`；驿站语境里的 4–8 位纯数字兜底 |
| 归类去重 | 识别菜鸟、丰巢、中通/圆通/申通/韵达/极兔、邮政、京东、顺丰、美团/饿了么等；提取地址；同码 + 同驿站去重 |
| 悬浮球 | 可拖动吸附、待取数量角标、点开面板、长按隐藏、透明度可调 |
| 列表面板 | 待取 / 已取 / 设置三页；点条目复制；左滑标记已取 / 删除；搜索；超 24h 高亮 |
| 补录 | 手动添加、剪贴板识别 |
| 提醒 | 新码到达时顶部横幅 4 秒 |
| 设置 | 总开关、悬浮球、自动抓码、横幅、保留天数(1–90)、透明度、自定义关键词 |
| 存储 | `~/Library/Application Support/QujianKuaiMa/codes.plist`，**不联网、不上传** |

## 目录

```
Makefile                 构建配置（rootless / roothide 两种 scheme）
control                  无根包的 control
control.roothide         隐根包的 control（不同包名 / 架构 / Conflicts）
build.sh                 一键构建
Tweak.xm                 Logos hook：BBServer 通知 + SpringBoard 启动
QKMCommon.h              公共接口
QKMPrefs.m               设置（NSUserDefaults suite）
QKMParser.m              本机正则解析
QKMStore.m               本机 plist 存储 / 去重 / 过期清理
QKMUI.m                  悬浮球、面板、设置、横幅（纯公开 UIKit）
QujianKuaiMa.plist       MobileSubstrate filter: com.apple.springboard
include/CydiaSubstrate/  构建用转发头（解决本机 theos arm64e 找不到声明的问题）
mod/roothide/            项目自带的 roothide scheme 模块（源自 roothide/theos，MIT）
roothide.entitlements    隐根构建所需签名权益
```

## 构建

需要 Xcode + theos（`THEOS` 环境变量，默认 `~/theos`）。

```bash
bash build.sh             # 无根：packages/..._iphoneos-arm64.deb
bash build.sh roothide    # 隐根：packages/...roothide_1.0.0_iphoneos-arm64e.deb
```

等价的原生命令：

```bash
make clean && make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make clean && make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide \
     THEOS_MODULE_PATH="$(pwd)/mod"
```

> 官方 `roothide/theos` 自带 `roothide` scheme 模块，用它构建时不需要
> `THEOS_MODULE_PATH`；本项目自带一份，是为了在普通 theos 上也能产出隐根包。

## 为什么一份源码能出两种包

- **没有任何硬编码的 `/var/jb` / `/Library/MobileSubstrate` 路径**：
  所有文件读写走 `NSHomeDirectory()` 和 `NSUserDefaults`，都是系统真实路径。
- 路径前缀完全由 theos 的 scheme 模块决定：
  `rootless` → `/var/jb/...`（arm64）；
  `roothide` → 无前缀、`@loader_path/.jbroot` 解析动态库（arm64e）。
- 隐根构建会带上 `roothide.entitlements`（`platform-application`、
  `no-sandbox`、`AppBundles`、`AppDataContainers`）。

## 两个包的关系

| 包名 | 环境 | 架构 | 说明 |
|---|---|---|---|
| `com.assitdev.qujiankuaima` | rootless 无根 | iphoneos-arm64 | 标准包，名称「取件快码 Assit」 |
| `com.assitdev.qujiankuaima.roothide` | roothide 隐根 | iphoneos-arm64e | 原生包，名称「取件快码 Assit · 隐根」 |

两者 `Conflicts` 互斥，安装时包管理器会自动替换，**只装与环境对应的那一个**。

## 说明

本插件为个人学习研究产物，仅供自有设备使用。代码为原创实现，
不包含任何第三方 App 的代码、资源或签名，也不涉及激活 / 授权绕过。
