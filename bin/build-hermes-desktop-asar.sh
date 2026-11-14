#!/usr/bin/env bash
# Build a portable Hermes Desktop app.asar from a release tag.
# Usage: build-hermes-desktop-asar.sh [tag]   (default: latest stable vX.Y.Z tag)
#
# Config: sourced from $HERMES_PACK_CONFIG (default ~/.config/hermes-desktop-pack/config.env).
set -euo pipefail

CONFIG="${HERMES_PACK_CONFIG:-$HOME/.config/hermes-desktop-pack/config.env}"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT="${BUILD_ROOT:-$HOME/hermes-desktop-build}"
REPO="${REPO:-$BUILD_ROOT/hermes-agent}"
PATCH_DIR="${PATCH_DIR:-$SELF_DIR/../patches}"
ART="${ART:-$HOME/hermes-desktop-artifacts}"
PACK_SERVER_BASE="${PACK_SERVER_BASE:-http://127.0.0.1:4011}"

export PATH="${NODE_BIN_DIR:-$HOME/.local/share/node24/bin}:$PATH"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

cd "$REPO"

if [ $# -ge 1 ]; then
  TAG="$1"
else
  # Latest stable release tag: 0.x line only, prereleases/canary and the old
  # calendar-versioned tags excluded.
  TAG=$(git ls-remote --tags origin 'refs/tags/v*' \
    | sed -e 's|.*refs/tags/||' -e 's|\^{}$||' \
    | grep -Ev '\-|\+' | grep -E '^v[0-9]\.[0-9]+\.[0-9]+$' | sort -uV | tail -1)
fi

echo "[build] tag=$TAG"
git fetch --depth 1 origin tag "$TAG"
git checkout -f "$TAG"

# Re-apply the packing-server patch (renderer fallback panel).
if git apply --whitespace=nowarn "$PATCH_DIR/portable-update.patch"; then
  cp "$PATCH_DIR/files/portable-updates.ts" apps/desktop/src/lib/
  cp "$PATCH_DIR/files/portable-update-panel.tsx" apps/desktop/src/app/
  echo "[build] portable patch applied"
else
  echo "[build] WARNING: portable patch failed to apply (upstream changed?)" >&2
fi

# Bake build identity + update-server origin into the bundle: package.json
# version is 0.0.0, so the panel compares against the tag constant instead.
cat > apps/desktop/src/lib/portable-build-tag.ts <<EOF
export const PORTABLE_BUILD_TAG = '$TAG'
export const PORTABLE_UPDATE_BASE = '$PACK_SERVER_BASE'
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
cat > "$ART/$TAG/manifest.json" <<EOF
{
  "tag": "$TAG",
  "version": "$APP_VERSION",
  "builtAt": "$(date -Iseconds)",
  "artifactUrl": "$PACK_SERVER_BASE/api/desktop-update/artifact?tag=$TAG"
}
EOF

echo "[build] done: $ART/$TAG/app.asar"
