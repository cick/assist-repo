#!/usr/bin/env bash
# 推送到 GitHub（remote 固定 cick/assist-repo）
# 特性：
#   1. 先 git pull --rebase，自动处理本地与远程的历史分叉（不再出现 “fetch first” 拒绝）
#   2. 若变基时 README 冲突，自动保留本地（我们自己的）版本并继续
#   3. 再 git push（此时已是快进，不会被拒）
# 用法：
#   bash push.sh
# 若 push 提示要密码：GitHub 不接受账号密码，请用 Personal Access Token（带 repo 权限）当作密码；
# 或先 `brew install gh` → `gh auth login`（浏览器授权）后免密。
set -e

cd "$(dirname "$0")"

echo "== 当前 remote =="
git remote -v

echo
echo "== 拉取并变基（处理历史分叉） =="
resolved=0
if ! git pull --rebase origin main; then
  # pull --rebase 失败：先判断是不是进入了变基冲突态
  if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
    echo "⚠️ 变基出现冲突，自动解决 README 冲突（保留本地版本）..."
    n=0
    while [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; do
      n=$((n + 1))
      if [ "$n" -gt 20 ]; then
        echo "❌ 自动解决次数过多，疑似异常，请手动处理："
        git diff --name-only --diff-filter=U
        exit 1
      fi
      # 只自动处理 README 冲突；其它文件冲突交回手动
      if git diff --name-only --diff-filter=U | grep -qx README.md; then
        # rebase 语境：--ours = 上游基准版本，--theirs = 本地正在重放的提交
        # 这里保留「本地（我们自己）」的 README 版本
        git checkout --theirs README.md
        git add README.md
        GIT_EDITOR=true git rebase --continue || true
      else
        echo "❌ 遇到非 README 的冲突，无法自动解决，请手动处理："
        git diff --name-only --diff-filter=U
        exit 1
      fi
    done
    resolved=1
  else
    echo "❌ git pull 失败（可能是网络 / 认证问题），请检查后重试。"
    exit 1
  fi
fi
[ "$resolved" = 1 ] && echo "✅ README 冲突已自动解决，变基完成"

echo
echo "== 推送到 origin/main =="
git push -u origin main

echo
echo "✅ 推送完成。GitHub Pages 源地址："
echo "   https://cick.github.io/assist-repo/"
echo "⚠️ 若首次启用，去 GitHub → 仓库 Settings → Pages → Source 选『main / root』并 Save（约 1-2 分钟生效）。"
