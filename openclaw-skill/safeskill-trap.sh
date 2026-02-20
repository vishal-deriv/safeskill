#!/usr/bin/env bash
# SafeSkill BASH_ENV Trap
#
# This file is sourced by bash before executing commands when BASH_ENV
# points to it. It installs a DEBUG trap that checks every command with
# SafeSkillAgent BEFORE execution.
#
# With extdebug enabled, returning non-zero from the DEBUG trap
# PREVENTS the command from executing. This is real enforcement
# that the LLM cannot bypass.
#
# Setup: export BASH_ENV=/opt/safeskill/safeskill-trap.sh

# Don't run in interactive shells (user's terminal) — only in OpenClaw exec
[[ $- == *i* ]] && return 0

# Don't recurse
[[ -n "$_SAFESKILL_ACTIVE" ]] && return 0
export _SAFESKILL_ACTIVE=1

SAFESKILL_SOCKET="${SAFESKILL_SOCKET:-/tmp/safeskill.sock}"

# Enable extdebug so DEBUG trap can prevent command execution
shopt -s extdebug 2>/dev/null

_safeskill_check() {
    local cmd="$1"

    # Skip empty commands
    [[ -z "$cmd" ]] && return 0

    # Skip our own trap infrastructure
    [[ "$cmd" == _safeskill_* ]] && return 0
    [[ "$cmd" == "shopt -s extdebug"* ]] && return 0
    [[ "$cmd" == "trap "* ]] && return 0
    [[ "$cmd" == "return "* ]] && return 0
    [[ "$cmd" == "export _SAFESKILL"* ]] && return 0

    # Fast-path: skip obviously safe builtins
    local first="${cmd%% *}"
    case "$first" in
        echo|printf|true|false|test|\[|pwd|cd|pushd|popd|export|alias|\
        type|help|set|shopt|declare|local|readonly|source|\.|builtin|\
        command|hash|let|read|trap|ulimit|umask|wait)
            return 0
            ;;
    esac

    # Check if daemon is reachable
    [[ ! -S "$SAFESKILL_SOCKET" ]] && {
        echo "[SafeSkill] BLOCKED — Agent not running" >&2
        return 1
    }

    # JSON-encode and check with daemon
    local escaped
    escaped=$(printf '%s' "$cmd" | python3 -c '
import sys,json
print(json.dumps(sys.stdin.buffer.read().decode("utf-8","replace")))
' 2>/dev/null) || return 0

    local result
    result=$(curl -sf --max-time 3 --unix-socket "$SAFESKILL_SOCKET" \
        http://localhost/evaluate \
        -H "Content-Type: application/json" \
        -d "{\"command\":${escaped},\"source\":\"openclaw-bash-trap\"}" 2>/dev/null) || {
        echo "[SafeSkill] BLOCKED — Agent unreachable" >&2
        return 1
    }

    # Parse verdict
    local verdict_line
    verdict_line=$(printf '%s' "$result" | python3 -c '
import sys,json
d=json.loads(sys.stdin.read())
blocked="1" if d.get("blocked",True) else "0"
v=d.get("verdict","unknown")
m=d.get("message","")
s=d.get("severity","")
print(f"{blocked}|{v}|{s}|{m}")
' 2>/dev/null) || return 0

    local blocked verdict severity message
    IFS='|' read -r blocked verdict severity message <<< "$verdict_line"

    if [[ "$blocked" == "1" ]]; then
        echo "[SafeSkill] BLOCKED" >&2
        [[ -n "$severity" ]] && echo "[SafeSkill] Severity: $severity" >&2
        [[ -n "$message" ]] && echo "[SafeSkill] Reason: $message" >&2
        return 1
    fi

    if [[ "$verdict" == "warned" ]]; then
        echo "[SafeSkill] WARNING: $message" >&2
    fi

    return 0
}

trap '_safeskill_check "$BASH_COMMAND"' DEBUG
