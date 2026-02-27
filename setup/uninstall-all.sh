#!/usr/bin/env bash
# Remove SafeSkill and OpenClaw — runs both uninstall scripts.
# Usage: bash setup/uninstall-all.sh
# (SafeSkill part will prompt for sudo)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "=== Uninstalling SafeSkill + OpenClaw ==="
echo ""

echo ">> Running uninstall-safeskill.sh (requires sudo)..."
sudo bash "$SCRIPT_DIR/uninstall-safeskill.sh"

echo ""
echo ">> Running uninstall-openclaw.sh..."
bash "$SCRIPT_DIR/uninstall-openclaw.sh"

echo ""
echo "=== All uninstalled ==="
echo ""
