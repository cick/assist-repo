#!/usr/bin/env bash
# 推送到 GitHub（remote 已固定为 https://github.com/cick/assist-repo.git）
# 直接运行即可：
#   bash push.sh
# 若 git push 提示要密码：GitHub 不接受账号密码，请用 Personal Access Token（带 repo 权限）
# 当作密码粘贴；或先 `brew install gh` → `gh auth login`（浏览器授权）后免密。
set -e
cd "$(dirname "$0")"
echo "== 当前 remote =="
git remote -v
git push -u origin main
echo
echo "✅ 已推送。GitHub Pages 源地址："
echo "   https://cick.github.io/assist-repo/"
echo "⚠️ 别忘了在 GitHub → 仓库 Settings → Pages → Source 选『main / root』并 Save（约 1-2 分钟生效）。"
