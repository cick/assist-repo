# Assist 越狱源

一个 iOS 15–16 的 APT 软件源，兼容 Cydia / Sileo / Zebra / Installer。
覆盖 **rootless 无根**（Dopamine / palera1n）与 **roothide 隐根** 两种环境。

源地址：**https://cick.github.io/assist-repo/**

## 收录的包

| 包名 | 名称 | 版本 | 说明 |
|---|---|---|---|
| `com.dev.callassiststatusbar` | 顶栏时间 Assit | 0.9.143 | 状态栏时间接管、天气 / 网速悬浮窗、停靠小图标动画主题 |
| `com.dev.dingtalkassistant` | 钉钉助手 | 0.9.21.1 | 定时自动打卡：多时间点（精确到秒）、桌面悬浮球、多企业自动选择 |
| `com.dev.dingtalkclicker` | 钉钉点击器（独立版） | 0.9.21.1 | 只含点击器本体，与助手内置的是同一个二进制；供检查注入 / 单独修复用 |
| `com.hang.zzzj` | 转转筛选 | 0.0.39 | 转转 App 悬浮球：自动翻页抓全搜索结果，按机型 / 内存 / 电池 / 系统 / 成色筛选 + 价格排序 |
| `com.hang.zlj` | 找靓机筛选 | 0.0.18 | 找靓机 App 悬浮球：搜索列表拉全，使用痕迹与验机报告同源，筛选 + 价格排序 |
| `com.assitdev.qujiankuaima` | 取件快码 Assit | 1.0.1 | 通知里自动抓出取件 / 取餐 / 货架码，按驿站归类进悬浮球；**rootless 无根**，`iphoneos-arm64` |
| `com.assitdev.qujiankuaima.roothide` | 取件快码 Assit · 隐根 | 1.0.1 | 同一份源码的 **roothide 原生**构建，`iphoneos-arm64e`，包内无 `/var/jb` 前缀 |

> ⚠️ **取件快码的两个包互斥**（已声明 `Conflicts`），只装与你越狱环境对应的那一个：
> 无根装标准包，隐根装「· 隐根」包。源码见 [`source/QujianKuaiMa/`](source/QujianKuaiMa/README.md)，
> 是**完整可编译**的 Theos 工程（`bash build.sh` / `bash build.sh roothide`），
> 与原帖软件只有功能思路上的对应，代码、图标、描述均为原创。
>
> **v1.0.1**：补上 iOS「设置」里的插件设置页（PreferenceLoader）与安装自动 Respring，并修复了部分 iOS 版本上悬浮球不初始化的问题。装完仍看不到时，确认 ElleKit / PreferenceLoader 已安装，并在 Dopamine 里点一次「重启 SpringBoard」。

> 点击器包与「钉钉助手」写的是同一个文件（`DynamicLibraries/DingTalkClicker.dylib`），
> 所以**两者的版本号必须一致**：助手升到新版本后，点击器包也要跟着升，否则会把点击器降回旧版。
> 不需要独立调试时，只要装「钉钉助手」就够，它自带点击器。
>
> ⚠️ 早先的 0.9.18 基线点击器**不能**与 0.9.21.1 的助手混用：它读不到
> `<钉钉容器>/Documents/DTA/dta_cmd.plist`（0.9.20 起才有的握手），装上去表现就是
> 「注入没反应、设置页看不到状态」。仓库里已改发 0.9.21.1 版。

## 源格式

标准 APT flat layout：

```
Packages / Packages.gz / Packages.bz2   索引（gen_repo.py 自动生成）
Release                                 源元信息 + 索引校验和
debs/                                   所有 .deb
icons/                                  包图标（<包名>.png，gen_repo.py 会自动写 Icon 字段）
depictions/                             详情页（HTML 给 Cydia/Zebra，*.sileo.json 给 Sileo）
depictions/assets/                      详情页用图：横幅（16:9）与功能示意图
index.html                              站点首页
source/                                 源码；钉钉助手为历史存档，QujianKuaiMa/ 为可编译 Theos 工程
```

## 发布新版本

```bash
# 1. 把新 deb 丢进 debs/（文件名建议 <package>_<version>_<arch>.deb）
cp ~/Desktop/xxx.deb debs/

# 2. 重新生成索引（纯 Python，不需要 dpkg-scanpackages）
python3 gen_repo.py

# 3. 提交并推送（push.sh 会先 pull --rebase，自动处理 README 冲突）
git add -A && git commit -m "release: <package> <version>"
bash push.sh
```

`gen_repo.py` 会自动：解析每个 deb 的 `control`、算 `Filename / Size / MD5sum / SHA256`、去掉非标准的 `Changelog` 字段、按包名匹配 `depictions/<package>.html` 决定详情页（没有对应文件的包不会挂错详情页），并在仓库里存在 `icons/<package>.png` 时写入 `Icon:` 字段。

## 图标与详情页图片

| 文件 | 尺寸 | 用途 |
|---|---|---|
| `icons/<package>.png` | 512×512 | 包图标，写进 `Packages` 的 `Icon:`，Sileo / Zebra 列表与详情头部显示 |
| `depictions/assets/<package>-banner.jpg` | 1920×1080 | 详情页顶部横幅（Sileo 原生页的 `headerImage` + `DepictionImageView`） |
| `depictions/assets/...-shot-N.png` | 750×1334 | 截图轮播（`DepictionScreenshotsView`，itemSize `{160, 284.6}`） |

新增一个包只要三步：丢 `icons/<package>.png`、丢 `depictions/<package>.sileo.json`、
丢 `debs/*.deb`，然后跑 `python3 gen_repo.py`。

Sileo 原生详情页（`*.sileo.json`）支持的常用视图：

```jsonc
{"class":"DepictionImageView",  "url":"…", "width":1920, "height":1080, "cornerRadius":16}
{"class":"DepictionScreenshotsView", "itemSize":"{160, 284.6}",
 "screenshots":[{"url":"…","accessibilityText":"…"}]}
{"class":"DepictionHeaderView",  "title":"小标题"}
{"class":"DepictionMarkdownView","markdown":"**粗体**、`代码`、多段用 \n\n"}
{"class":"DepictionTableTextView","title":"版本","text":"0.9.21.1"}
```

> Sileo 优先用 `SileoDepiction`（JSON，能显示图标 / 横幅 / 截图轮播），
> HTML 版只在 Cydia / Zebra 里用。两者都要维护，否则不同客户端体验不一致。

## 打包要点（越狱 deb 踩过的坑）

- **不要 strip 已签名的 dylib**：文件变短后 `LC_CODE_SIGNATURE` 的偏移仍指向旧位置，dyld 校验会直接 SIGKILL（表现为装完就安全模式）。打完包如需改动，用 `ldid -S` 重新签名。
- **control 的续行必须以一个空格开头**：写更新日志时用了全角空格，dpkg 会把它当成新字段，报 `field name ... must be followed by colon`，包直接装不上。
- **rootless 路径**：所有文件放在 `/var/jb/...`，注入目录是 `/var/jb/Library/MobileSubstrate/DynamicLibraries/`。
- **macOS 没有 dpkg-deb**：本仓库用 `tarfile` + 手写 `ar` 头组装 deb（系统自带 `ar rc` 会写成 BSD 扩展名格式，dpkg 可能不认）。
