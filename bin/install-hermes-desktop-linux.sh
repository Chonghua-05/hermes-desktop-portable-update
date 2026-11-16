#!/usr/bin/env bash
# Hermes Desktop 一键安装/更新（Linux x64，Arch/Fedora/Debian 通用）
#
#   /opt/hermes-desktop/            应用目录（属主当前用户，更新不需要 root）
#   /usr/bin/hermes-desktop         启动命令
#   /usr/share/applications/hermes-desktop.desktop   桌面菜单入口
#
# 幂等：重复执行会把 app.asar 更新到最新 Release，Electron 已存在则跳过。
#
# 用法：
#   curl -fsSL <release>/latest/download/install-hermes-desktop-linux.sh | bash
#   ASAR_URL=/path/app.asar bash install-hermes-desktop-linux.sh
#
# 环境变量：
#   DEST / BIN_DIR / APPS_DIR   默认 /opt/hermes-desktop、/usr/bin、/usr/share/applications
#   ELECTRON_VER                Electron 版本，默认 44.9.3
#   ASAR_URL / ASAR_MANIFEST_URL  app.asar 与 manifest.json 来源（默认本仓库 latest）
#   ASAR_SHA256                 覆盖校验值；留空则从 manifest 读；两者都空则跳过
#   SUDO                        写系统路径前缀，默认 sudo
set -uo pipefail

REPO_SLUG="${REPO_SLUG:-Chonghua-05/hermes-desktop-portable-update}"
DEST="${DEST:-/opt/hermes-desktop}"
BIN_DIR="${BIN_DIR:-/usr/bin}"
APPS_DIR="${APPS_DIR:-/usr/share/applications}"
ELECTRON_VER="${ELECTRON_VER:-44.9.3}"
ASAR_URL="${ASAR_URL:-https://github.com/$REPO_SLUG/releases/latest/download/app.asar}"
ASAR_MANIFEST_URL="${ASAR_MANIFEST_URL:-https://github.com/$REPO_SLUG/releases/latest/download/manifest.json}"
ASAR_SHA256="${ASAR_SHA256-}"
ICON_URL="${ICON_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/v0.23.1/apps/desktop/assets/icon.png}"
MIRROR="${MIRROR:-https://npmmirror.com/mirrors/electron}"
SUDO="${SUDO-sudo}"

die() { echo "错误：$*" >&2; exit 1; }

for c in curl unzip sha256sum; do command -v "$c" >/dev/null || die "缺少 $c"; done

echo "[1/5] 创建 $DEST（属主 $USER，后续更新免 root）"
$SUDO install -d -o "$USER" -g "$USER" -m 755 "$DEST" || die "无法创建 $DEST"

echo "[2/5] Electron $ELECTRON_VER"
if [ -x "$DEST/electron" ]; then
  echo "      已安装，跳过"
else
  tmp=$(mktemp -d)
  curl -fL --retry 3 --connect-timeout 20 -o "$tmp/electron.zip" \
    "$MIRROR/$ELECTRON_VER/electron-v$ELECTRON_VER-linux-x64.zip" \
    || { rm -rf "$tmp"; die "Electron 下载失败"; }
  unzip -q "$tmp/electron.zip" -d "$DEST" || { rm -rf "$tmp"; die "Electron 解包失败"; }
  rm -rf "$tmp"
fi
chmod +x "$DEST/electron"
# Chromium 沙箱：setuid helper 必须 root:root 4755，否则只能靠 --no-sandbox
if [ -f "$DEST/chrome-sandbox" ] && [ "$(stat -c '%u:%a' "$DEST/chrome-sandbox")" != "0:4755" ]; then
  $SUDO chown root:root "$DEST/chrome-sandbox" 2>/dev/null &&
    $SUDO chmod 4755 "$DEST/chrome-sandbox" 2>/dev/null || true
fi

echo "[3/5] app.asar"
mkdir -p "$DEST/resources"
if [ -z "$ASAR_SHA256" ]; then
  # manifest 里带构建产物的 sha256，按它校验；拿不到就不校验
  ASAR_SHA256=$(curl -fsSL --connect-timeout 15 "$ASAR_MANIFEST_URL" 2>/dev/null \
    | sed -n 's/.*"sha256" *: *"\([0-9a-f]\{64\}\)".*/\1/p' | head -1)
fi
case "$ASAR_URL" in
  http://*|https://*)
    curl -fL --retry 3 --connect-timeout 20 -o "$DEST/resources/app.asar.new" "$ASAR_URL" \
      || die "asar 下载失败：$ASAR_URL" ;;
  *)  [ -f "$ASAR_URL" ] || die "找不到 $ASAR_URL"
      cp "$ASAR_URL" "$DEST/resources/app.asar.new" ;;
esac
size=$(stat -c%s "$DEST/resources/app.asar.new")
[ "$size" -gt 1000000 ] || { rm -f "$DEST/resources/app.asar.new"; die "asar 太小($size)，来源不对"; }
if [ -n "$ASAR_SHA256" ]; then
  got=$(sha256sum "$DEST/resources/app.asar.new" | cut -d' ' -f1)
  [ "$got" = "$ASAR_SHA256" ] || { rm -f "$DEST/resources/app.asar.new"; die "asar 校验不匹配（期望 $ASAR_SHA256，实际 $got）"; }
  echo "      $size 字节，sha256 校验通过"
else
  echo "      $size 字节（未取到校验值，跳过校验）"
fi
mv -f "$DEST/resources/app.asar.new" "$DEST/resources/app.asar"

echo "[4/5] 启动器 $BIN_DIR/hermes-desktop"
cat > "$DEST/hermes-desktop" <<'LAUNCH'
#!/usr/bin/env bash
DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
FLAGS=()
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = wayland ]; then
  FLAGS=(--ozone-platform=wayland --enable-features=WaylandWindowDecorations)
fi
exec "$DIR/electron" "${FLAGS[@]}" "$@"
LAUNCH
chmod +x "$DEST/hermes-desktop"
$SUDO ln -sfn "$DEST/hermes-desktop" "$BIN_DIR/hermes-desktop" || true

echo "[5/5] 桌面入口"
[ -f "$DEST/icon.png" ] || curl -fsSL --connect-timeout 15 -o "$DEST/icon.png" "$ICON_URL" 2>/dev/null
$SUDO install -d -m 755 "$APPS_DIR" 2>/dev/null
$SUDO tee "$APPS_DIR/hermes-desktop.desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=Hermes Desktop
Comment=Hermes Agent client
Exec=$DEST/hermes-desktop
Icon=$DEST/icon.png
Terminal=false
Categories=Development;
StartupWMClass=Hermes
EOF
$SUDO chmod 644 "$APPS_DIR/hermes-desktop.desktop" 2>/dev/null
command -v update-desktop-database >/dev/null && $SUDO update-desktop-database "$APPS_DIR" 2>/dev/null

echo
echo "装好了。运行：hermes-desktop"
echo "以后更新版本：重新执行同一条命令（自动跳过 Electron 下载）"
