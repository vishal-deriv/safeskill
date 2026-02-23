#!/usr/bin/env bash
set -euo pipefail

# SafeSkill OpenClaw Integration Installer
#
# Direct interception: BASH_ENV trap intercepts every command at the shell level.
# Blocked commands never run; the agent just sees [SafeSkill] BLOCKED.
# No MD files, no skill checks — the trap is the gate.
#
# Run as the same user that runs OpenClaw (NOT root).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
WORKSPACE="${OPENCLAW_WORKSPACE:-$OPENCLAW_HOME/workspace}"
TRAP_INSTALL_PATH="/opt/safeskill/safeskill-trap.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!!]${NC} $*"; }
log_error() { echo -e "${RED}[FAIL]${NC} $*"; }
log_step()  { echo -e "${CYAN}[>>]${NC} ${BOLD}$*${NC}"; }

# ================================================================
# LAYER 1: BASH_ENV TRAP (hard enforcement)
# ================================================================
install_trap() {
    log_step "Layer 1: Installing BASH_ENV trap..."

    local src="$SCRIPT_DIR/safeskill-trap.sh"
    if [[ ! -f "$src" ]]; then
        log_error "safeskill-trap.sh not found"
        return 1
    fi

    # Try /opt/safeskill first (requires sudo), fallback to home
    if sudo cp "$src" "$TRAP_INSTALL_PATH" 2>/dev/null; then
        sudo chmod 644 "$TRAP_INSTALL_PATH"
    elif [[ -w "$(dirname "$TRAP_INSTALL_PATH")" ]]; then
        cp "$src" "$TRAP_INSTALL_PATH"
        chmod 644 "$TRAP_INSTALL_PATH"
    else
        TRAP_INSTALL_PATH="$HOME/.safeskill-trap.sh"
        cp "$src" "$TRAP_INSTALL_PATH"
        chmod 644 "$TRAP_INSTALL_PATH"
        log_warn "Installed trap at $TRAP_INSTALL_PATH (no sudo access)"
    fi

    log_info "Trap script: $TRAP_INSTALL_PATH"

    # Quick test: does the trap work?
    local test_out
    test_out=$(BASH_ENV="$TRAP_INSTALL_PATH" SAFESKILL_SOCKET=/tmp/safeskill.sock \
        bash -c 'echo "trap-test-ok"' 2>/dev/null) || true

    if [[ "$test_out" == *"trap-test-ok"* ]]; then
        log_info "Trap test passed (safe commands pass through)"
    else
        log_warn "Trap test inconclusive — may still work with daemon running"
    fi
}

# ================================================================
# INJECT SECURITY INTO SOUL.MD (immutable, operator-controlled)
# ================================================================
inject_soul_security() {
    log_step "Injecting Security section into SOUL.md..."

    local soul_file="$WORKSPACE/SOUL.md"
    local inject_src="$SCRIPT_DIR/safeskill-soul-security.md"

    if [[ ! -f "$inject_src" ]]; then
        log_warn "safeskill-soul-security.md not found — skipping"
        return 0
    fi

    mkdir -p "$WORKSPACE"

    local security_block
    security_block=$(cat "$inject_src")

    if [[ -f "$soul_file" ]]; then
        if grep -q "SAFESKILL-SECURITY" "$soul_file" 2>/dev/null; then
            # Replace existing block with current version, keep at top
            awk '
                /<!-- SAFESKILL-SECURITY/{skip=1}
                /<!-- END SAFESKILL-SECURITY -->/{skip=0;next}
                !skip
            ' "$soul_file" > "${soul_file}.tmp"
            { cat "$inject_src"; echo ""; cat "${soul_file}.tmp"; } > "$soul_file"
            rm -f "${soul_file}.tmp"
            log_info "SOUL.md Security section updated (at start)"
        else
            # Inject at start — Security first
            { cat "$inject_src"; echo ""; cat "$soul_file"; } > "${soul_file}.tmp"
            mv "${soul_file}.tmp" "$soul_file"
            log_info "SOUL.md Security section added at start"
        fi
    else
        cat "$inject_src" > "$soul_file"
        echo "" >> "$soul_file"
        log_info "SOUL.md created with Security section at start"
    fi
}

# ================================================================
# INSTALL SKILL (optional — left for compatibility)
# ================================================================
install_skill() {
    log_step "Installing SafeSkill skill..."

    local skill_dir="$OPENCLAW_HOME/skills/safeskill"
    mkdir -p "$skill_dir"

    if [[ -f "$SCRIPT_DIR/SKILL.md" ]]; then
        cp "$SCRIPT_DIR/SKILL.md" "$skill_dir/SKILL.md"
        log_info "SKILL.md installed"
    fi

    # Copy wrapper scripts
    for f in safeskill-exec.sh safeskill-wrapper.sh safeskill-shell; do
        if [[ -f "$SCRIPT_DIR/$f" ]]; then
            cp "$SCRIPT_DIR/$f" "$skill_dir/$f"
            chmod +x "$skill_dir/$f"
        fi
    done
}

