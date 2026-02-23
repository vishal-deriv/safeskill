#!/usr/bin/env bash
# SafeSkill Interception Verification Script
#
# Runs test commands through the trap and verifies they appear in the audit log.
# Use this to triple-check that commands are being intercepted and logged.

set -euo pipefail

TRAP_PATH="${SAFESKILL_TRAP:-/opt/safeskill/safeskill-trap.sh}"
SOCKET="${SAFESKILL_SOCKET:-/tmp/safeskill.sock}"
LOG_DIR="${SAFESKILL_LOG_DIR:-/var/log/safeskill}"
AUDIT_FILE="$LOG_DIR/audit-$(date +%Y-%m-%d).jsonl"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass()  { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
step()  { echo -e "${CYAN}[>>]${NC} ${BOLD}$*${NC}"; }

echo ""
echo "============================================"
echo "  SafeSkill Interception Verification"
echo "============================================"
echo ""

# 1. Daemon and socket
step "1. Checking daemon and socket..."
if [[ ! -S "$SOCKET" ]]; then
    fail "Socket not found: $SOCKET (daemon not running?)"
    echo "   Start: sudo launchctl load -w /Library/LaunchDaemons/com.safeskill.agent.plist"
    exit 1
fi
pass "Socket exists: $SOCKET"

if ! curl -sf --max-time 2 --unix-socket "$SOCKET" http://localhost/health 2>/dev/null | grep -q healthy; then
    fail "Daemon not healthy"
    exit 1
fi
pass "Daemon healthy"

# 2. Trap script
step "2. Checking trap script..."
if [[ ! -f "$TRAP_PATH" ]]; then
    fail "Trap not found: $TRAP_PATH"
    echo "   Run: ./openclaw-skill/install.sh"
    exit 1
fi
pass "Trap exists: $TRAP_PATH"

# 3. Run a unique test command through the trap (must NOT be fast-path so daemon sees it)
step "3. Running test command through trap..."
UNIQUE_ID="safeskill-verify-$(date +%s)"
UNIQUE_CMD="python3 -c \"print('$UNIQUE_ID')\""
OUT=$(BASH_ENV="$TRAP_PATH" SAFESKILL_SOCKET="$SOCKET" bash -c "$UNIQUE_CMD" 2>&1) || true

if [[ "$OUT" != *"$UNIQUE_ID"* ]]; then
    fail "Trap test failed — command output: $OUT"
    exit 1
fi
pass "Trap allowed command (daemon evaluated)"

# 4. Check audit log for evaluate event (log dir is root-owned, use sudo)
step "4. Checking audit log for evaluate event..."
# Daemon uses UTC for filename; try local date first, then UTC
AUDIT_FILE="$LOG_DIR/audit-$(date +%Y-%m-%d).jsonl"
if ! sudo test -f "$AUDIT_FILE" 2>/dev/null; then
    AUDIT_FILE="$LOG_DIR/audit-$(date -u +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d).jsonl"
fi
if ! sudo test -f "$AUDIT_FILE" 2>/dev/null; then
    fail "Audit file not found in $LOG_DIR"
    echo "   (Sudo required for log access; daemon may not have written yet)"
    exit 1
fi

# Get last few lines (in case of buffering)
LAST_LINES=$(sudo tail -20 "$AUDIT_FILE" 2>/dev/null || true)
if ! echo "$LAST_LINES" | grep -q "event_action.*evaluate"; then
    fail "No evaluate events in audit log!"
    echo ""
    echo "   Last audit entries:"
    echo "$LAST_LINES" | tail -5 | while read -r line; do echo "   $line"; done
    echo ""
    echo "   This usually means:"
    echo "   - Gateway plist does NOT have BASH_ENV (run install.sh to patch it)"
    echo "   - Gateway was not restarted after install"
    echo "   - OpenClaw runs commands on a different host (node/sandbox)"
    exit 1
fi

# Check for our specific command (python3 -c "print('safeskill-verify-...')")
if ! echo "$LAST_LINES" | grep -q "safeskill-verify-"; then
    warn "Evaluate events exist but our test command not found in last 20 lines"
    warn "Commands may be logged with a short delay. Check: sudo tail -f $AUDIT_FILE"
else
    pass "Test command found in audit log (event_action=evaluate)"
fi

# 5. Test blocked command
step "5. Testing blocked command (cat /etc/passwd)..."
BLOCK_OUT=$(BASH_ENV="$TRAP_PATH" SAFESKILL_SOCKET="$SOCKET" bash -c 'cat /etc/passwd' 2>&1) || true
if echo "$BLOCK_OUT" | grep -q "\[SafeSkill\] BLOCKED"; then
    pass "Blocked command correctly blocked"
else
    warn "Expected [SafeSkill] BLOCKED for cat /etc/passwd"
    echo "   Output: $BLOCK_OUT"
fi

# 6. Summary
echo ""
echo "============================================"
step "Summary"
echo "  - Daemon: running"
echo "  - Trap: working"
echo "  - Audit log: $AUDIT_FILE"
echo ""
echo "  To watch commands in real time:"
echo "    sudo tail -f $AUDIT_FILE"
echo ""
echo "  Filter for evaluate events only:"
echo "    sudo tail -f $AUDIT_FILE | grep evaluate"
echo ""
echo "  Ensure gateway has BASH_ENV: run ./openclaw-skill/install.sh"
echo "  Then restart: openclaw gateway stop && openclaw gateway start"
echo "============================================"
echo ""
