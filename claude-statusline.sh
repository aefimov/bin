#!/usr/bin/env node
const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const REPOSITORY_LIMITS_STATE_DIR = path.join(os.homedir(), '.claude', 'repository-limits');
const REPOSITORY_LIMITS_CONFIG_PATH = path.join(os.homedir(), '.claude', 'repository-limits-config.json');

const PRICE = {
    input: 3.0 / 1e6,
    output: 15.0 / 1e6,
    cacheRead: 0.30 / 1e6,
    cacheWrite: 3.75 / 1e6,
};

function formatTokens(n) {
    if (n >= 1_000_000) return `${Math.round(n / 1_000_000)}M`;
    if (n >= 1000) return `${Math.round(n / 1000)}K`;
    return `${n}`;
}

function visLen(s) {
    const plain = s.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
    let w = 0;
    for (const c of [...plain]) {
        const cp = c.codePointAt(0);
        if (cp === 0x200D) continue;          // ZWJ
        if (cp === 0xFE0F) { w++; continue; } // emoji variation selector
        w += cp >= 0x1F000 ? 2 : 1;
    }
    return w;
}
function padVis(s, w) { return s + ' '.repeat(Math.max(0, w - visLen(s))); }

function formatDuration(ms) {
    const s = Math.floor(ms / 1000);
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    if (d > 0) return h ? `${d}d${h}h` : `${d}d`;
    if (h > 0) return m ? `${h}h${m}m` : `${h}h`;
    return sec ? `${m}m${sec}s` : `${m}m`;
}

const DAY_MS = 24 * 3600 * 1000;

function getSessionWallClockMs(transcriptPath) {
    try {
        for (const line of fs.readFileSync(transcriptPath, 'utf8').split('\n')) {
            try { const e = JSON.parse(line); if (e.timestamp) return Date.now() - new Date(e.timestamp).getTime(); } catch {}
        }
    } catch {}
    return null;
}

// Wall-clock since the first entry within the last 24h window.
function getTodayWallClockMs(transcriptPaths) {
    const cutoff = Date.now() - DAY_MS;
    let earliest = null;
    for (const tp of transcriptPaths) {
        try {
            for (const line of fs.readFileSync(tp, 'utf8').split('\n')) {
                try {
                    const e = JSON.parse(line);
                    if (!e.timestamp) continue;
                    const ts = new Date(e.timestamp).getTime();
                    if (ts < cutoff) continue;
                    if (earliest === null || ts < earliest) earliest = ts;
                    break;
                } catch {}
            }
        } catch {}
    }
    return earliest !== null ? Date.now() - earliest : 0;
}

// Thinking time = user→first_assistant timestamp delta, optionally filtered by cutoff.
function getThinkingMs(transcriptPaths, cutoff = 0) {
    let total = 0;
    for (const tp of transcriptPaths) {
        try {
            let lastUserTs = null;
            for (const line of fs.readFileSync(tp, 'utf8').split('\n')) {
                try {
                    const e = JSON.parse(line);
                    if (!e.timestamp) continue;
                    const ts = new Date(e.timestamp).getTime();
                    if (ts < cutoff) continue;
                    if (e.type === 'user' || e.type === 'human') {
                        lastUserTs = ts;
                    } else if (e.type === 'assistant' && e.apiBlockIndex === 0 && lastUserTs !== null) {
                        total += ts - lastUserTs;
                        lastUserTs = null;
                    }
                } catch {}
            }
        } catch {}
    }
    return total;
}

function getSessionTotalStats(transcriptPath) {
    let tokens = 0, cost = 0;
    try {
        for (const line of fs.readFileSync(transcriptPath, 'utf8').split('\n')) {
            try {
                const u = JSON.parse(line)?.message?.usage;
                if (!u) continue;
                const inp = u.input_tokens || 0;
                const out = u.output_tokens || 0;
                const cr = u.cache_read_input_tokens || 0;
                const cw = u.cache_creation_input_tokens || 0;
                tokens += inp + out + cr + cw;
                cost += inp * PRICE.input + out * PRICE.output + cr * PRICE.cacheRead + cw * PRICE.cacheWrite;
            } catch {}
        }
    } catch {}
    return { tokens, cost };
}

// Token/cost totals for entries within the last 24h window.
function getTodayStats(transcriptPaths) {
    const cutoff = Date.now() - DAY_MS;
    let tokens = 0, cost = 0;
    for (const tp of transcriptPaths) {
        try {
            for (const line of fs.readFileSync(tp, 'utf8').split('\n')) {
                try {
                    const e = JSON.parse(line);
                    if (!e.timestamp) continue;
                    if (new Date(e.timestamp).getTime() < cutoff) continue;
                    const u = e?.message?.usage;
                    if (!u) continue;
                    const inp = u.input_tokens || 0;
                    const out = u.output_tokens || 0;
                    const cr = u.cache_read_input_tokens || 0;
                    const cw = u.cache_creation_input_tokens || 0;
                    tokens += inp + out + cr + cw;
                    cost += inp * PRICE.input + out * PRICE.output + cr * PRICE.cacheRead + cw * PRICE.cacheWrite;
                } catch {}
            }
        } catch {}
    }
    return { tokens, cost };
}

