# 取件快码 Assit — 源码

**Author: AssitDev** · 包名 `com.assitdev.qujiankuaima` · v2.0.0

按原帖截图重做的**取件聚合面板**：三个身份码 + 六个查件入口 + 设置页。
一个 deb 里同时提供**桌面 App**、**SpringBoard 悬浮球**和 **iOS 设置页**，
主入口是桌面 App —— 不依赖 tweak 注入是否成功，装完就能看到、点开就能用。

## 功能

| 模块 | 说明 |
|---|---|
| 三个身份码 | 淘宝 / 拼多多（驿站扫码出示）、京东（订单内查看） |
| 六个查件入口 | 淘宝待取、拼多多待取（查看待取包裹）；京东 / 抖音 / 快手 / 得物待取（查看订单物流） |
| 跳转 | 各 App 的 URL Scheme；`设置` 里可为每个入口填完整深链；未装对应 App 时可复制链接 / 打开网页版 |
| 桌面 App | `QujianKuaiMa.app`，`postinst` 用 `uicache` 注册；UIKit 纯代码界面，按截图布局 |
| 悬浮球 | 注入 SpringBoard 的可拖动「码」球，点击 `qujiankuaima://` 唤起 App |
| 设置 | App 内设置页 + iOS「设置」里的 PreferenceLoader 页，共享同一份 `NSUserDefaults` domain |
| 注入自检 | tweak 在 `%ctor` 写标记文件，App 设置页显示 dylib 有没有被加载 |

## 目录结构

```
Makefile / build.sh / build_app.sh   构建（App 由 build_app.sh 用 xcrun clang 编译并 ldid 签名）
QKMConfig.h/.m                      9 个入口定义、偏好读写、注入标记（App 与 tweak 共用）
app/                                桌面 App：main.m / QKMRootViewController.m / Info.plist / 图标
Tweak.m                             SpringBoard 注入端（普通 constructor，不 hook 任何私有 selector）
QKMBubble.h/.m                      悬浮球视图
layout/Applications/...              App 产物目录（构建时生成，已 gitignore）
layout/DEBIAN/postinst              uicache 注册 + cfprefsd 刷新 + Respring
layout/Library/PreferenceLoader/     iOS 设置页 plist 与图标
mod/roothide/                       本机 theos 缺的 roothide scheme 模块
include/CydiaSubstrate/             arm64e 构建所需的 substrate 头转发
```

## 构建

需要 Xcode + theos（默认 `$THEOS` 或 `~/theos`）+ `ldid`。

```bash
bash build.sh            # 无根 rootless → *_2.0.0_iphoneos-arm64.deb
bash build.sh roothide   # 隐根 roothide → *_2.0.0_iphoneos-arm64e.deb
```

两个方案都先跑 `build_app.sh` 编译桌面 App，再由 theos 编译 tweak 并连同 `layout/` 一起打进 deb。
源码不含硬编码的 `/var/jb`，前缀全部交给 theos 的 package scheme 处理。

## 实现要点与已知限制

- 早期版本（1.0.x）把功能猜成了「通知抓码 + 悬浮球清单」，方向错误，已被 2.0.0 整体替换。
- 原来 hook `SpringBoard -applicationDidFinishLaunching:` 依赖不稳定的私有 selector，
  在部分 iOS 15/16 上不会被系统调用；2.0.0 改用普通 `constructor`，不 hook 任何方法。
- 各厂商「身份码 / 待取包裹」页的 URL Scheme 深链路径不公开、会随版本变化，
  默认只填 App 首页 scheme，完整深链由使用者在设置里自行填写 —— 这是刻意保留的可配置性，
  插件不读取账号信息、不抓包、不联网。
- App 统一编译 arm64（A12+ 的普通 App 进程可运行），roothide 包里的 tweak 为 arm64e 原生。
- 二进制为本地编译验证，未在真机越狱环境实测。
