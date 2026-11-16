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
  # Latest stable release tag: 0.x line only, prereleases/canary and the old
  # calendar-versioned tags excluded.
  TAG=$(git ls-remote --tags origin 'refs/tags/v*' \
    | sed -e 's|.*refs/tags/||' -e 's|\^{}$||' \
    | grep -Ev '\-|\+' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -uV | tail -1)
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

cd apps/desktop
corepack pnpm run build

mkdir -p "$ART/$TAG"
rm -rf release/asar-src/dist release/asar-src/package.json
cp -r dist release/asar-src/dist
cp package.json release/asar-src/package.json
corepack pnpm dlx @electron/asar pack release/asar-src "$ART/$TAG/app.asar"

APP_VERSION="${TAG#v}"
SHA=$(sha256sum "$ART/$TAG/app.asar" | cut -d' ' -f1)
cat > "$ART/$TAG/manifest.json" <<EOF
{
  "tag": "asar-$TAG",
  "upstreamTag": "$TAG",
  "version": "$APP_VERSION",
  "builtAt": "$(date -uIseconds)",
  "sha256": "$SHA",
  "size": $(stat -c%s "$ART/$TAG/app.asar"),
  "artifactUrl": "$PORTABLE_RELEASE_URL/latest/download/app.asar"
}
EOF

echo "[build] done: $ART/$TAG/app.asar sha256=$SHA"
