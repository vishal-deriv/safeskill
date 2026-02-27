// safeskill-hook.js — SafeSkill interception layer for OpenClaw
//
// Loaded via NODE_OPTIONS=--require /path/to/safeskill-hook.js
// Runs before OpenClaw boots. Patches Node's child_process so every
// command the AI tries to execute is evaluated by SafeSkillAgent first.
//
// NO OpenClaw source code is modified. This is pure runtime interception.

'use strict';

const cp   = require('child_process');
const fs   = require('fs');
const path = require('path');

// ── Save ALL originals before any patching ───────────────────────────────────
const orig = {
  spawn:        cp.spawn.bind(cp),
  spawnSync:    cp.spawnSync.bind(cp),
  exec:         cp.exec.bind(cp),
  execSync:     cp.execSync.bind(cp),
  execFile:     cp.execFile.bind(cp),
  execFileSync: cp.execFileSync.bind(cp),
  fork:         cp.fork.bind(cp),
};

// ── Config ───────────────────────────────────────────────────────────────────
const SOCKET  = process.env.SAFESKILL_SOCKET     || '/var/run/safeskill/safeskill.sock';
const TOKFILE = process.env.SAFESKILL_TOKEN_FILE || '/var/run/safeskill/client.token';

// ── Helpers ──────────────────────────────────────────────────────────────────
function daemonUp() {
  try { fs.statSync(SOCKET); return true; } catch { return false; }
}

function getToken() {
  try { return fs.readFileSync(TOKFILE, 'utf8').trim(); } catch { return null; }
}

function toStr(cmd, args) {
  const parts = [cmd, ...(Array.isArray(args) ? args.map(String) : [])].filter(Boolean);
  return parts.join(' ');
}

// Extract cwd from any options-like object (checks multiple positions for execFile overloads)
function getCwd(...candidates) {
  for (const o of candidates) {
    if (o && typeof o === 'object' && !Array.isArray(o) && o.cwd) return o.cwd;
  }
  return null;
}

// ── Fast-pass: OpenClaw internal health-monitor commands ─────────────────────
// These are read-only system introspection calls OpenClaw runs every ~5–15s to
// monitor its own gateway process. They never originate from the AI and pose
// no security risk. Skipping the daemon entirely means: no curl, no audit
// log entry, no SIEM event — and zero latency overhead on gateway health checks.
const HEALTH_PREFIXES = [
  'sysctl -n hw.model',
  'sw_vers -productVersion',
  '/usr/sbin/lsof -nP -iTCP:',   // gateway port listener check
  'ps -p ',                       // gateway PID inspection
  'launchctl print gui/',         // launchd service status
  'arp -a -n -l',                 // network table check (~every 15s)
  '/usr/sbin/scutil --get',       // system hostname lookups
  'defaults read -g ',            // system locale/preference reads
];

function isHealthCheck(cmdStr) {
  return HEALTH_PREFIXES.some(function(p) { return cmdStr.startsWith(p); });
}

// ── Daemon query ─────────────────────────────────────────────────────────────
// Recursion guard — prevents the internal curl call from re-entering our hook
let _checking = false;

function queryDaemon(cmdStr, token) {
  _checking = true;
  try {
    const payload = JSON.stringify({ command: cmdStr, source: 'openclaw-hook' });
    const r = orig.spawnSync('curl', [
      '-sf', '--max-time', '2',
      '--unix-socket', SOCKET,
      'http://localhost/evaluate',
      '-H', 'Content-Type: application/json',
      '-H', 'X-SafeSkill-Token: ' + token,
      '-d', payload,
    ], { timeout: 3000, encoding: 'utf8' });

    if (r.status !== 0 || !r.stdout) return false; // fail-closed on curl error
    const result = JSON.parse(r.stdout);
    return result.blocked === false; // explicit false only — anything else is fail-closed
  } catch {
    return false; // fail-closed on any parse / runtime error
  } finally {
    _checking = false;
  }
}

// ── Script pre-flight ─────────────────────────────────────────────────────────
// When a shell script is about to be executed, read it first, extract all
// commands, and evaluate each against the daemon. If ANY command inside the
// script would be blocked — the whole script is blocked before it starts.
//
// Covers:
//   bash script.sh          → reads script.sh, evals every command
//   sh ./run.sh             → same
//   ./deploy.sh             → same (by path pattern)
//   /bin/zsh -c bash a.sh  → unwraps -c, then detects script
//   cmd1 && bash a.sh       → splits compound, detects script in each part
//   nested scripts          → recursive up to MAX_SCRIPT_DEPTH
//
// Limitation: dynamic scripts (variable-computed names, heredocs, curl|bash)
// and scripts sourced via `source`/`.` are not analysed — they fall through
// to normal daemon evaluation of the top-level command.

