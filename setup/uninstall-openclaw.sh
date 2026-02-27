#!/usr/bin/env bash
# Remove OpenClaw completely — all traces.
# Run as your normal user (no sudo required).
# Usage: bash setup/uninstall-openclaw.sh

set -euo pipefail

echo ""
echo "=== Uninstalling OpenClaw ==="
echo ""

# 1. Stop gateway process and unload LaunchAgent
echo "[1] Stopping OpenClaw gateway..."
openclaw gateway stop 2>/dev/null || true
launchctl bootout "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || true
pkill -f openclaw 2>/dev/null || true
sleep 1
echo "    Done"

# 2. Remove workspace, config, and all OpenClaw data
echo "[2] Removing ~/.openclaw (workspace, config, agents, logs, etc.)..."
rm -rf "$HOME/.openclaw"
echo "    Done"

# 3. Remove LaunchAgent plist
echo "[3] Removing gateway LaunchAgent plist..."
rm -f "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
echo "    Done"

# 4. Uninstall npm global package
echo "[4] Uninstalling OpenClaw npm package..."
npm uninstall -g openclaw 2>/dev/null || true
echo "    Done"

# 5. Remove shell completion from .zshrc if present
echo "[5] Removing OpenClaw completion from .zshrc..."
if [[ -f "$HOME/.zshrc" ]] && grep -q "openclaw/completions" "$HOME/.zshrc" 2>/dev/null; then
    sed -i.bak '/openclaw\/completions/d' "$HOME/.zshrc"
    echo "    Removed completion line"
else
    echo "    None found"
fi

# 6. Remove SafeSkill trap from home (if installed there)
echo "[6] Removing ~/.safeskill-trap.sh (if present)..."
rm -f "$HOME/.safeskill-trap.sh"
echo "    Done"

echo ""
echo "=== OpenClaw uninstall complete ==="
echo ""
echo "Verify:"
echo "  ps aux | grep openclaw     # should show nothing"
echo "  ls ~/.openclaw 2>/dev/null || echo 'gone'"
echo "  which openclaw             # should show nothing"
echo ""