function getLastOpStats(transcriptPath) {
    try {
        let opIndex = 0, lastStats = null;
        for (const line of fs.readFileSync(transcriptPath, 'utf8').trimEnd().split('\n')) {
            try {
                const e = JSON.parse(line);
                const u = e?.message?.usage;
                if (!u) continue;
                const input = u.input_tokens || 0;
                const output = u.output_tokens || 0;
                const cacheRead = u.cache_read_input_tokens || 0;
                const cacheWrite = u.cache_creation_input_tokens || 0;
                const tokens = input + output + cacheRead + cacheWrite;
                if (tokens === 0) continue;
                opIndex++;
                const cost = input * PRICE.input + output * PRICE.output
                    + cacheRead * PRICE.cacheRead + cacheWrite * PRICE.cacheWrite;
                lastStats = { tokens, cost, opIndex };
            } catch {}
        }
        return lastStats;
    } catch {}
    return null;
}

function loadRepositoryLimitsConfig() {
    try { return JSON.parse(fs.readFileSync(REPOSITORY_LIMITS_CONFIG_PATH, 'utf8')); }
    catch { return { repos: {} }; }
}

function getOrgRepo(repoData) {
    try {
        if (repoData?.owner && repoData?.name) return [repoData.owner, repoData.name];
        const url = execSync('git remote get-url origin', { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] }).trim();
        const m = url.match(/[:/]([^/:]+)\/([^/]+?)(\.git)?\/?$/);
        if (m) return [m[1], m[2]];
    } catch {}
    return [null, null];
}

function loadRepositoryLimitsState(org, repo) {
    const day = new Date().toISOString().slice(0, 10);
    const safe = `${org}__${repo}`.toLowerCase().replace(/[^a-z0-9_.-]/g, '_');
    const file = path.join(REPOSITORY_LIMITS_STATE_DIR, `${safe}__${day}.json`);
    try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
    catch { return { tokens_used: 0, cost_usd: 0 }; }
}

// Returns limit data for the current repo, or null if no limits are configured.
function repositoryLimitsData(repoData) {
    const [org, repo] = getOrgRepo(repoData);
    if (!org || !repo) return null;
    const config = loadRepositoryLimitsConfig();
    const key = `${org}/${repo}`.toLowerCase();
    const repoConfig = (config.repos || {})[key];
    if (!repoConfig || !repoConfig.daily_token_cap) return null;
    const state = loadRepositoryLimitsState(org, repo);
    return {
        tokensUsed: state.tokens_used || 0,
        costUsed: state.cost_usd || 0,
        tokenCap: repoConfig.daily_token_cap + (state.extra_token_cap || 0),
        transcriptPaths: Object.keys(state.transcript_offsets || {}),
    };
}

