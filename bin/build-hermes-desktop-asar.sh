#!/usr/bin/env bash
# Build a portable Hermes Desktop app.asar from an upstream release tag.
#
# Usage: build-hermes-desktop-asar.sh [upstream-tag]
#   (default: latest stable vX.Y.Z tag of the upstream repo)
#
# Works on a workstation and in CI:
#   WORKSPACE=<upstream clone> ART=<output dir> ./build-hermes-desktop-asar.sh v0.23.1
#
# Config: sourced from $HERMES_PACK_CONFIG (default ~/.config/hermes-desktop-pack/config.env).
set -euo pipefail

CONFIG="${HERMES_PACK_CONFIG:-$HOME/.config/hermes-desktop-pack/config.env}"
# Environment wins over config.env: CI and one-off runs pass WORKSPACE/ART/etc.
_ENV_WORKSPACE="${WORKSPACE-}"; _ENV_REPO="${REPO-}"; _ENV_ART="${ART-}"
_ENV_PATCH_DIR="${PATCH_DIR-}"; _ENV_RELEASE_SLUG="${RELEASE_SLUG-}"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
[ -n "$_ENV_WORKSPACE" ] && WORKSPACE="$_ENV_WORKSPACE"
[ -n "$_ENV_REPO" ] && REPO="$_ENV_REPO"
[ -n "$_ENV_ART" ] && ART="$_ENV_ART"
[ -n "$_ENV_PATCH_DIR" ] && PATCH_DIR="$_ENV_PATCH_DIR"
[ -n "$_ENV_RELEASE_SLUG" ] && RELEASE_SLUG="$_ENV_RELEASE_SLUG"

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
WORKSPACE="${WORKSPACE:-${REPO:-$HOME/hermes-desktop-build/hermes-agent}}"
PATCH_DIR="${PATCH_DIR:-$SELF_DIR/../patches}"
ART="${ART:-$HOME/hermes-desktop-artifacts}"

# Where clients look for updates: GitHub Releases of this packing repo. No
# LAN-specific address is baked into the bundle.
RELEASE_SLUG="${RELEASE_SLUG:-Chonghua-05/hermes-desktop-portable-update}"
PORTABLE_UPDATE_BASE="${PORTABLE_UPDATE_BASE:-https://api.github.com/repos/$RELEASE_SLUG/releases/latest}"
PORTABLE_RELEASE_URL="${PORTABLE_RELEASE_URL:-https://github.com/$RELEASE_SLUG/releases}"

export PATH="${NODE_BIN_DIR:-$HOME/.local/share/node24/bin}:$PATH"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

cd "$WORKSPACE"

TAG="${1:-${UPSTREAM_TAG:-}}"
if [ -z "$TAG" ]; then
  # Latest stable release tag: the 0.x line only. Upstream also publishes
  # calendar-versioned aliases (v2026.9.24 == 0.21.5); those sort ABOVE 0.x
  # under -V, so pin the major to 0 instead of merely excluding pre-releases.
  TAG=$(git ls-remote --tags origin 'refs/tags/v*' \
    | sed -e 's|.*refs/tags/||' -e 's|\^{}$||' \
    | grep -E '^v0\.[0-9]+\.[0-9]+$' | sort -uV | tail -1)
fi
[ -n "$TAG" ] || { echo "[build] cannot resolve upstream tag" >&2; exit 1; }

echo "[build] tag=$TAG"
git fetch --depth 1 origin tag "$TAG" 2>/dev/null || true
git checkout -f "$TAG"

# Re-apply the portable patch (GitHub-Releases update panel).
git apply --whitespace=nowarn "$PATCH_DIR/portable-update.patch" \
  || { echo "[build] portable patch failed to apply (upstream changed?)" >&2; exit 1; }
cp "$PATCH_DIR/files/portable-updates.ts" apps/desktop/src/lib/
cp "$PATCH_DIR/files/portable-update-panel.tsx" apps/desktop/src/app/
echo "[build] portable patch applied"

# Bake build identity + update origin into the bundle: package.json version is
# 0.0.0, so the panel compares against the tag constant instead.
cat > apps/desktop/src/lib/portable-build-tag.ts <<EOF
export const PORTABLE_BUILD_TAG = '$TAG'
export const PORTABLE_UPDATE_BASE = '$PORTABLE_UPDATE_BASE'
export const PORTABLE_RELEASE_URL = '$PORTABLE_RELEASE_URL'
EOF

corepack pnpm install --no-frozen-lockfile --ignore-scripts --config.engine-strict=false --filter ./apps/desktop...

