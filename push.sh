#!/usr/bin/env bash
# 一键推送到 GitHub（需先在 github.com 建好同名公开仓库 callassist-repo）
# 用法：
#   GITHUB_USER=你的GitHub用户名 bash push.sh
set -e
if [ -z "$GITHUB_USER" ]; then
  echo "请这样运行：GITHUB_USER=你的GitHub用户名 bash push.sh"
  exit 1
fi
REPO_NAME="callassist-repo"
cd "$(dirname "$0")"
git remote remove origin 2>/dev/null || true
git remote add origin "https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
git push -u origin main
echo
echo "✅ 已推送。GitHub Pages 源地址："
echo "   https://${GITHUB_USER}.github.io/${REPO_NAME}/"
echo "⚠️ 别忘了在 GitHub → 仓库 Settings → Pages → Source 选『main / root』并 Save（约 1-2 分钟生效）。"
