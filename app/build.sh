#!/usr/bin/env bash
#
# 构建 PortHub.app —— 自包含的 macOS 应用，可直接分发给未安装 Node.js 的用户。
#
#   ./build.sh              构建到 app/build/PortHub.app
#   ./build.sh install      构建并安装到 /Applications
#   ./build.sh dmg          构建并打包成可分发的 DMG
#   ./build.sh release      构建 + 安装 + 打包 DMG（一条龙）
#
# 自包含的含义：Node.js 运行时与网关代码都放进 App bundle 内，
# 用户拖进「应用程序」即可使用，无需任何外部依赖。
#
# 说明：本机只有 Command Line Tools（无完整 Xcode），swiftc 默认挑的 SDK
# 与编译器版本不匹配，会报 `~Copyable` 之类的错误，因此显式指定 SDK。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"          # 项目根目录
BUILD="$HERE/build"
APP="$BUILD/PortHub.app"
BIN_NAME="PortHub"
VERSION="1.1.0"

SOURCES=("$HERE/Sources/main.swift" "$HERE/Sources/AppDelegate.swift" \
         "$HERE/Sources/ServiceController.swift" "$HERE/Sources/AppModel.swift" \
         "$HERE/Sources/MainWindow.swift" "$HERE/Sources/Design.swift")

# ── 选 SDK ────────────────────────────────────────────────────────────────
# 按可用性顺序取第一个存在的，避免逐个试编译（很慢）。
# 候选 SDK 列表，按优先级排列。
#
# 为什么要多个：SDK 与 swiftc 版本不匹配时会报 `~Copyable` 之类的内部错误，
# 而哪种组合能编过取决于机器。GitHub Actions 的 runner 是完整 Xcode（xcrun
# 给的就是对的），本机只有 Command Line Tools 且最新的 26.x 编不过，
# 需要退到 15.x。所以这里列出候选，编译失败自动换下一个。
sdk_candidates() {
  local from_xcrun
  from_xcrun="$(xcrun --show-sdk-path 2>/dev/null || true)"
  [[ -n "$from_xcrun" && -d "$from_xcrun" ]] && echo "$from_xcrun"

  local sdk_root="/Library/Developer/CommandLineTools/SDKs"
  for v in 15.5 15.4 15.2 15 14.5 14; do
    [[ -d "$sdk_root/MacOSX${v}.sdk" ]] && echo "$sdk_root/MacOSX${v}.sdk"
  done
  ls -d "$sdk_root"/MacOSX*.sdk 2>/dev/null
}

# ── 找 node（要打包进 App）───────────────────────────────────────────────
#
# 必须打包：用户机器上未必装了 Node.js，而且即便装了也可能在 nvm 里、
# 从 Finder 启动的 App 找不到。内置一份最省事。
#
# CI 上由 actions/setup-node 提供，`command -v node` 就能拿到；
# 本机走 nvm / homebrew。
find_node() {
  for c in "$(command -v node 2>/dev/null)" \
           /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
  done
  local nvm="$HOME/.nvm/versions/node"
  if [[ -d "$nvm" ]]; then
    for v in $(ls "$nvm" | sort -Vr); do
      [[ -x "$nvm/$v/bin/node" ]] && { echo "$nvm/$v/bin/node"; return 0; }
    done
  fi
  return 1
}

NODE_BIN="$(find_node)" || { echo "✗ 找不到 node，无法构建自包含 App" >&2; exit 1; }
echo "→ Node: $NODE_BIN ($(du -h "$NODE_BIN" | cut -f1))"

# ── 编译主程序（逐个尝试候选 SDK）──────────────────────────────────────────
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/gateway/providers"

echo "→ 编译主程序…"
BUILT=0
while read -r sdk; do
  [[ -z "$sdk" || ! -d "$sdk" ]] && continue
  echo "   试 SDK: $(basename "$sdk")"
  if swiftc -sdk "$sdk" -O -target arm64-apple-macos13.0 -framework AppKit \
       -o "$APP/Contents/MacOS/$BIN_NAME" "${SOURCES[@]}" 2>/tmp/porthub-swiftc.log; then
    BUILT=1
    echo "   ✓ 使用 $sdk"
    break
  fi
  echo "   ✗ 编不过，换下一个"
done < <(sdk_candidates | awk '!seen[$0]++')

