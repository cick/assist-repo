# 源码存档

> **`QujianKuaiMa/`（取件快码 Assit）是完整、可直接编译的 Theos 工程**，
> 与本页下面描述的历史存档不同：它带 `Makefile` / `control` / `build.sh` /
> `mod/roothide`，`bash build.sh` 出无根包，`bash build.sh roothide` 出隐根包。
> 细节见 [`QujianKuaiMa/README.md`](QujianKuaiMa/README.md)。

---

# 钉钉助手 · 源码存档

本目录的钉钉助手部分只是**历史源码存档**，不是可直接编译的工程。

## 现状

| 文件 | 说明 |
|---|---|
| `DingTalkAssistant-0.9.27.xm` | SpringBoard 侧调度器 + 悬浮球 + 点击器的中间版本源码（`kDTA_BuildTag = 0.9.27`），完整度最高的一份。 |
| `DingTalkAssistant-0.9.18-recovered.xm` | 0.9.18 时期回收版，仅作对照。 |

## 缺什么

`debs/` 里发布的 `0.9.21.1` 是用 **Theos 工程**构建的，工程目录（`Makefile`、`DingTalkAssistant.plist`、`DingTalkClicker.plist`、`prefs/DingTalkPrefs.m`、`prefs/Resources/Root.plist`、打包脚本）在一次系统清理后已丢失，只剩上面两个 `.xm`。

也就是说：

- 想改**调度器 / 点击器**逻辑 → 可以基于 `DingTalkAssistant-0.9.27.xm` 重建 Makefile 继续，但 `0.9.18.5 ~ 0.9.21.1` 之间的若干修复（秒级定时、触发冻结、`lastok` 验证、异步启动）需要从发布包的变更日志里逐条补回；
- 想改**设置页**（三列滚轮、多定时列表、左滑删除）→ 没有源码，只能反编译 `DingTalkPrefs` 可执行文件。

## 发布包结构（供重建参考）

rootless（`/var/jb`）下三个组件：

```
/var/jb/Library/MobileSubstrate/DynamicLibraries/
    DingTalkAssistant.dylib     → 注入 SpringBoard：定时、拉起钉钉、悬浮球、状态显示
    DingTalkAssistant.plist     → Filter: com.apple.springboard
    DingTalkClicker.dylib       → 注入钉钉：进考勤页、点打卡按钮、上报结果
    DingTalkClicker.plist       → Filter: com.laiwang.DingTalk 等 8 个 bundleID
/var/jb/Library/PreferenceBundles/DingTalkPrefs.bundle/
    DingTalkPrefs               → 设置页可执行文件
    Root.plist                  → 设置页布局（含 DingTalkSlotsCell 自定义行）
```

跨进程通信走钉钉自己的沙盒容器（`cfprefsd` 不允许跨域写）：

```
<钉钉容器>/Documents/DTA/dta_cfg.plist     配置
<钉钉容器>/Documents/DTA/dta_cmd.plist     pending / done / lastok
/var/mobile/Library/Preferences/dta_prefs_bridge.plist   设置页 → 调度器的桥接（带 _keys 增量）
```

## 免责

逆向学习产物，仅供研究，请勿用于规避考勤制度。