# --ignore-scripts leaves node-pty without its binary; the bundle copies
# dist/node_modules/node-pty into app.asar, so it must be built here. NAPI
# (node-addon-api) keeps the result valid across Node/Electron ABIs.
corepack pnpm rebuild node-pty >/dev/null 2>&1 || true
PTY_NODE="apps/desktop/node_modules/node-pty/build/Release/pty.node"
[ -f "$PTY_NODE" ] || PTY_NODE="node_modules/node-pty/build/Release/pty.node"
[ -f "$PTY_NODE" ] || { echo "[build] node-pty binary missing; the bundle would ship a broken terminal" >&2; exit 1; }
echo "[build] node-pty: $PTY_NODE"

cd apps/desktop
corepack pnpm run build

mkdir -p "$ART/$TAG"
mkdir -p release/asar-src
rm -rf release/asar-src/dist release/asar-src/package.json
cp -r dist release/asar-src/dist
cp package.json release/asar-src/package.json
[ -d release/asar-src/dist ] || { echo "[build] dist missing, nothing to pack" >&2; exit 1; }
rm -rf "$ART/$TAG/app.asar.unpacked"
# Native modules (.node) and node-pty's spawn-helper cannot be loaded from
# inside the archive: they must live in app.asar.unpacked.
corepack pnpm dlx @electron/asar pack release/asar-src "$ART/$TAG/app.asar" \
  --unpack-dir "dist/node_modules"
[ -d "$ART/$TAG/app.asar.unpacked/dist/node_modules/node-pty" ] \
  || { echo "[build] app.asar.unpacked missing node-pty" >&2; exit 1; }

# CI compiles pty.node for Linux only, so a Windows green build would hit a
# Linux ELF in build/Release and fail to open a terminal. node-pty's loader
# walks build/Release -> build/Debug -> prebuilds/<platform>-<arch> and keeps
# the first one that actually loads, so carrying the win32 prebuilds (already
# in the npm tarball: conpty.node, conpty.dll, OpenConsole.exe, winpty) is what
# makes the Windows build's terminal work too.
NPT_UNPACK="$ART/$TAG/app.asar.unpacked/dist/node_modules/node-pty"
NPT_PREBUILDS_SRC=""
for cand in node_modules/node-pty/prebuilds ../../node_modules/.pnpm/node-pty@*/node_modules/node-pty/prebuilds; do
  if [ -d "$cand" ]; then NPT_PREBUILDS_SRC="$cand"; break; fi
done
[ -n "$NPT_PREBUILDS_SRC" ] \
  || { echo "[build] node-pty prebuilds not found; Windows terminal would be broken" >&2; exit 1; }
for plat in win32-x64 win32-arm64; do
  [ -d "$NPT_PREBUILDS_SRC/$plat" ] || continue
  mkdir -p "$NPT_UNPACK/prebuilds/$plat"
  cp -r "$NPT_PREBUILDS_SRC/$plat/." "$NPT_UNPACK/prebuilds/$plat/"
done
find "$NPT_UNPACK/prebuilds" -name '*.pdb' -delete
[ -f "$NPT_UNPACK/prebuilds/win32-x64/conpty.node" ] \
  || { echo "[build] win32 conpty.node missing after prebuilds copy" >&2; exit 1; }
echo "[build] node-pty prebuilds: $(find "$NPT_UNPACK/prebuilds" -type f | wc -l) files, $(du -sh "$NPT_UNPACK/prebuilds" | cut -f1)"

tar -czf "$ART/$TAG/app.asar.unpacked.tar.gz" -C "$ART/$TAG" app.asar.unpacked

APP_VERSION="${TAG#v}"
SHA=$(sha256sum "$ART/$TAG/app.asar" | cut -d' ' -f1)
UNPACKED_SHA=$(sha256sum "$ART/$TAG/app.asar.unpacked.tar.gz" | cut -d' ' -f1)
cat > "$ART/$TAG/manifest.json" <<EOF
{
  "tag": "asar-$TAG",
  "upstreamTag": "$TAG",
  "version": "$APP_VERSION",
  "builtAt": "$(date -uIseconds)",
  "sha256": "$SHA",
  "size": $(stat -c%s "$ART/$TAG/app.asar"),
  "unpackedSha256": "$UNPACKED_SHA",
  "unpackedSize": $(stat -c%s "$ART/$TAG/app.asar.unpacked.tar.gz"),
  "artifactUrl": "$PORTABLE_RELEASE_URL/latest/download/app.asar",
  "unpackedUrl": "$PORTABLE_RELEASE_URL/latest/download/app.asar.unpacked.tar.gz"
}
EOF

echo "[build] done: $ART/$TAG/app.asar sha256=$SHA"
