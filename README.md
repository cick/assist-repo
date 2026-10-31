# CallAssist 越狱源

一个 iOS 15–16（rootless，Dopamine）的 APT 软件源，目前收录 **CallAssist StatusBar**（`com.dev.callassiststatusbar`，v0.9.98）。

## 目录结构

```
assist-repo/
├── Packages          # 包索引（明文）
├── Packages.gz / .bz2
├── Release           # 源元数据 + MD5/SHA256 校验和
├── icon.png          # 源图标（512 圆角紫蓝渐变 + 白色时钟）
├── index.html        # 落地页，自带「添加源 / 安装」按钮
├── debs/
│   └── com.dev.callassiststatusbar_0.9.98+debug_iphoneos-arm64.deb
├── gen_repo.py       # 重建索引脚本（纯 Python，不依赖 dpkg-scanpackages）
├── push.sh           # 一键推送到 GitHub 的脚本
└── README.md         # 本文件
```

## 源格式

标准 APT flat layout，兼容 Cydia / Sileo / Zebra / Installer。

索引由 `gen_repo.py` 生成：直接解析 deb（`ar → control.tar.gz → control`），自动算出 `Filename / Size / MD5sum / SHA256` 写进 `Packages`，再压成 `Packages.gz` / `.bz2` 并生成 `Release`。

## 托管方式

### 方式 A：GitHub Pages（推荐，免费）

1. 把这个 `assist-repo` 目录作为**独立仓库**推到 GitHub，仓库名 `assist-repo`（公开）。
2. 仓库页面 → **Settings → Pages → Source** 选 `Deploy from a branch` → Branch 选 **`main`**、目录选 **`/ (root)`** → Save。约 1–2 分钟生效。
3. 源地址即为：
   ```
   https://<你的用户名>.github.io/assist-repo/
   ```
   在 Sileo / Cydia / Zebra 里「添加源」粘贴这个地址即可看到并安装 0.9.98。

### 方式 B：Cloudflare Pages / Vercel / 任意 Nginx

把整个目录当静态文件服务出去即可，源地址就是该目录可访问 URL（**结尾的 `/` 建议带上**）。

## 升级 / 加新包

把新的 `.deb` 丢进 `debs/`（建议只留最新版，删掉旧 deb 避免重复条目），然后：

```bash
python3 gen_repo.py
```

重新部署整个目录即可。`index.html` 里的按钮会用当前访问域名自动拼出 `sileo://` / `cydia://` / `zbra://` 添加链接，不用手改。

## 各包管理器添加链接格式

- **Sileo**：`sileo://source/https://<域名>/assist-repo/`
- **Cydia**：`cydia://url/https://cydia.saurik.com/api/share#?source=https://<域名>/assist-repo/`
- **Zebra**：`zbra://sources/add/https://<域名>/assist-repo/`
