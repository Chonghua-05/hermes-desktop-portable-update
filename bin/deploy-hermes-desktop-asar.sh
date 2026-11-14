#!/usr/bin/env bash
# Deploy an app.asar to the Windows client: scp -> stop -> swap -> relaunch.
# Usage: deploy-hermes-desktop-asar.sh <tag>
#
# Config: sourced from $HERMES_PACK_CONFIG (default ~/.config/hermes-desktop-pack/config.env).
# Required: DEPLOY_HOST (ssh target), REMOTE_ASAR (destination path on Windows),
#           REMOTE_EXE (client executable path on Windows).
set -euo pipefail

CONFIG="${HERMES_PACK_CONFIG:-$HOME/.config/hermes-desktop-pack/config.env}"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

ART="${ART:-$HOME/hermes-desktop-artifacts}"
DEPLOY_HOST="${DEPLOY_HOST:?DEPLOY_HOST is required}"
REMOTE_ASAR="${REMOTE_ASAR:?REMOTE_ASAR is required}"
REMOTE_EXE="${REMOTE_EXE:?REMOTE_EXE is required}"
REMOTE_INCOMING="${REMOTE_INCOMING:-$(dirname "$REMOTE_ASAR")/app.asar.incoming}"
TASK_NAME="${TASK_NAME:-HermesAgentLaunch}"
WIN_PROCESS_NAME="${WIN_PROCESS_NAME:-Hermes Agent}"

TAG="$1"
[ -f "$ART/$TAG/app.asar" ] || { echo "[deploy] no artifact for $TAG" >&2; exit 1; }

echo "[deploy] scp $TAG/app.asar -> $DEPLOY_HOST"
scp -o ConnectTimeout=10 -q "$ART/$TAG/app.asar" "$DEPLOY_HOST:$REMOTE_INCOMING"

echo "[deploy] swap asar + relaunch"
SSH_CMDS=$(cat <<EOF
\$OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Get-Process -Name "$WIN_PROCESS_NAME" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Move-Item -LiteralPath "$REMOTE_INCOMING" -Destination "$REMOTE_ASAR" -Force
schtasks /Create /TN "$TASK_NAME" /TR "\\"$REMOTE_EXE\\"" /SC ONCE /ST 00:00 /IT /F | Out-Null
schtasks /Run /TN "$TASK_NAME" | Out-Null
Write-Output "deployed"
EOF
)
B64=$(printf '%s' "$SSH_CMDS" | iconv -f utf-8 -t utf-16le | base64 -w0)
ssh -o ConnectTimeout=10 "$DEPLOY_HOST" powershell -NoProfile -EncodedCommand "$B64"

echo "[deploy] done ($TAG)"
