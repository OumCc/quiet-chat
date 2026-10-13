#!/bin/bash
# 生成并验证完整更新清单；私钥仅从 stdin 送入 Sparkle，输出目录不得包含私钥。
set -euo pipefail

if [[ $# != 4 || -z "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
  echo "需要 app、归档目录、Sparkle bin、下载前缀和 SPARKLE_ED25519_PRIVATE_KEY" >&2
  exit 1
fi

# 提前拒绝无效输入，避免第三方工具的解码错误回显私钥内容。
python3 - <<'PY'
import base64
import os
import sys
try:
    key = base64.b64decode(os.environ["SPARKLE_ED25519_PRIVATE_KEY"].strip(), validate=True)
    assert len(key) in (32, 96)
except (ValueError, AssertionError):
    sys.exit("更新私钥格式无效")
PY

APP="$1"
ARCHIVES="$2"
SPARKLE_BIN="$3"
DOWNLOAD_PREFIX="$4"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHIVE="$ARCHIVES/QuietChat-$VERSION.dmg"

printf '%s\n' "$SPARKLE_ED25519_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" \
  --ed-key-file - --maximum-deltas 0 --maximum-versions 1 --embed-release-notes \
  --download-url-prefix "$DOWNLOAD_PREFIX" "$ARCHIVES"

printf '%s\n' "$SPARKLE_ED25519_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" \
  --ed-key-file - --verify "$ARCHIVES/appcast.xml"
swift "$SCRIPT_DIR/verify-update.swift" "$APP" "$ARCHIVE" "$ARCHIVES/appcast.xml"