const SHELLS = new Set([
  'bash', 'sh', 'zsh', 'dash',
  '/bin/bash', '/bin/sh', '/bin/zsh', '/bin/dash',
  '/usr/bin/bash', '/usr/bin/sh', '/usr/bin/zsh',
  '/usr/local/bin/bash', '/usr/local/bin/zsh',
]);

// Shell structural keywords — skip these lines when parsing a script body
const SKIP_LINE_RE = /^(?:#|if[\s(]|then\b|else\b|elif[\s(]|fi\b|for[\s(]|while[\s(]|until[\s(]|do\b|done\b|case[\s(]|esac\b|\{|\}|function\s|return\b|local\s|declare\s|typeset\s|readonly\s|exit\b|\[\[|\[)/;
// Pure variable assignments: VAR=value  or  export VAR=value  (not ==)
const ASSIGN_LINE_RE = /^(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*=[^=]/;

// Depth guard — prevents infinite recursion on self-referencing scripts
let _scriptDepth = 0;
const MAX_SCRIPT_DEPTH = 3;

// Read a shell script and return its non-structural command lines.
// Returns [] for binaries (null-bytes), null if unreadable (caller fails-closed).
function extractScriptCommands(scriptPath) {
  let content;
  try { content = fs.readFileSync(scriptPath, 'utf8'); } catch { return null; }

  // Binary check — shell scripts never contain null bytes
  if (content.includes('\x00')) return [];

  const cmds = [];
  const lines = content.split('\n');
  let continuation = '';

  for (const raw of lines) {
    const trimmed = raw.trim();
    const current = continuation ? continuation + ' ' + trimmed : trimmed;

    if (current.endsWith('\\')) {
      // Line continuation — accumulate and keep going
      continuation = current.slice(0, -1).trimEnd();
      continue;
    }
    continuation = '';

    const full = current.trim();
    if (!full) continue;
    if (SKIP_LINE_RE.test(full)) continue;
    if (ASSIGN_LINE_RE.test(full)) continue;

    cmds.push(full);
  }

  return cmds;
}

// Resolve a raw script path (relative paths anchored to cwd or process.cwd())
// Returns the absolute path if the file is readable, null otherwise.
function resolveScript(rawPath, cwd) {
  // Only treat as a script if it looks like a path (not a flag or shell keyword)
  if (!rawPath || rawPath.startsWith('-')) return null;

  // Only proceed for explicit relative paths (./  ../) or .sh-suffixed names
  // This prevents treating /usr/bin/grep or other system binaries as scripts.
  const looksLikeScript =
    rawPath.startsWith('./') ||
    rawPath.startsWith('../') ||
    rawPath.endsWith('.sh');
  if (!looksLikeScript) return null;

  const resolved = path.isAbsolute(rawPath)
    ? rawPath
    : path.resolve(cwd || process.cwd(), rawPath);

  try { fs.accessSync(resolved, fs.constants.R_OK); return resolved; }
  catch { return null; }
}

// Evaluate all commands inside a script file against the daemon.
// Returns false (block) if any command is blocked or the file is unreadable.
function preflightScriptFile(scriptPath, cwd, token) {
  _scriptDepth++;
  try {
    const cmds = extractScriptCommands(scriptPath);
    if (cmds === null) return false; // unreadable — fail-closed

    for (const cmd of cmds) {
      if (isHealthCheck(cmd)) continue;
      // Evaluate this line against the daemon
      if (!queryDaemon(cmd, token)) return false;
      // If this line is itself a script execution, recurse
      if (_scriptDepth < MAX_SCRIPT_DEPTH) {
        if (!preflightTokens(cmd.split(/\s+/), cwd, token)) return false;
      }
    }
    return true;
  } finally {
    _scriptDepth--;
  }
}

// Split a shell command string on top-level compound operators (&& || ;)
// Note: does not handle pipes (|) as a separator — piped commands are a single unit.
function splitCompound(cmdStr) {
  return cmdStr
    .split(/\s*(?:&&|\|\||;)\s*/)
    .map(function(s) { return s.trim(); })
    .filter(Boolean);
}

// Pre-flight an inline command string (the content after `shell -c "..."`)
function preflightInline(inline, cwd, token) {
  const parts = splitCompound(inline);
  for (const part of parts) {
    if (!preflightTokens(part.split(/\s+/), cwd, token)) return false;
  }
  return true;
}

// Core dispatcher: given a tokenised command, detect and pre-flight any script.
// Returns true if safe (or not a script), false if any sub-command is blocked.
function preflightTokens(tokens, cwd, token) {
  if (!tokens || tokens.length === 0) return true;

  const cmd0 = tokens[0];

  // ── Case 1: shell -c "inline command" ───────────────────────────────────────
  // e.g. /bin/zsh -c bash a.sh > out.txt
  if (SHELLS.has(cmd0) && tokens[1] === '-c') {
    // Rejoin the remaining tokens as the inline string, strip outer quotes
    const inline = tokens.slice(2).join(' ').replace(/^["']|["']$/g, '');
    return preflightInline(inline, cwd, token);
  }

  // ── Case 2: shell [flags] scriptfile ────────────────────────────────────────
  // e.g. bash script.sh  /  sh -x ./run.sh
  if (SHELLS.has(cmd0)) {
    for (let i = 1; i < tokens.length; i++) {
      if (!tokens[i].startsWith('-')) {
        // First non-flag argument — check if it's a script file
        const scriptPath = resolveScript(tokens[i], cwd);
        if (scriptPath) return preflightScriptFile(scriptPath, cwd, token);
        break; // not a readable script — fall through to normal daemon eval
      }
    }
    return true;
  }

  // ── Case 3: ./script.sh or ../script.sh or plain-name.sh ────────────────────
  const scriptPath = resolveScript(cmd0, cwd);
  if (scriptPath) return preflightScriptFile(scriptPath, cwd, token);

  return true; // not a script execution — nothing extra to do
}

// ── isAllowed — main gate ─────────────────────────────────────────────────────
function isAllowed(cmdStr, cwd) {
  if (_checking) return true;
  if (isHealthCheck(cmdStr)) return true;
  if (!daemonUp()) return false;

  const token = getToken();
  if (!token) return false;

  // ── Script pre-flight ──────────────────────────────────────────────────────
  // Analyse any shell script that's about to run BEFORE it starts.
  // If any command inside the script would be blocked, block the whole script.
  if (!preflightTokens(cmdStr.split(/\s+/), cwd, token)) return false;

  // ── Normal daemon evaluation of the top-level command ─────────────────────
  return queryDaemon(cmdStr, token);
}

function deny(cmd) {
  const e = new Error('[SafeSkill] BLOCKED: ' + cmd);
  e.code  = 'EPERM';
  e.cmd   = cmd;
  return e;
}

// ── Patches ───────────────────────────────────────────────────────────────────

cp.spawn = function safeskillSpawn(command, args, options) {
  const cmd = toStr(command, args);
  if (!isAllowed(cmd, getCwd(options))) throw deny(cmd);
  return orig.spawn(command, args, options);
};

cp.spawnSync = function safeskillSpawnSync(command, args, options) {
  const cmd = toStr(command, args);
  if (!isAllowed(cmd, getCwd(options))) throw deny(cmd);
  return orig.spawnSync(command, args, options);
};

cp.exec = function safeskillExec(command, options, callback) {
  if (!isAllowed(command, getCwd(options))) {
    const e  = deny(command);
    const cb = typeof options === 'function' ? options
             : typeof callback === 'function' ? callback : null;
    if (cb) { setImmediate(function() { cb(e, '', ''); }); return null; }
    throw e;
  }
  return orig.exec(command, options, callback);
};

cp.execSync = function safeskillExecSync(command, options) {
  if (!isAllowed(command, getCwd(options))) throw deny(command);
  return orig.execSync(command, options);
};

cp.execFile = function safeskillExecFile(file, args, options, callback) {
  const cmd = toStr(file, Array.isArray(args) ? args : []);
  // execFile has optional args — options may be in the args position
  const cwd = getCwd(options, Array.isArray(args) ? null : args);
  if (!isAllowed(cmd, cwd)) {
    const e  = deny(cmd);
    const cb = typeof args     === 'function' ? args
             : typeof options  === 'function' ? options
             : typeof callback === 'function' ? callback : null;
    if (cb) { setImmediate(function() { cb(e, '', ''); }); return null; }
    throw e;
  }
  return orig.execFile(file, args, options, callback);
};

cp.execFileSync = function safeskillExecFileSync(file, args, options) {
  const cmd = toStr(file, args);
  if (!isAllowed(cmd, getCwd(options))) throw deny(cmd);
  return orig.execFileSync(file, args, options);
};

cp.fork = function safeskillFork(modulePath, args, options) {
  const cmd = 'node ' + modulePath;
  if (!isAllowed(cmd, getCwd(options))) throw deny(cmd);
  return orig.fork(modulePath, args, options);
};