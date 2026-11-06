#!/bin/bash
# 发版：./make-release.sh 0.3.0
# 可选指定版本下限；平时直接推送 main 即可自动递增补丁号并发版。
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "用法：./make-release.sh X.Y.Z（设置版本下限并推送 main）" >&2
    exit 1
fi
if [ "$(git -C "$ROOT" branch --show-current)" != main ]; then
    echo "请在 main 分支发版" >&2
    exit 1
fi
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
    echo "工作区有未提交的改动，先提交再发版" >&2
    exit 1
fi

echo "$VERSION" > "$ROOT/VERSION"
git -C "$ROOT" add VERSION
if ! git -C "$ROOT" diff --cached --quiet; then
    git -C "$ROOT" commit -m "$(cat <<EOF
Set release version floor to $VERSION
EOF
)"
fi
git -C "$ROOT" push origin HEAD:main
echo "已推送 main，Actions 会选择至少 $VERSION 的版本发版。"
echo "查看进度：gh run list --repo ykai55/menubar-launcher"
