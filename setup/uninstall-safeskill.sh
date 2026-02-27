#!/usr/bin/env bash
# Remove SafeSkill daemon completely — all traces.
# Requires sudo for system-level removal.
# Usage: sudo bash setup/uninstall-safeskill.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$REAL_USER")

echo ""
echo "=== Uninstalling SafeSkill ==="
echo ""

# 1. Stop daemon and unload LaunchDaemons
echo "[1] Stopping SafeSkill daemon..."
pkill -9 -f safeskill-agent 2>/dev/null || true
launchctl unload /Library/LaunchDaemons/com.safeskill.agent.plist 2>/dev/null || true
launchctl unload /Library/LaunchDaemons/com.safeskill.updater.plist 2>/dev/null || true
sleep 1
echo "    Done"

# 2. Remove LaunchDaemon plists
echo "[2] Removing LaunchDaemon plists..."
rm -f /Library/LaunchDaemons/com.safeskill.agent.plist
rm -f /Library/LaunchDaemons/com.safeskill.updater.plist
echo "    Done"

# 3. Remove binaries
echo "[3] Removing binaries..."
rm -f /usr/local/bin/safeskill-agent /usr/local/bin/safeskill
echo "    Done"

# 4. Remove directories
echo "[4] Removing SafeSkill directories..."
rm -rf /opt/safeskill /etc/safeskill /var/log/safeskill /var/run/safeskill
echo "    Done"

# 5. Remove user trap script (if in home)
echo "[5] Removing ~/.safeskill-trap.sh (if present)..."
rm -f "$USER_HOME/.safeskill-trap.sh"
echo "    Done"

echo ""
echo "=== SafeSkill uninstall complete ==="
echo ""
echo "Verify:"
echo "  ps aux | grep safeskill     # should show nothing"
echo "  ls /opt/safeskill 2>/dev/null || echo 'gone'"
echo "  ls /var/run/safeskill 2>/dev/null || echo 'gone'"
echo ""
