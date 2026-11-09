# Assist 越狱源

一个 iOS 15–16（rootless，Dopamine / palera1n）的 APT 软件源，兼容 Cydia / Sileo / Zebra / Installer。

源地址：**https://cick.github.io/assist-repo/**

## 收录的包

| 包名 | 名称 | 版本 | 说明 |
|---|---|---|---|
| `com.dev.callassiststatusbar` | 顶栏时间 Assit | 0.9.143 | 状态栏时间接管、天气 / 网速悬浮窗、停靠小图标动画主题 |
| `com.dev.dingtalkassistant` | 钉钉助手 | 0.9.21.1 | 定时自动打卡：多时间点（精确到秒）、桌面悬浮球、多企业自动选择 |
| `com.dev.dingtalkclicker` | 钉钉点击器（独立版） | 0.9.18 | 只含点击器本体，安装即自动注入钉钉；供单独替换 / 调试用 |

> `钉钉助手` 的 deb 里已经自带点击器，**正常情况下不需要单独装** `钉钉点击器`。
> 单独安装会把助手包里的新版点击器覆盖成 0.9.18 基线版；想复原重装 `钉钉助手` 即可。

## 源格式

标准 APT flat layout：

```
Packages / Packages.gz / Packages.bz2   索引（gen_repo.py 自动生成）
Release                                 源元信息 + 索引校验和
debs/                                   所有 .deb
depictions/                             详情页（HTML 给 Cydia/Zebra，*.sileo.json 给 Sileo）
index.html                              站点首页
source/                                 钉钉助手的历史源码存档（不可直接编译，见其中 README）
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

`gen_repo.py` 会自动：解析每个 deb 的 `control`、算 `Filename / Size / MD5sum / SHA256`、去掉非标准的 `Changelog` 字段、并按包名匹配 `depictions/<package>.html` 决定详情页（没有对应文件的包不会挂错详情页）。

## 打包要点（越狱 deb 踩过的坑）

- **不要 strip 已签名的 dylib**：文件变短后 `LC_CODE_SIGNATURE` 的偏移仍指向旧位置，dyld 校验会直接 SIGKILL（表现为装完就安全模式）。打完包如需改动，用 `ldid -S` 重新签名。
- **control 的续行必须以一个空格开头**：写更新日志时用了全角空格，dpkg 会把它当成新字段，报 `field name ... must be followed by colon`，包直接装不上。
- **rootless 路径**：所有文件放在 `/var/jb/...`，注入目录是 `/var/jb/Library/MobileSubstrate/DynamicLibraries/`。
- **macOS 没有 dpkg-deb**：本仓库用 `tarfile` + 手写 `ar` 头组装 deb（系统自带 `ar rc` 会写成 BSD 扩展名格式，dpkg 可能不认）。
