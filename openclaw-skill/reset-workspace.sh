#!/usr/bin/env bash
# Reset OpenClaw workspace to fresh defaults, then re-inject SafeSkill Security at start.
# Removes: SafeSkill injections, test scripts, sessions. Restores default templates.

set -euo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
WORKSPACE="${WORKSPACE:-$OPENCLAW_HOME/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# OpenClaw default templates (strip frontmatter)
OC_BIN="$(command -v openclaw 2>/dev/null)"
OC_NODE=""
if [[ -n "$OC_BIN" ]]; then
    OC_DIR="$(cd "$(dirname "$OC_BIN")/../lib/node_modules/openclaw" 2>/dev/null && pwd)"
    [[ -d "$OC_DIR" ]] && OC_NODE="$OC_DIR"
fi
if [[ -z "$OC_NODE" ]]; then
    OC_NODE="${HOME}/.nvm/versions/node/$(ls "${HOME}/.nvm/versions/node" 2>/dev/null | tail -1)/lib/node_modules/openclaw"
fi
OC_TEMPLATES="${OC_NODE}/docs/reference/templates"
if [[ ! -d "$OC_TEMPLATES" ]]; then
    OC_TEMPLATES=""
fi

strip_frontmatter() {
    awk '/^---$/{if(++c==2)next} c==1{next} 1'
}

reset_workspace() {
    echo "[reset] Backing up workspace to ${WORKSPACE}.bak.$(date +%s)"
    cp -a "$WORKSPACE" "${WORKSPACE}.bak.$(date +%s)" 2>/dev/null || true

    mkdir -p "$WORKSPACE"

    if [[ -d "$OC_TEMPLATES" ]]; then
        echo "[reset] Restoring default templates from OpenClaw..."
        for f in BOOTSTRAP.md AGENTS.md SOUL.md IDENTITY.md USER.md TOOLS.md HEARTBEAT.md; do
            if [[ -f "$OC_TEMPLATES/$f" ]]; then
                strip_frontmatter < "$OC_TEMPLATES/$f" > "$WORKSPACE/$f"
            fi
        done
    else
        echo "[reset] OpenClaw templates not found — creating minimal defaults..."
        cat > "$WORKSPACE/BOOTSTRAP.md" << 'BOOT'
# BOOTSTRAP.md - Hello, World
_You just woke up. Start with: "Hey. Who am I? Who are you?"_
BOOT
        cat > "$WORKSPACE/SOUL.md" << 'SOUL'
# SOUL.md - Who You Are
_You're not a chatbot. Be genuinely helpful. Have opinions. Be resourceful._
SOUL
        cat > "$WORKSPACE/AGENTS.md" << 'AGENTS'
# AGENTS.md - Your Workspace
Read SOUL.md, USER.md. Don't exfiltrate private data. trash > rm.
AGENTS
        touch "$WORKSPACE/IDENTITY.md" "$WORKSPACE/USER.md" "$WORKSPACE/TOOLS.md" "$WORKSPACE/HEARTBEAT.md"
    fi

    # Remove non-default
    rm -f "$WORKSPACE/test-script.sh"
    rm -rf "$WORKSPACE/.pi"

    # Clear sessions (optional — agent memory)
    rm -rf "$OPENCLAW_HOME/agents/main/sessions"/* 2>/dev/null || true
    mkdir -p "$OPENCLAW_HOME/agents/main/sessions"

    echo "[reset] Workspace reset. Re-injecting SafeSkill Security..."
    bash "$SCRIPT_DIR/install.sh"
}

echo ""
echo "=== Reset OpenClaw Workspace ==="
echo "  Workspace: $WORKSPACE"
echo "  Config:    $OPENCLAW_HOME/openclaw.json"
echo ""
read -rp "Proceed? [y/N] " r
[[ "${r,,}" == "y" ]] && reset_workspace || echo "Aborted."
echo ""