# ================================================================
# UPDATE SIEM METADATA (hostname, user, source_ip) - one-time at install
# ================================================================
update_siem_metadata() {
    log_step "Updating SIEM metadata (hostname, user, source_ip)..."

    local hname user ip
    hname=$(hostname 2>/dev/null || uname -n 2>/dev/null)
    user="${USER:-$(whoami 2>/dev/null)}"
    [[ -z "$user" ]] && user="unknown"
    ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
    [[ -z "$ip" ]] && ip="127.0.0.1"

    local agent_yaml="/etc/safeskill/agent.yaml"
    # Use sudo for read+write if file exists (root-owned)
    if sudo test -f "$agent_yaml" 2>/dev/null; then
        local tmp
        tmp=$(mktemp -t safeskill-agent.XXXXXX)
        {
            sudo cat "$agent_yaml" 2>/dev/null | grep -v '^default_hostname:\|^default_user:\|^default_source_ip:' || true
            echo "default_hostname: $hname"
            echo "default_user: $user"
            echo "default_source_ip: $ip"
        } > "$tmp"
        if sudo cp "$tmp" "$agent_yaml" 2>/dev/null; then
            sudo chmod 640 "$agent_yaml"
            log_info "SIEM metadata updated (hostname=$hname user=$user source_ip=$ip)"
            log_info "Restart SafeSkill daemon to apply metadata (e.g. launchctl kickstart -k system/com.safeskill.agent)"
        else
            log_warn "Could not write $agent_yaml"
        fi
        rm -f "$tmp"
    else
        log_warn "agent.yaml not found — run setup/install-macos.sh first for full SIEM metadata"
    fi
}

# ================================================================
# CONFIGURE GATEWAY ENVIRONMENT
# ================================================================
configure_gateway_env() {
    log_step "Configuring gateway environment..."

    # Method A: .env file
    local env_file="$OPENCLAW_HOME/.env"
    local env_lines=()
    if [[ -f "$env_file" ]]; then
        while IFS= read -r line; do
            [[ "$line" == BASH_ENV=* ]] && continue
            [[ "$line" == SAFESKILL_SOCKET=* ]] && continue
            [[ "$line" == _SAFESKILL_ACTIVE=* ]] && continue
            env_lines+=("$line")
        done < "$env_file"
    fi
    env_lines+=("BASH_ENV=$TRAP_INSTALL_PATH")
    env_lines+=("SAFESKILL_SOCKET=/tmp/safeskill.sock")
    printf '%s\n' "${env_lines[@]}" > "$env_file"
    log_info ".env updated: BASH_ENV=$TRAP_INSTALL_PATH"

    # Method B: openclaw.json env block
    local config_file="$OPENCLAW_HOME/openclaw.json"
    python3 -c "
import json, os
p = '${config_file}'
c = {}
if os.path.exists(p):
    try:
        with open(p) as f: c = json.load(f)
    except: pass
e = c.setdefault('env', {})
e['BASH_ENV'] = '${TRAP_INSTALL_PATH}'
e['SAFESKILL_SOCKET'] = '/tmp/safeskill.sock'
with open(p, 'w') as f: json.dump(c, f, indent=2)
print('openclaw.json updated')
" 2>/dev/null && log_info "openclaw.json env block updated" || log_warn "Could not update openclaw.json"

    # Method C: Create gateway launcher
    local launcher="$OPENCLAW_HOME/start-safeskill-gateway.sh"
    cat > "$launcher" << LAUNCHER
#!/usr/bin/env bash
# Start OpenClaw gateway with SafeSkill enforcement
export BASH_ENV="$TRAP_INSTALL_PATH"
export SAFESKILL_SOCKET="/tmp/safeskill.sock"
exec openclaw gateway "\$@"
LAUNCHER
    chmod +x "$launcher"
    log_info "Gateway launcher: $launcher"

    # Method D: systemd user service override (if gateway runs as service)
    local uid
    uid=$(id -u 2>/dev/null) || true
    local xdg="/run/user/$uid"
    if [[ -d "$xdg" ]] && command -v systemctl &>/dev/null; then
        (
            export XDG_RUNTIME_DIR="$xdg"
            systemctl --user set-environment BASH_ENV="$TRAP_INSTALL_PATH" 2>/dev/null && \
                log_info "systemd user env: BASH_ENV set" || true
            systemctl --user set-environment SAFESKILL_SOCKET="/tmp/safeskill.sock" 2>/dev/null || true
        )
    fi

    # Method E: Patch LaunchAgent plist directly (CRITICAL for interception)
    # OpenClaw's gateway install may overwrite plist without env vars. We patch it.
    patch_gateway_plist
}

