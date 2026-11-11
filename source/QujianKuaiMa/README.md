# 取件快码 Assit — 源码

**Author: AssitDev** · 包名 `com.assitdev.qujiankuaima` · v3.0.0

**1.0 的「通知抓码 + 取件码清单」与 2.0 的「三个身份码 + 六个查件入口」合并版。**
一个 deb 里同时提供桌面 App、SpringBoard 悬浮球内置面板、iOS 设置页三个入口，
三者共享同一份偏好与同一份取件码数据。

## 功能

| 模块 | 说明 |
|---|---|
| 查件 Tab | 三个身份码（淘宝 / 拼多多 / 京东）、六个查件入口（淘宝 / 拼多多 / 京东 / 抖音 / 快手 / 得物），URL Scheme 跳转，链接可自定义，未装 App 时网页兜底 |
| 取件码 Tab | 通知自动抓码、按驿站归类去重、点一下复制、左滑标记已取 / 删除、搜索、手动添加、剪贴板识别；新码顶部横幅 |
| 自检 Tab | 插件注入状态、`postinst` 的 uicache 安装日志、一键复制 `uicache -a && killall -9 SpringBoard` |
| 悬浮球面板 | 点击直接展开内置面板（待取码 + 九个入口），**不依赖桌面 App 是否注册成功** |
| iOS 设置页 | 悬浮球 / 自动抓码 / 横幅开关、保留天数、自定义关键词、九个入口链接 |

数据只写本机 plist，不联网、不上传。

## 目录结构

```
Makefile / build.sh / build_app.sh   构建（App 由 build_app.sh 用 xcrun clang 编译并 ldid 签名）
QKMConfig.h/.m                      九个入口定义、偏好读写、共享数据路径、Darwin 通知
QKMParser.h/.m                      本机正则解析（取件码 / 取餐码 / 货架号 3-2-1056 / 自定义关键词）
QKMStore.h/.m                       取件码 plist 存储（App 与 SpringBoard 共用绝对路径）
app/main.m                          UITabBarController 三个 Tab
app/QKMRootViewController.m         查件 Tab（按原帖截图布局）+ 设置页
app/QKMCodesViewController.m        取件码 Tab
app/QKMDiagnosticsViewController.m  自检 Tab
app/Resources/                      Info.plist 与图标
Tweak.m                             SpringBoard 注入端（纯 constructor + runtime swizzle）
QKMBubble.h/.m                      可拖动悬浮球
QKMPanel.h/.m                       悬浮球展开的内置面板
layout/Applications/...              App 产物目录（构建时生成，已 gitignore）
layout/DEBIAN/postinst              uicache -a + uicache -p + 日志 + Respring
layout/Library/PreferenceLoader/     iOS 设置页 plist 与图标
mod/roothide/                       本机 theos 缺的 roothide scheme 模块
include/CydiaSubstrate/             arm64e 构建所需的 substrate 头转发
```

## 构建

需要 Xcode + theos（默认 `$THEOS` 或 `~/theos`）+ `ldid`。

```bash
bash build.sh            # 无根 rootless → *_3.0.0_iphoneos-arm64.deb
bash build.sh roothide   # 隐根 roothide → *_3.0.0_iphoneos-arm64e.deb
```

两个方案都先跑 `build_app.sh` 编译桌面 App，再由 theos 编译 tweak 并连同 `layout/` 一起打进 deb。
源码不含硬编码的 `/var/jb`，前缀全部交给 theos 的 package scheme 处理。

## 关键实现决定

- **不再链接 CydiaSubstrate**：`Tweak.m` 用普通 `constructor` + `objc/runtime` 的
  `method_setImplementation` 读取 `BBServer` 通知，不依赖 Logos / `MSHookMessageEx`，
  在 ElleKit 与不同 iOS 版本上少一层 dylib 加载失败的可能。
- **桌面图标注册**：`postinst` 优先执行 `uicache -a`（Dopamine「刷新越狱应用」的官方动作，
  2.0 只跑 `uicache -p` 常常不足），再跑 `uicache -p`，失败时退回无参数全量刷新；
  每一步的返回码写入 `install.log`，App 自检页直接显示。`Info.plist` 补了
  `CFBundleSupportedPlatforms` 与构建元数据，并同时提供两套图标命名。
- **跨进程数据**：App 与 SpringBoard 读写同一份
  `/var/mobile/Library/Application Support/QujianKuaiMa/codes.plist`（绝对真实路径，
  roothide 下 `/var/mobile` 同样是系统真实路径），改动通过 Darwin 通知同步。
- **不把功能押在单一入口**：桌面图标注册失败 → 悬浮球面板可用；
  注入也失败 → iOS 设置页与桌面 App 仍可用（手动添加 / 剪贴板识别不依赖 hook）。

## 已知限制

- 各厂商「身份码 / 待取包裹」页的 URL Scheme 深链路径不公开、会随版本变化，
  默认只填 App 首页 scheme，完整深链由使用者在设置里自行填写。
- App 统一编译 arm64（A12+ 的普通 App 进程可运行），roothide 包里的 tweak 为 arm64e 原生。
- 二进制为本地编译验证，未在真机越狱环境实测。
