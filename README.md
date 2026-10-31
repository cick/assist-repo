# CallAssist 越狱源

一个 APT 风格的越狱插件分发源（兼容 **Cydia / Sileo / Zebra / Installer** 的 flat layout）。

当前收录：

| 包名 | 版本 | 说明 |
|---|---|---|
| `com.dev.callassiststatusbar` | 0.9.98 | 顶栏时间Assit：状态栏接管、天气/网速悬浮窗、停靠小图标 7 个动画主题 |

---

## 目录结构

```
callassist-repo/
├── Packages          # 包索引（明文）
├── Packages.gz
├── Packages.bz2
├── Release           # 源元数据 + 校验和
├── icon.png          # 源图标（Sileo 自动读取）
├── index.html        # 落地页（自带“添加源 / 安装”按钮）
├── debs/             # 所有 .deb 放这里
│   └── com.dev.callassiststatusbar_0.9.98+debug_iphoneos-arm64.deb
├── gen_repo.py       # 重建索引的脚本（纯 Python）
└── README.md
```

---

## 本地重建索引

每次往 `debs/` 里加 / 换新版本 deb 后，重新生成索引：

```bash
python3 gen_repo.py
```

脚本会解析每个 deb 的 control、计算 `Filename / Size / MD5sum / SHA256`，并重新写出
`Packages` / `Packages.gz` / `Packages.bz2` / `Release`。**无需** `dpkg-scanpackages`。

> 多个版本的同一个包：建议只保留最新版（删掉旧 deb），避免客户端列出重复条目。

---

## 如何托管（任选其一）

### A. GitHub Pages（最省事，免费）

1. 把这个 `callassist-repo` 目录作为**独立仓库**推到 GitHub，仓库名随便（例如 `callassist-repo`）。
2. 仓库 Settings → Pages → Source 选 `main` 分支、`/ (root)`，保存。
3. 等一两分钟，源地址就是：
   ```
   https://<你的用户名>.github.io/callassist-repo/
   ```
4. 在 Sileo / Cydia / Zebra 里「添加源」粘贴上面这个地址即可。

### B. 任意静态空间

Cloudflare Pages / Vercel / Netlify / 自己的 Nginx，只要能把整个目录当静态文件服务出去即可，
源地址就是该目录可访问的 URL（**结尾的 `/` 建议带上**）。

---

## 在客户端里添加

- **Sileo**：`sileo://source/https://<域名>/callassist-repo/`
- **Cydia**：`cydia://url/https://cydia.saurik.com/api/share#?source=https://<域名>/callassist-repo/`
- **Zebra**：`zbra://sources/add/https://<域名>/callassist-repo/`

落地页 `index.html` 里的按钮会自动用当前访问域名拼出上面这些链接，不用手改。

---

## 加新插件

1. 把新的 `.deb` 放进 `debs/`。
2. `python3 gen_repo.py`。
3. 重新上传 / 重新部署 Pages。

客户端刷新源即可看到新包。

---

## 可选增强（进阶）

- **源图标**：替换 `icon.png`（建议 512×512，圆角）。Sileo 会自动读取。
- **包详情页（Depiction）**：给 `Packages` 里每个包加 `Depiction:` 字段指向一个 HTML/JSON 页，
  可在 Sileo 里展示更漂亮的图文详情。脚本目前依赖 `Description:` 字段，已够用。
- **GPG 签名**：为 `Release` 生成 `Release.gpg` 可让较新客户端校验完整性（可选）。
