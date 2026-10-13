#!/bin/bash
# 将专用更新密钥导出到仓库外备份；只打印路径，不打印私钥，也不覆盖既有备份。
set -euo pipefail

if [[ $# != 1 ]]; then
  echo "用法：bash tools/release/export-update-key.sh <仓库外备份文件>" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DESTINATION="$1"
case "$DESTINATION" in
  /*) ;;
  *) echo "备份路径必须是绝对路径" >&2; exit 1 ;;
esac
umask 077
mkdir -p "$(dirname "$DESTINATION")"
DESTINATION="$(cd "$(dirname "$DESTINATION")" && pwd -P)/$(basename "$DESTINATION")"
case "$DESTINATION" in
  "$REPO_ROOT"/*) echo "私钥不能备份到仓库内" >&2; exit 1 ;;
esac

"$REPO_ROOT/macos/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys" \
  --account io.github.OumCc.QuietChat.updates -x "$DESTINATION"
chmod 600 "$DESTINATION"
echo "更新密钥已备份到：$DESTINATION"
