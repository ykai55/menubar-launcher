#!/bin/bash
# 发版：./make-release.sh 0.3.0
# 写 VERSION → 提交 → 打 tag 推送。推送 tag 后由 .github/workflows/release.yml 构建、建 Release、更新 Homebrew tap
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$1"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "工作区有未提交的改动，先提交再发版" >&2
    exit 1
fi

echo "$VERSION" > VERSION
git add VERSION
git commit -m "Release v$VERSION"
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
echo "已推送 v$VERSION，查看进度：gh run watch --repo ykai55/menubar-launcher"