if [[ "$BUILT" -ne 1 ]]; then
  echo "✗ 所有候选 SDK 都编译失败。最后一次错误：" >&2
  tail -20 /tmp/porthub-swiftc.log >&2
  exit 1
fi

# ── 打包资源 ──────────────────────────────────────────────────────────────
echo "→ 打包资源…"

# 图标
cp "$HERE/icons/PortHub.icns" "$APP/Contents/Resources/PortHub.icns"
cp "$HERE/icons/menubar.png" "$APP/Contents/Resources/menubar.png"
[[ -f "$HERE/icons/menubar@2x.png" ]] && cp "$HERE/icons/menubar@2x.png" "$APP/Contents/Resources/menubar@2x.png"

# 网关代码（自包含的关键之一）
cp "$PROJECT/src/gateway.mjs" "$APP/Contents/Resources/gateway/"
cp "$PROJECT/src/providers/"*.mjs "$APP/Contents/Resources/gateway/providers/"
cp "$PROJECT/porthub.config.json" "$APP/Contents/Resources/gateway/"

# Node 运行时（自包含的关键之二）
#
# 注意：**不要 strip**。strip 会破坏 node 自带的代码签名，macOS 随后会
# 以 SIGKILL（退出码 137）直接杀掉它，表现为「网关静默起不来」。
# 体积换稳定，这里保留原样，最后统一重新签名。
echo "→ 打包 Node 运行时（体积大头，请稍候）…"
cp "$NODE_BIN" "$APP/Contents/Resources/node"
chmod +x "$APP/Contents/Resources/node"

# ── Info.plist ────────────────────────────────────────────────────────────
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PortHub</string>
  <key>CFBundleDisplayName</key><string>PortHub</string>
  <key>CFBundleIdentifier</key><string>io.porthub.app</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>PortHub</string>
  <key>CFBundleIconFile</key><string>PortHub</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- 常规应用：有主窗口与 Dock 图标；关窗后由代码切到 accessory 只留菜单栏 -->
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# ── 签名 ──────────────────────────────────────────────────────────────────
# 顺序很重要：**先签内部的 node，再签整个 App**。
# node 被复制进 bundle 后，它原有的签名路径已失效，必须先重新签名，
# 否则运行时会被 macOS 以 SIGKILL 杀掉（退出码 137）。
echo "→ 签名…"
codesign --force --sign - "$APP/Contents/Resources/node" 2>/dev/null || true

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID"; then
  codesign --force --deep --options runtime --sign "Developer ID Application" "$APP" 2>/dev/null \
    || codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

# 自检：确认 node 签名有效，否则整个 App 无法工作
if ! codesign --verify "$APP/Contents/Resources/node" 2>/dev/null; then
  echo "⚠️  node 签名校验未通过，运行时可能被系统终止" >&2
fi

SIZE="$(du -sh "$APP" | cut -f1)"
echo "✓ 构建完成: $APP ($SIZE)"

# ── 安装 ──────────────────────────────────────────────────────────────────
install_app() {
  local DEST="/Applications/PortHub.app"
  pkill -f "PortHub.app/Contents/MacOS/PortHub" 2>/dev/null || true
  sleep 1
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "✓ 已安装到 $DEST"
}

# ── 打包 DMG ──────────────────────────────────────────────────────────────
make_dmg() {
  local DMG="$BUILD/PortHub-${VERSION}.dmg"
  local STAGE="$BUILD/dmg-stage"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"

  # 用 APFS clonefile 而不是 cp -R。
  #
  # App 有 117MB（内置 node），普通复制要再占一份真实空间，GitHub Actions
  # 的 runner 磁盘很小，实测会在 hdiutil 阶段报 "No space left on device"。
  # clonefile 在同一文件系统内是写时复制，几乎不占额外空间、也快得多。
  # 文件系统不支持时回退到普通复制。
  if ! cp -cR "$APP" "$STAGE/" 2>/dev/null; then
    echo "   （clonefile 不可用，回退到普通复制）"
    cp -R "$APP" "$STAGE/"
  fi
  ln -s /Applications "$STAGE/Applications"   # 拖拽安装的快捷方式

  echo "→ 生成 DMG…"
  hdiutil create -volname "PortHub" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "✓ DMG: $DMG ($(du -h "$DMG" | cut -f1))"
}

# ── 入口 ──────────────────────────────────────────────────────────────────
case "${1:-}" in
  install) install_app ;;
  dmg)     make_dmg ;;
  release) install_app; make_dmg ;;
  *)       ;;
esac
