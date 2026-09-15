#!/usr/bin/env node
const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const REPOSITORY_LIMITS_STATE_DIR = path.join(os.homedir(), '.claude', 'repository-limits');
const REPOSITORY_LIMITS_CONFIG_PATH = path.join(os.homedir(), '.claude', 'repository-limits-config.json');
const AUDIT_SESSIONS_DIR = path.join(os.homedir(), 'Library', 'Application Support', 'Claude', 'local-agent-mode-sessions');

const PRICE = {
    input: 3.0 / 1e6,
    output: 15.0 / 1e6,
    cacheRead: 0.30 / 1e6,
    cacheWrite5m: 3.75 / 1e6,
    cacheWrite1h: 6.0 / 1e6,
    get cacheWrite() { return this.cacheWrite5m; }, // legacy alias
};

function formatTokens(n) {
    if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(1)}B`;
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1000) return `${(n / 1000).toFixed(1)}K`;
    return `${n}`;
}

function formatCost(n) {
    if (n >= 1_000_000_000) return `~$${(n / 1_000_000_000).toFixed(1)}B`;
    if (n >= 1_000_000) return `~$${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1000) return `~$${(n / 1000).toFixed(1)}K`;
    if (n >= 0.01) return `~$${n.toFixed(2)}`;
    return `~$${n.toPrecision(1)}`;
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
const _now = new Date();
const MONTH_START_MS = new Date(_now.getFullYear(), _now.getMonth(), 1).getTime();

function getSessionWallClockMs(transcriptPath) {
    try {
        for (const line of fs.readFileSync(transcriptPath, 'utf8').split('\n')) {
            try { const e = JSON.parse(line); if (e.timestamp) return Date.now() - new Date(e.timestamp).getTime(); } catch {}
        }
    } catch {}
    return null;
}

// Wall-clock since the first entry within the given window.
function getTodayWallClockMs(transcriptPaths, cutoff = Date.now() - DAY_MS) {
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

// Parse cache write tokens from both old flat field and new nested ephemeral format.
function parseCacheWrite(u) {
    const cc = u.cache_creation;
    if (cc && typeof cc === 'object') {
        return {
            cw5m: cc.ephemeral_5m_input_tokens || 0,
            cw1h: cc.ephemeral_1h_input_tokens || 0,
        };
    }
    return { cw5m: u.cache_creation_input_tokens || 0, cw1h: 0 };
}

function usageTokensAndCost(u) {
    const inp = u.input_tokens || 0;
    const out = u.output_tokens || 0;
    const cr  = u.cache_read_input_tokens || 0;
    const { cw5m, cw1h } = parseCacheWrite(u);
    const tokens = inp + out + cr + cw5m + cw1h;
    const cost = inp * PRICE.input + out * PRICE.output + cr * PRICE.cacheRead
               + cw5m * PRICE.cacheWrite5m + cw1h * PRICE.cacheWrite1h;
    return { tokens, cost };
}

function getSessionTotalStats(transcriptPath) {
    let tokens = 0, cost = 0;
    try {
        for (const line of fs.readFileSync(transcriptPath, 'utf8').split('\n')) {
            try {
                const e = JSON.parse(line);
                if ((e.apiBlockIndex ?? 0) !== 0) continue;
                const u = e?.message?.usage;
                if (!u) continue;
                const r = usageTokensAndCost(u);
                tokens += r.tokens;
                cost   += r.cost;
            } catch {}
        }
    } catch {}
    return { tokens, cost };
}

// Token/cost totals for entries within the given window.
function getTodayStats(transcriptPaths, cutoff = Date.now() - DAY_MS) {
    let tokens = 0, cost = 0;
    for (const tp of transcriptPaths) {
        try {
            for (const line of fs.readFileSync(tp, 'utf8').split('\n')) {
                try {
                    const e = JSON.parse(line);
                    if ((e.apiBlockIndex ?? 0) !== 0) continue;
                    if (!e.timestamp) continue;
                    if (new Date(e.timestamp).getTime() < cutoff) continue;
                    const u = e?.message?.usage;
                    if (!u) continue;
                    const r = usageTokensAndCost(u);
                    tokens += r.tokens;
                    cost   += r.cost;
                } catch {}
            }
        } catch {}
    }
    return { tokens, cost };
}

function getPrevWorkdayRange(now) {
    const dow = now.getDay();
    if (dow === 0 || dow === 6) return null; // weekend — no delta
    const daysBack = dow === 1 ? 3 : 1; // Monday→Friday, others→yesterday
    const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysBack);
    return { startMs: d.getTime(), endMs: new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysBack + 1).getTime() };
}