let input = '';
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
    const data = JSON.parse(input);
    const model = data.model.display_name;
    const cwd = data.workspace?.current_dir || '';
    const dir = path.basename(cwd);
    const sessionName = data.session_name || null;
    const transcriptPath = data.transcript_path || null;
    const sessionCost = data.cost?.total_cost_usd || 0;
    const pct = Math.floor(data.context_window?.used_percentage || 0);
    const ctxTotal = data.context_window?.context_window_size || 0;
    const durationMs = data.cost?.total_duration_ms || 0;

    const CYAN = '\x1b[36m', GREEN = '\x1b[32m', YELLOW = '\x1b[33m', RED = '\x1b[31m', RESET = '\x1b[0m';
    const LIGHT_GREEN = '\x1b[92m', DIM = '\x1b[90m';
    const CC = '🦀';

    // ── Line 1: [model] 📁 dir | 🌿 branch ──────────────────────────────────
    let branch = '';
    try {
        branch = execSync('git branch --show-current', { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] }).trim();
        branch = branch ? ` | 🌿 ${branch}` : '';
    } catch {}
    console.log(`${CYAN}[${model}]${RESET} 📁 ${dir}${branch}`);

    // ── Lines 2–3: tabular ───────────────────────────────────────────────────
    const SEP = ' | ';
    const barColor = pct >= 90 ? RED : pct >= 70 ? YELLOW : GREEN;
    const bar = '█'.repeat(Math.floor(pct / 10)) + '░'.repeat(10 - Math.floor(pct / 10));

    const sessionTotal  = transcriptPath ? getSessionTotalStats(transcriptPath) : null;
    const lastOp        = transcriptPath ? getLastOpStats(transcriptPath) : null;
    const wallClockMs   = transcriptPath ? (getSessionWallClockMs(transcriptPath) ?? durationMs) : durationMs;
    const sessionThinkMs = transcriptPath ? getThinkingMs([transcriptPath]) : 0;
    const bolt          = repositoryLimitsData(data.workspace?.repo);

    // Show a slim 24h line when no limits are configured but session spans >1 day.
    const showSlim = !bolt && wallClockMs > DAY_MS;

    // Transcript paths for 24h aggregation.
    const tPaths24 = bolt?.transcriptPaths?.length
        ? bolt.transcriptPaths
        : (transcriptPath ? [transcriptPath] : []);

    const need24 = bolt || showSlim;
    const wallClock24   = need24 ? getTodayWallClockMs(tPaths24) : 0;
    const todayThinkMs  = need24 ? getThinkingMs(tPaths24, Date.now() - DAY_MS) : 0;
    const today24Stats  = showSlim ? getTodayStats(tPaths24) : null;

    // — Segment A2: context bar —
    const sA2 = `${barColor}${bar}${RESET} ${ctxTotal ? `${pct}%/✦${formatTokens(ctxTotal)}` : `${pct}%`}`;

    // — Segment B2: session tokens/cost —
    const sB2 = sessionTotal?.tokens > 0
        ? `✦${formatTokens(sessionTotal.tokens)}/${YELLOW}$${sessionTotal.cost.toFixed(2)}${RESET}`
        : `${YELLOW}$${sessionCost.toFixed(2)}${RESET}`;

    // — Segment C2: last op —
    const sC2 = lastOp
        ? `${DIM}💬${lastOp.opIndex}${RESET} ${LIGHT_GREEN}↑${RESET}✦${formatTokens(lastOp.tokens)} ${YELLOW}$${lastOp.cost.toFixed(3)}${RESET}`
        : '';

    // — Segment D2: session timing —
    const sD2 = sessionThinkMs > 0
        ? `${CC}${formatDuration(sessionThinkMs)}/⏱️${formatDuration(wallClockMs)}`
        : `⏱️${formatDuration(wallClockMs)}`;

    // — Segment E2: session name —
    const sE2 = sessionName ? `🎯${DIM}${sessionName}${RESET}` : '';

    if (!need24) {
        // Single line only.
        const parts = [sA2, sB2];
        if (sC2) parts.push(sC2);
        parts.push(sD2);
        if (sE2) parts.push(sE2);
        console.log(parts.join(SEP));
        return;
    }

    // — Line 3 segments —
    let sA3, sB3, sD3, sE3;

    if (bolt) {
        const limitExceeded = bolt.tokensUsed >= bolt.tokenCap;
        const tokenPct  = Math.min(100, Math.floor((bolt.tokensUsed / bolt.tokenCap) * 100));
        const barColor3 = tokenPct >= 90 ? RED : tokenPct >= 70 ? YELLOW : GREEN;
        const bar3      = barColor3 + '█'.repeat(Math.round(tokenPct / 10)) + '░'.repeat(10 - Math.round(tokenPct / 10)) + RESET;
        sA3 = `${bar3} ${tokenPct}%/✦${formatTokens(bolt.tokenCap)}`;
        sB3 = `✦${formatTokens(bolt.tokensUsed)}/${YELLOW}$${bolt.costUsed.toFixed(2)}${RESET}`;
        sD3 = todayThinkMs > 0
            ? `${CC}${formatDuration(todayThinkMs)}/⏱️${formatDuration(wallClock24)}`
            : `⏱️${formatDuration(wallClock24)}`;
        sE3 = limitExceeded
            ? `🔒${DIM}limits (✦${formatTokens(bolt.tokenCap)} per 1d)${RESET}`
            : `🔓${DIM}limits (✦${formatTokens(bolt.tokenCap)} per 1d)${RESET}`;
    } else {
        // Slim 24h line — no bar, no limits label.
        sA3 = '';
        sB3 = today24Stats?.tokens > 0
            ? `✦${formatTokens(today24Stats.tokens)}/${YELLOW}$${today24Stats.cost.toFixed(2)}${RESET}`
            : '';
        sD3 = todayThinkMs > 0
            ? `${CC}${formatDuration(todayThinkMs)}/⏱️${formatDuration(wallClock24)}`
            : `⏱️${formatDuration(wallClock24)}`;
        sE3 = `${DIM}per 1d${RESET}`;
    }

    // Column widths — A3 is blank in slim mode so wA stays driven by sA2.
    const wA = bolt ? Math.max(visLen(sA2), visLen(sA3)) : visLen(sA2);
    const wB = Math.max(visLen(sB2), visLen(sB3));
    const wC = visLen(sC2);
    const wD = Math.max(visLen(sD2), visLen(sD3));

    const l2 = padVis(sA2, wA) + SEP + padVis(sB2, wB) + (wC ? SEP + padVis(sC2, wC) : '') + SEP + padVis(sD2, wD) + (sE2 ? SEP + sE2 : '');
    console.log(l2);

    // Line 3: blank A in slim mode, blank C always (no last-op for 24h view).
    const l3a = bolt ? padVis(sA3, wA) : ' '.repeat(wA);
    const l3 = l3a + SEP + padVis(sB3, wB) + (wC ? ' '.repeat(SEP.length + wC) : '') + SEP + padVis(sD3, wD) + SEP + sE3;
    console.log(l3);
});