# ================================================================
# PATCH GATEWAY PLIST (ensures BASH_ENV in LaunchAgent env)
# ================================================================
patch_gateway_plist() {
    local plist="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
    if [[ ! -f "$plist" ]]; then
        log_warn "Gateway plist not found — run 'openclaw gateway install' first, then re-run this script"
        return 0
    fi

    python3 << PYEOF
import plistlib
import sys
plist_path = "$plist"
trap_path = "$TRAP_INSTALL_PATH"
try:
    with open(plist_path, "rb") as f:
        plist = plistlib.load(f)
    env = plist.get("EnvironmentVariables")
    if env is None:
        env = {}
    elif hasattr(env, "__iter__") and not isinstance(env, dict):
        env = dict(env)
    env["BASH_ENV"] = trap_path
    env["SAFESKILL_SOCKET"] = "/tmp/safeskill.sock"
    plist["EnvironmentVariables"] = env
    with open(plist_path, "wb") as f:
        plistlib.dump(plist, f)
    print("PATCHED")
except Exception as e:
    sys.stderr.write(f"Plist patch failed: {e}\n")
    sys.exit(1)
PYEOF

    if [[ $? -eq 0 ]]; then
        log_info "Gateway plist patched: BASH_ENV and SAFESKILL_SOCKET set"
        log_info "Restart gateway to apply: openclaw gateway stop && openclaw gateway start"
    else
        log_warn "Could not patch gateway plist — use launcher: $OPENCLAW_HOME/start-safeskill-gateway.sh start"
    fi
}

# ================================================================
# VERIFY
# ================================================================
verify() {
    log_step "Verifying installation..."

    local ok=true

    # Check daemon
    if [[ -S "/tmp/safeskill.sock" ]]; then
        local health
        health=$(curl -sf --max-time 2 --unix-socket /tmp/safeskill.sock http://localhost/health 2>/dev/null) || true
        if echo "$health" | grep -q "healthy" 2>/dev/null; then
            log_info "SafeSkillAgent daemon: RUNNING"
        else
            log_warn "SafeSkillAgent daemon: socket exists but not healthy"
        fi
    else
        log_error "SafeSkillAgent daemon: NOT RUNNING"
        echo "       Start it:  safeskill start --config-dir /etc/safeskill --log-dir /var/log/safeskill"
        ok=false
    fi

    # Check trap
    if [[ -f "$TRAP_INSTALL_PATH" ]]; then
        log_info "BASH_ENV trap: $TRAP_INSTALL_PATH"
    else
        log_error "BASH_ENV trap: MISSING"
        ok=false
    fi

    # Check SOUL.md Security section
    if [[ -f "$WORKSPACE/SOUL.md" ]] && grep -q "SAFESKILL-SECURITY" "$WORKSPACE/SOUL.md" 2>/dev/null; then
        log_info "SOUL.md Security section: injected"
    else
        log_error "SOUL.md Security section: MISSING"
        ok=false
    fi

    # Check socket permissions
    if [[ -S "/tmp/safeskill.sock" ]]; then
        local perms
        perms=$(stat -c "%a" /tmp/safeskill.sock 2>/dev/null || stat -f "%Lp" /tmp/safeskill.sock 2>/dev/null || echo "?")
        if [[ "$perms" == "666" ]]; then
            log_info "Socket permissions: 666 (non-root can connect)"
        else
            log_warn "Socket permissions: $perms (may need: sudo chmod 666 /tmp/safeskill.sock)"
        fi
    fi

    echo ""
    if [[ "$ok" == true ]]; then
        log_info "All checks passed"
    else
        log_error "Some checks failed — see above"
    fi
}

# ================================================================
# MAIN
# ================================================================
main() {
    echo ""
    echo "============================================"
    echo "  SafeSkill OpenClaw Integration"
    echo "============================================"
    echo ""
    echo "  Direct interception via BASH_ENV trap"
    echo ""
    echo "  OpenClaw home: $OPENCLAW_HOME"
    echo "  Workspace:     $WORKSPACE"
    echo ""

    install_trap
    echo ""
    inject_soul_security
    echo ""
    update_siem_metadata
    echo ""
    install_skill
    echo ""
    configure_gateway_env
    echo ""
    verify

    echo ""
    echo "============================================"
    echo ""
    echo "  ${BOLD}TO ACTIVATE:${NC}"
    echo ""
    echo "  Option A (recommended — guaranteed to work):"
    echo "    openclaw gateway stop"
    echo "    BASH_ENV=$TRAP_INSTALL_PATH openclaw gateway start"
    echo ""
    echo "  Option B (use the launcher):"
    echo "    openclaw gateway stop"
    echo "    $OPENCLAW_HOME/start-safeskill-gateway.sh start"
    echo ""
    echo "  Option C (if gateway runs via systemd --user):"
    echo "    systemctl --user restart openclaw-gateway"
    echo ""
    echo "  Then start TUI:  openclaw tui"
    echo ""
    echo "  ${BOLD}VERIFY INTERCEPTION:${NC}"
    echo "    ./openclaw-skill/verify-interception.sh"
    echo ""
    echo "  ${BOLD}TEST IN TUI:${NC}"
    echo "    Tell OpenClaw: \"run rm -rf /\" or \"run cat /etc/passwd\""
    echo "    Blocked commands → [SafeSkill] BLOCKED (never runs)"
    echo ""
    echo "  ${BOLD}WATCH COMMANDS IN LOG:${NC}"
    echo "    sudo tail -f /var/log/safeskill/audit-\$(date +%Y-%m-%d).jsonl | grep evaluate"
    echo ""
    echo "============================================"
    echo ""
}

main "$@"