function getStatsInRange(transcriptPaths, startMs, endMs) {
    let tokens = 0, cost = 0;
    for (const tp of transcriptPaths) {
        try {
            for (const line of fs.readFileSync(tp, 'utf8').split('\n')) {
                try {
                    const e = JSON.parse(line);
                    if ((e.apiBlockIndex ?? 0) !== 0) continue;
                    if (!e.timestamp) continue;
                    const ts = new Date(e.timestamp).getTime();
                    if (ts < startMs || ts >= endMs) continue;
                    const u = e?.message?.usage;
                    if (!u) continue;
                    const r = usageTokensAndCost(u);
                    tokens += r.tokens;
                    cost   += r.cost;
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
                if ((e.apiBlockIndex ?? 0) !== 0) continue;
                const u = e?.message?.usage;
                if (!u) continue;
                const r = usageTokensAndCost(u);
                if (r.tokens === 0) continue;
                opIndex++;
                lastStats = { tokens: r.tokens, cost: r.cost, opIndex };
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

// All transcript files in the same project directory modified within the given window.
function findRecentTranscripts(transcriptPath, cutoff = Date.now() - DAY_MS) {
    if (!transcriptPath) return [];
    const dir = path.dirname(transcriptPath);
    try {
        return fs.readdirSync(dir)
            .filter(f => f.endsWith('.jsonl'))
            .map(f => path.join(dir, f))
            .filter(f => { try { return fs.statSync(f).mtimeMs >= cutoff; } catch { return false; } });
    } catch { return [transcriptPath]; }
}

// All desktop-app audit.jsonl files modified since the given cutoff.
function findAuditFilesSince(cutoff) {
    const result = [];
    function scan(dir, depth) {
        if (depth > 4) return;
        try {
            for (const entry of fs.readdirSync(dir)) {
                const fp = path.join(dir, entry);
                try {
                    const stat = fs.statSync(fp);
                    if (stat.isDirectory()) { scan(fp, depth + 1); continue; }
                    if (entry === 'audit.jsonl' && stat.mtimeMs >= cutoff) result.push(fp);
                } catch {}
            }
        } catch {}
    }
    scan(AUDIT_SESSIONS_DIR, 0);
    return result;
}

// Token/cost totals from desktop-app audit.jsonl entries (type=result) within a date range.
// Deduplicates by uuid across all provided files.
function getAuditStatsInRange(auditPaths, startMs, endMs) {
    let tokens = 0, cost = 0;
    const seenUuids = new Set();
    for (const ap of auditPaths) {
        try {
            for (const line of fs.readFileSync(ap, 'utf8').split('\n')) {
                try {
                    const e = JSON.parse(line);
                    if (e.type !== 'result' || !e.usage) continue;
                    const ts = new Date(e.timestamp || '').getTime();
                    if (!ts || ts < startMs || ts >= endMs) continue;
                    if (e.uuid) {
                        if (seenUuids.has(e.uuid)) continue;
                        seenUuids.add(e.uuid);
                    }
                    const r = usageTokensAndCost(e.usage);
                    tokens += r.tokens;
                    cost   += r.cost;
                } catch {}
            }
        } catch {}
    }
    return { tokens, cost };
}

// All transcript files across all Claude projects modified since the given cutoff.
function findAllTranscriptsSince(cutoff) {
    const projectsDir = path.join(os.homedir(), '.claude', 'projects');
    const result = [];
    try {
        for (const proj of fs.readdirSync(projectsDir)) {
            const projDir = path.join(projectsDir, proj);
            try {
                if (!fs.statSync(projDir).isDirectory()) continue;
                for (const f of fs.readdirSync(projDir)) {
                    if (!f.endsWith('.jsonl')) continue;
                    const fp = path.join(projDir, f);
                    try { if (fs.statSync(fp).mtimeMs >= cutoff) result.push(fp); } catch {}
                }
            } catch {}
        }
    } catch {}
    return result;
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
    const limits        = repositoryLimitsData(data.workspace?.repo);

    // Show a slim 24h line when no limits are configured.
    const showSlim = !limits;

    // Transcript paths for 24h aggregation.
    // Always include the current transcript even if the hook hasn't written it to state yet.
    const tPaths24Raw = limits?.transcriptPaths?.length
        ? limits.transcriptPaths
        : findRecentTranscripts(transcriptPath);
    const tPaths24Set = new Set(tPaths24Raw);
    if (transcriptPath) tPaths24Set.add(transcriptPath);
    const tPaths24 = [...tPaths24Set];

    // Other (past) sessions = 24h paths minus current transcript.
    const otherPaths = transcriptPath ? tPaths24.filter(p => p !== transcriptPath) : tPaths24;

    // 24h stats: transcript-computed everywhere, but current session uses API-reported cost.
    const otherStats    = otherPaths.length ? getTodayStats(otherPaths) : { tokens: 0, cost: 0 };
    const sessionToks   = sessionTotal?.tokens || 0;
    const today24Tokens = sessionToks + otherStats.tokens;
    const today24Cost   = sessionCost + otherStats.cost;

    const wallClock24  = getTodayWallClockMs(tPaths24);
    const todayThinkMs = getThinkingMs(tPaths24, Date.now() - DAY_MS);

    // Previous workday delta for 24h row (same repo only)
    let prevDayDeltaStr = '';
    const prevDayRange = getPrevWorkdayRange(_now);
    if (prevDayRange && transcriptPath) {
        const prevDayPaths = findRecentTranscripts(transcriptPath, prevDayRange.startMs);
        const prevDayStats = getStatsInRange(prevDayPaths, prevDayRange.startMs, prevDayRange.endMs);
        const curr24Stats  = getStatsInRange([...tPaths24Set], Date.now() - DAY_MS, Date.now() + 1);
        if (curr24Stats.tokens > 0 || prevDayStats.tokens > 0) {
            const d24Tokens   = curr24Stats.tokens - prevDayStats.tokens;
            const d24Cost     = curr24Stats.cost   - prevDayStats.cost;
            const sign24      = d24Tokens >= 0 ? LIGHT_GREEN + '↑' : RED + '↓';
            prevDayDeltaStr   = `${sign24}${RESET}◈${formatTokens(Math.abs(d24Tokens))} ${YELLOW}${formatCost(Math.abs(d24Cost))}${RESET}`;
        }
    }

    // — Segment A2: context bar —
    const sA2 = `${barColor}${bar}${RESET} ${pct}%`;

    // — Segment B2: session tokens/cost — use API-reported cost, not recomputed from hardcoded prices
    const sB2 = sessionTotal?.tokens > 0
        ? `◈${formatTokens(sessionTotal.tokens)} ${YELLOW}${formatCost(sessionCost)}${RESET}`
        : `${YELLOW}${formatCost(sessionCost)}${RESET}`;

    // — Segment C2 / CDelta2: last op count + tokens —
    const sC2     = lastOp ? `${DIM}💬${lastOp.opIndex}${RESET}` : '';
    const sDelta2 = lastOp ? `${LIGHT_GREEN}↑${RESET}◈${formatTokens(lastOp.tokens)} ${YELLOW}${formatCost(lastOp.cost)}${RESET}` : '';

    // — Segment D2: thinking time —
    const sD2 = sessionThinkMs > 0 ? `${CC}${formatDuration(sessionThinkMs)}` : '';

    // — Segment E2: wall clock —
    const sE2wall = `⏱️${formatDuration(wallClockMs)}`;

    // — Segment F2: session name + context size —
    const ctxSuffix = ctxTotal ? ` (◈${formatTokens(ctxTotal)} context)` : '';
    const sF2 = sessionName
        ? `🎯${DIM}${sessionName}${ctxSuffix}${RESET}`
        : ctxTotal ? `${DIM}${ctxSuffix.trim()}${RESET}` : '';

    // — Line 3 segments —
    let sA3, sB3, sC3, sDelta3, sD3, sE3wall, sE3;

    const sD3base     = todayThinkMs > 0 ? `${CC}${formatDuration(todayThinkMs)}` : '';
    const sE3wallBase = `⏱️${formatDuration(wallClock24)}`;
    const sC3base     = tPaths24.length > 0 ? `${DIM}🔮${tPaths24.length}${RESET}` : '';
    const sDelta3base = prevDayDeltaStr;
    const sB3base = today24Tokens > 0
        ? `◈${formatTokens(today24Tokens)} ${YELLOW}${formatCost(today24Cost)}${RESET}`
        : '';

    if (limits) {
        const limitExceeded = today24Tokens >= limits.tokenCap;
        const tokenPct  = Math.min(100, Math.floor((today24Tokens / limits.tokenCap) * 100));
        const barColor3 = tokenPct >= 90 ? RED : tokenPct >= 70 ? YELLOW : GREEN;
        const bar3      = barColor3 + '█'.repeat(Math.round(tokenPct / 10)) + '░'.repeat(10 - Math.round(tokenPct / 10)) + RESET;
        sA3 = `${bar3} ${tokenPct}%`;
        sB3 = sB3base;
        sC3 = sC3base;
        sD3 = sD3base;
        sE3wall = sE3wallBase;
        sDelta3 = sDelta3base;
        sE3 = limitExceeded
            ? `🔒${DIM}limits (◈${formatTokens(limits.tokenCap)} per 1d)${RESET}`
            : `🔓${DIM}limits (◈${formatTokens(limits.tokenCap)} per 1d)${RESET}`;
    } else {
        sA3 = `${DIM}24 hours${RESET}`;
        sB3 = sB3base;
        sC3 = sC3base;
        sDelta3 = sDelta3base;
        sD3 = sD3base;
        sE3wall = sE3wallBase;
        sE3 = '';
    }

    // — Line 4 (month, global) segments —
    const tPathsMonthRaw = findAllTranscriptsSince(MONTH_START_MS);
    const tPathsMonthSet = new Set(tPathsMonthRaw);
    if (transcriptPath) tPathsMonthSet.add(transcriptPath);
    const tPathsMonth = [...tPathsMonthSet];

    const otherMonthPaths = transcriptPath ? tPathsMonth.filter(p => p !== transcriptPath) : tPathsMonth;
    const otherMonthStats = otherMonthPaths.length ? getTodayStats(otherMonthPaths, MONTH_START_MS) : { tokens: 0, cost: 0 };
    const monthWallClockMs = getTodayWallClockMs(tPathsMonth, MONTH_START_MS);
    const monthThinkMs     = getThinkingMs(tPathsMonth, MONTH_START_MS);

    // Desktop-app audit sessions for this month (global, included in all month totals)
    const auditFilesMonth    = findAuditFilesSince(MONTH_START_MS);
    const auditMonthStats    = getAuditStatsInRange(auditFilesMonth, MONTH_START_MS, Date.now() + 1);

    const monthTokens = sessionToks + otherMonthStats.tokens + auditMonthStats.tokens;
    const monthCost   = sessionCost + otherMonthStats.cost   + auditMonthStats.cost;

    // Delta vs same period last month — both periods include CLI transcripts + audit sessions
    const prevMonthStartMs       = new Date(_now.getFullYear(), _now.getMonth() - 1, 1).getTime();
    const prevMonthEndMs         = new Date(_now.getFullYear(), _now.getMonth() - 1, _now.getDate() + 1).getTime();
    const tPathsPrev             = findAllTranscriptsSince(prevMonthStartMs);
    const prevMonthCLIStats      = getStatsInRange(tPathsPrev, prevMonthStartMs, prevMonthEndMs);
    const auditFilesPrev         = findAuditFilesSince(prevMonthStartMs);
    const prevMonthAuditStats    = getAuditStatsInRange(auditFilesPrev, prevMonthStartMs, prevMonthEndMs);
    const prevMonthTokens        = prevMonthCLIStats.tokens + prevMonthAuditStats.tokens;
    const prevMonthCost          = prevMonthCLIStats.cost   + prevMonthAuditStats.cost;
    const currMonthPeriodCLI     = getStatsInRange([...tPathsMonthSet], MONTH_START_MS, Date.now() + 1);
    const currMonthPeriodTokens  = currMonthPeriodCLI.tokens + auditMonthStats.tokens;
    const currMonthPeriodCost    = currMonthPeriodCLI.cost   + auditMonthStats.cost;
    const deltaTokens            = currMonthPeriodTokens - prevMonthTokens;
    const deltaCost              = currMonthPeriodCost   - prevMonthCost;

    const monthName = _now.toLocaleString('en', { month: 'short', year: 'numeric' });
    const sA4 = `${DIM}${monthName}${RESET}`;
    const sB4 = monthTokens > 0
        ? `◈${formatTokens(monthTokens)} ${YELLOW}${formatCost(monthCost)}${RESET}`
        : '';
    const sDelta4 = prevMonthTokens > 0
        ? `${deltaTokens >= 0 ? LIGHT_GREEN + '↑' : RED + '↓'}${RESET}◈${formatTokens(Math.abs(deltaTokens))} ${YELLOW}${formatCost(Math.abs(deltaCost))}${RESET}`
        : '';
    const sC4 = tPathsMonth.length > 0 ? `${DIM}🔮${tPathsMonth.length}${RESET}` : '';
    const sD4 = monthThinkMs > 0 ? `${CC}${formatDuration(monthThinkMs)}` : '';
    const sE4wall = `⏱️${formatDuration(monthWallClockMs)}`;

    const stripAnsi = s => s.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
    const showLine3 = !!limits || stripAnsi(sB2) !== stripAnsi(sB3) || stripAnsi(sD2) !== stripAnsi(sD3) || stripAnsi(sE2wall) !== stripAnsi(sE3wall) || !!sDelta3;

    // Column widths — take max across all shown lines.
    const wA     = Math.max(visLen(sA2), showLine3 ? visLen(sA3) : 0, visLen(sA4));
    const wB     = Math.max(visLen(sB2), showLine3 ? visLen(sB3) : 0, visLen(sB4));
    const wC     = Math.max(visLen(sC2), visLen(sC3), visLen(sC4));
    const wDelta = Math.max(visLen(sDelta2), showLine3 ? visLen(sDelta3) : 0, visLen(sDelta4));
    const wD     = Math.max(visLen(sD2), showLine3 ? visLen(sD3) : 0, visLen(sD4));
    const wE     = Math.max(visLen(sE2wall), showLine3 ? visLen(sE3wall) : 0, visLen(sE4wall));

    const l2 = padVis(sA2, wA) + SEP + padVis(sB2, wB) + (wC ? SEP + padVis(sC2, wC) : '') + (wDelta ? SEP + padVis(sDelta2, wDelta) : '') + (wD ? SEP + padVis(sD2, wD) : '') + SEP + padVis(sE2wall, wE) + (sF2 ? SEP + sF2 : '');
    console.log(l2);

    if (showLine3) {
        const l3 = padVis(sA3, wA) + SEP + padVis(sB3, wB) + (wC ? SEP + padVis(sC3, wC) : '') + (wDelta ? SEP + padVis(sDelta3, wDelta) : '') + (wD ? SEP + padVis(sD3, wD) : '') + SEP + padVis(sE3wall, wE) + (sE3 ? SEP + sE3 : '');
        console.log(l3);
    }

    const l4 = padVis(sA4, wA) + SEP + padVis(sB4, wB) + (wC ? SEP + padVis(sC4, wC) : '') + (wDelta ? SEP + padVis(sDelta4, wDelta) : '') + (wD ? SEP + padVis(sD4, wD) : '') + SEP + padVis(sE4wall, wE);
    console.log(l4);
});
