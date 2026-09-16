#!/usr/bin/env node
const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const REPOSITORY_LIMITS_STATE_DIR = path.join(os.homedir(), '.claude', 'repository-limits');
const REPOSITORY_LIMITS_CONFIG_PATH = path.join(os.homedir(), '.claude', 'repository-limits-config.json');
const CACHE_FILE = path.join(os.homedir(), '.claude', 'statusline-cache.json');
const MONTH_CACHE_FILE = path.join(os.homedir(), '.claude', 'statusline-month-cache.json');
const CACHE_TTL_MS = 300_000;
const MONTH_RESCAN_INTERVAL_MS = 30_000;
const DEBUG_MODE = process.env.CLAUDE_STATUSLINE_DEBUG === '1';

const PRICE = {
    input: 3.0 / 1e6,
    output: 15.0 / 1e6,
    cacheRead: 0.30 / 1e6,
    cacheWrite5m: 3.75 / 1e6,
    cacheWrite1h: 6.0 / 1e6,
    get cacheWrite() { return this.cacheWrite5m; },
};

function trimZeros(s) {
    return s.includes('.') ? s.replace(/\.?0+$/, '') : s;
}

function formatTokens(n) {
    if (n >= 1_000_000_000) return `${trimZeros((n / 1_000_000_000).toFixed(1))}B`;
    if (n >= 1_000_000) return `${trimZeros((n / 1_000_000).toFixed(1))}M`;
    if (n >= 1000) return `${trimZeros((n / 1000).toFixed(1))}K`;
    return `${n}`;
}

function formatCost(n) {
    if (n >= 1_000_000_000) return `~$${trimZeros((n / 1_000_000_000).toFixed(1))}B`;
    if (n >= 1_000_000) return `~$${trimZeros((n / 1_000_000).toFixed(1))}M`;
    if (n >= 1000) return `~$${trimZeros((n / 1000).toFixed(1))}K`;
    if (n >= 0.01) return `~$${trimZeros(n.toFixed(2))}`;
    return `~$${n.toPrecision(1)}`;
}

function visLen(s) {
    const plain = s.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
    let w = 0;
    for (const c of [...plain]) {
        const cp = c.codePointAt(0);
        if (cp === 0x200D) continue;
        if (cp === 0xFE0F) { w++; continue; }
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

const _now = new Date();
const MONTH_START_MS = new Date(_now.getFullYear(), _now.getMonth(), 1).getTime();
const PREV_MONTH_START_MS = new Date(_now.getFullYear(), _now.getMonth() - 1, 1).getTime();
const PREV_MONTH_END_MS = MONTH_START_MS;

function parseCacheWrite(u) {
    const cc = u.cache_creation;
    if (cc && typeof cc === 'object') {
        return { cw5m: cc.ephemeral_5m_input_tokens || 0, cw1h: cc.ephemeral_1h_input_tokens || 0 };
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
    };
}

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

const DAY_MS = 24 * 3600 * 1000;

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

function getTodayStats(transcriptPaths, cutoff = Date.now() - DAY_MS) {
    let tokens = 0, cost = 0;
    for (const tp of transcriptPaths) {
        try {
            for (const line of fs.readFileSync(tp, 'utf8').split('\n')) {
                try {
                    const e = JSON.parse(line);
                    if ((e.apiBlockIndex ?? 0) !== 0 || !e.timestamp) continue;
                    if (new Date(e.timestamp).getTime() < cutoff) continue;
                    const u = e?.message?.usage;
                    if (!u) continue;
                    const r = usageTokensAndCost(u);
                    tokens += r.tokens; cost += r.cost;
                } catch {}
            }
        } catch {}
    }
    return { tokens, cost };
}

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

function getPrevWorkdayRange(now) {
    const dow = now.getDay();
    if (dow === 0 || dow === 6) return null;
    const daysBack = dow === 1 ? 3 : 1;
    const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysBack);
    return {
        startMs: d.getTime(),
        endMs: new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysBack + 1).getTime(),
    };
}

function getStatsInRange(transcriptPaths, startMs, endMs) {
    let tokens = 0, cost = 0;
    for (const tp of transcriptPaths) {
        try {
            for (const line of fs.readFileSync(tp, 'utf8').split('\n')) {
                try {
                    const e = JSON.parse(line);
                    if ((e.apiBlockIndex ?? 0) !== 0 || !e.timestamp) continue;
                    const ts = new Date(e.timestamp).getTime();
                    if (ts < startMs || ts >= endMs) continue;
                    const u = e?.message?.usage;
                    if (!u) continue;
                    const r = usageTokensAndCost(u);
                    tokens += r.tokens; cost += r.cost;
                } catch {}
            }
        } catch {}
    }
    return { tokens, cost };
}

// ── Incremental file reading ──────────────────────────────────────────────────

function readNewLines(filePath, fromOffset) {
    try {
        const fd = fs.openSync(filePath, 'r');
        const size = fs.fstatSync(fd).size;
        if (size < fromOffset) { fs.closeSync(fd); return { lines: [], newOffset: 0, reset: true }; }
        if (size === fromOffset) { fs.closeSync(fd); return { lines: [], newOffset: fromOffset }; }
        const buf = Buffer.alloc(size - fromOffset);
        fs.readSync(fd, buf, 0, buf.length, fromOffset);
        fs.closeSync(fd);
        return { lines: buf.toString('utf8').split('\n').filter(Boolean), newOffset: size };
    } catch { return { lines: [], newOffset: fromOffset }; }
}

// ── Main cache (current session, incremental) ─────────────────────────────────

function tryReadCache(transcriptPath) {
    try {
        const c = JSON.parse(fs.readFileSync(CACHE_FILE, 'utf8'));
        if (c.transcriptPath !== transcriptPath) return null;
        if (Date.now() - c.ts > CACHE_TTL_MS) return null;
        return c;
    } catch { return null; }
}

function writeCache(stats) {
    try { fs.writeFileSync(CACHE_FILE, JSON.stringify({ ts: Date.now(), ...stats })); } catch {}
}

function updateMainCache(cache, data) {
    const transcriptPath = data.transcript_path || null;
    const t = DEBUG_MODE ? Date.now() : 0;

    let branch = '';
    try {
        branch = execSync('git branch --show-current', { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] }).trim();
        branch = branch ? ` | 🌿 ${branch}` : '';
    } catch {}
    const limits = repositoryLimitsData(data.workspace?.repo);

    let fromOffset = cache?.transcriptOffset || 0;
    let { lines, newOffset, reset } = transcriptPath
        ? readNewLines(transcriptPath, fromOffset)
        : { lines: [], newOffset: 0 };

    // File was truncated (new session reused path) — restart from beginning
    if (reset && transcriptPath) {
        ({ lines, newOffset } = readNewLines(transcriptPath, 0));
        cache = null;
    }

    let tokens        = cache?.sessionTotal?.tokens || 0;
    let cost          = cache?.sessionTotal?.cost   || 0;
    let thinkMs       = cache?.sessionThinkMs       || 0;
    let sessionStartTs = cache?.sessionStartTs      || null;
    let pendingUserTs  = cache?.pendingUserTs        || null;
    let lastOp         = cache?.lastOp              || null;
    let opIndex        = lastOp?.opIndex            || 0;

    for (const line of lines) {
        try {
            const e = JSON.parse(line);
            if (!e.timestamp) continue;
            const ts = new Date(e.timestamp).getTime();
            if (!sessionStartTs) sessionStartTs = ts;
            if (e.type === 'user' || e.type === 'human') {
                pendingUserTs = ts;
            } else if (e.type === 'assistant' && e.apiBlockIndex === 0 && pendingUserTs !== null) {
                thinkMs += ts - pendingUserTs;
                pendingUserTs = null;
            }
            if ((e.apiBlockIndex ?? 0) !== 0) continue;
            const u = e?.message?.usage;
            if (!u) continue;
            const r = usageTokensAndCost(u);
            if (r.tokens === 0) continue;
            opIndex++;
            tokens += r.tokens;
            cost   += r.cost;
            lastOp  = { tokens: r.tokens, cost: r.cost, opIndex };
        } catch {}
    }

    const wallClockMs = sessionStartTs
        ? Date.now() - sessionStartTs
        : (data.cost?.total_duration_ms || 0);

    // 24h stats (sliding window — computed fresh each call)
    const cutoff24 = Date.now() - DAY_MS;
    const tPaths24Raw = findRecentTranscripts(transcriptPath, cutoff24);
    const tPaths24Set = new Set(tPaths24Raw);
    if (transcriptPath) tPaths24Set.add(transcriptPath);
    const tPaths24   = [...tPaths24Set];
    const otherPaths = transcriptPath ? tPaths24.filter(p => p !== transcriptPath) : tPaths24;
    const otherStats  = otherPaths.length ? getTodayStats(otherPaths, cutoff24) : { tokens: 0, cost: 0 };
    const wallClock24 = getTodayWallClockMs(tPaths24, cutoff24);
    const todayThinkMs = getThinkingMs(tPaths24, cutoff24);

    let prevDayInfo = null;
    const prevDayRange = getPrevWorkdayRange(_now);
    if (prevDayRange && transcriptPath) {
        const prevDayPaths = findRecentTranscripts(transcriptPath, prevDayRange.startMs);
        const prevDayStats = getStatsInRange(prevDayPaths, prevDayRange.startMs, prevDayRange.endMs);
        const curr24Stats  = getStatsInRange(tPaths24, cutoff24, Date.now() + 1);
        if (curr24Stats.tokens > 0 || prevDayStats.tokens > 0) {
            prevDayInfo = {
                d24Tokens: curr24Stats.tokens - prevDayStats.tokens,
                d24Cost:   curr24Stats.cost   - prevDayStats.cost,
            };
        }
    }

    if (DEBUG_MODE) process.stderr.write(`main cache: ${Date.now() - t}ms, ${lines.length} new lines\n`);

    return {
        transcriptPath, branch, limits,
        sessionTotal: { tokens, cost },
        lastOp, sessionThinkMs: thinkMs,
        sessionStartTs, pendingUserTs,
        wallClockMs, transcriptOffset: newOffset,
        tPaths24Count: tPaths24.length, otherStats, wallClock24, todayThinkMs, prevDayInfo,
    };
}

// ── Month cache (all sessions, incremental per file) ──────────────────────────

function loadMonthCache() {
    try { return JSON.parse(fs.readFileSync(MONTH_CACHE_FILE, 'utf8')); }
    catch { return null; }
}

function saveMonthCache(mc) {
    try { fs.writeFileSync(MONTH_CACHE_FILE, JSON.stringify(mc)); } catch {}
}

function updateCurrentMonth(current, data) {
    const c = current || {
        tokens: 0, cost: 0, thinkMs: 0, wallClockStartMs: null,
        offsets: {}, lastScanMs: 0, transcriptCount: 0,
    };

    let { tokens, cost, thinkMs, wallClockStartMs, lastScanMs } = c;
    const offsets = Object.assign({}, c.offsets);

    // Periodically discover new transcript files
    if (Date.now() - (lastScanMs || 0) > MONTH_RESCAN_INTERVAL_MS) {
        for (const p of findAllTranscriptsSince(MONTH_START_MS)) {
            if (!(p in offsets)) offsets[p] = { offset: 0, pendingUserTs: null };
        }
        lastScanMs = Date.now();
    }

    // Always track the current session transcript
    const tp = data.transcript_path;
    if (tp && !(tp in offsets)) offsets[tp] = { offset: 0, pendingUserTs: null };

    for (const [fp, entry] of Object.entries(offsets)) {
        const { offset, pendingUserTs: pUTs } = typeof entry === 'number'
            ? { offset: entry, pendingUserTs: null }
            : entry;

        const { lines, newOffset, reset } = readNewLines(fp, offset);
        let pendingUserTs = reset ? null : pUTs;

        for (const line of lines) {
            try {
                const e = JSON.parse(line);
                if (!e.timestamp) continue;
                const ts = new Date(e.timestamp).getTime();
                if (ts < MONTH_START_MS) continue;
                if (!wallClockStartMs || ts < wallClockStartMs) wallClockStartMs = ts;
                if (e.type === 'user' || e.type === 'human') {
                    pendingUserTs = ts;
                } else if (e.type === 'assistant' && e.apiBlockIndex === 0 && pendingUserTs !== null) {
                    if (pendingUserTs >= MONTH_START_MS) thinkMs += ts - pendingUserTs;
                    pendingUserTs = null;
                }
                if ((e.apiBlockIndex ?? 0) !== 0) continue;
                const u = e?.message?.usage;
                if (!u) continue;
                const r = usageTokensAndCost(u);
                tokens += r.tokens;
                cost   += r.cost;
            } catch {}
        }

        offsets[fp] = { offset: reset ? newOffset : newOffset, pendingUserTs };
    }

    return {
        tokens, cost, thinkMs, wallClockStartMs,
        offsets, lastScanMs,
        transcriptCount: Object.keys(offsets).length,
    };
}

function computePrevMonth(elapsedMs) {
    const t = DEBUG_MODE ? Date.now() : 0;
    const paths = findAllTranscriptsSince(PREV_MONTH_START_MS);
    const samePeriodCutoff = PREV_MONTH_START_MS + elapsedMs;
    let tokens = 0, cost = 0, samePeriodTokens = 0, samePeriodCost = 0;
    let thinkMs = 0, wallClockStartMs = null;

    for (const fp of paths) {
        const { lines } = readNewLines(fp, 0);
        let pendingUserTs = null;
        for (const line of lines) {
            try {
                const e = JSON.parse(line);
                if (!e.timestamp) continue;
                const ts = new Date(e.timestamp).getTime();
                if (ts < PREV_MONTH_START_MS || ts >= PREV_MONTH_END_MS) continue;
                if (!wallClockStartMs || ts < wallClockStartMs) wallClockStartMs = ts;
                if (e.type === 'user' || e.type === 'human') {
                    pendingUserTs = ts;
                } else if (e.type === 'assistant' && e.apiBlockIndex === 0 && pendingUserTs !== null) {
                    if (pendingUserTs >= PREV_MONTH_START_MS) thinkMs += ts - pendingUserTs;
                    pendingUserTs = null;
                }
                if ((e.apiBlockIndex ?? 0) !== 0) continue;
                const u = e?.message?.usage;
                if (!u) continue;
                const r = usageTokensAndCost(u);
                tokens += r.tokens;
                cost   += r.cost;
                if (ts < samePeriodCutoff) {
                    samePeriodTokens += r.tokens;
                    samePeriodCost   += r.cost;
                }
            } catch {}
        }
    }

    if (DEBUG_MODE) process.stderr.write(`prev month: ${Date.now() - t}ms, ${paths.length} files\n`);
    const wallClockMs = wallClockStartMs ? PREV_MONTH_END_MS - wallClockStartMs : 0;
    return { tokens, cost, samePeriodTokens, samePeriodCost, samePeriodElapsedMs: elapsedMs, thinkMs, wallClockMs, computed: true };
}

const ELAPSED_REFRESH_MS = 6 * 3600 * 1000;

function updateMonthCache(mc, data) {
    if (mc?.monthStartMs !== MONTH_START_MS) mc = null;
    const t = DEBUG_MODE ? Date.now() : 0;
    const elapsedMs = Date.now() - MONTH_START_MS;
    const currentMonth = updateCurrentMonth(mc?.currentMonth || null, data);
    const prevStale = !mc?.prevMonth?.computed
        || Math.abs(elapsedMs - (mc.prevMonth.samePeriodElapsedMs || 0)) > ELAPSED_REFRESH_MS;
    const prevMonth = prevStale ? computePrevMonth(elapsedMs) : mc.prevMonth;
    if (DEBUG_MODE) process.stderr.write(`month cache total: ${Date.now() - t}ms\n`);
    return { monthStartMs: MONTH_START_MS, currentMonth, prevMonth };
}

// ── Render ────────────────────────────────────────────────────────────────────

function renderOutput(data, stats, mc) {
    const { branch, sessionTotal, lastOp, wallClockMs, sessionThinkMs, limits,
            tPaths24Count, otherStats, wallClock24, todayThinkMs, prevDayInfo } = stats;

    const sessionCost = data.cost?.total_cost_usd || 0;
    const pct      = Math.floor(data.context_window?.used_percentage || 0);
    const ctxTotal = data.context_window?.context_window_size || 0;
    const model    = data.model.display_name;
    const dir      = path.basename(data.workspace?.current_dir || '');
    const sessionName = data.session_name || null;

    const CYAN = '\x1b[36m', GREEN = '\x1b[32m', YELLOW = '\x1b[33m', RED = '\x1b[31m', RESET = '\x1b[0m';
    const LIGHT_GREEN = '\x1b[92m', DIM = '\x1b[90m';
    const CC = '🦀';

    const cm = mc?.currentMonth || null;
    const pm = mc?.prevMonth    || null;

    console.log(`${CYAN}[${model}]${RESET} 📁 ${dir}${branch}`);

    const SEP = ' | ';
    const barColor = pct >= 90 ? RED : pct >= 70 ? YELLOW : GREEN;
    const bar = '█'.repeat(Math.floor(pct / 10)) + '░'.repeat(10 - Math.floor(pct / 10));

    const today24Tokens = (sessionTotal?.tokens || 0) + (otherStats?.tokens || 0);
    const today24Cost   = sessionCost + (otherStats?.cost || 0);

    // ── Line 2: session ──────────────────────────────────────────────────────
    const sA2 = `${barColor}${bar}${RESET} ${pct}%`;
    const sB2 = sessionTotal?.tokens > 0
        ? `◈${formatTokens(sessionTotal.tokens)} ${YELLOW}${formatCost(sessionCost)}${RESET}`
        : `${YELLOW}${formatCost(sessionCost)}${RESET}`;
    const sC2     = lastOp ? `${DIM}💬${lastOp.opIndex}${RESET}` : '';
    const sDelta2 = lastOp ? `${LIGHT_GREEN}↑${RESET}◈${formatTokens(lastOp.tokens)} ${YELLOW}${formatCost(lastOp.cost)}${RESET}` : '';
    const sD2     = sessionThinkMs > 0 ? `${CC}${formatDuration(sessionThinkMs)}` : '';
    const sE2     = `⏱️${formatDuration(wallClockMs)}`;
    const ctxSuffix = ctxTotal ? ` (◈${formatTokens(ctxTotal)} context)` : '';
    const sF2 = sessionName
        ? `🔮${DIM}${sessionName}${ctxSuffix}${RESET}`
        : ctxTotal ? `${DIM}${ctxSuffix.trim()}${RESET}` : '';

    // ── Line 3: 24h (or limits bar) ─────────────────────────────────────────
    let sA3 = '', sB3 = '', sC3 = '', sDelta3 = '', sD3 = '', sE3wall = '', sE3 = '', sF3 = '';

    if (limits) {
        const tokenPct  = Math.min(100, Math.floor((limits.tokensUsed / limits.tokenCap) * 100));
        const barColor3 = tokenPct >= 90 ? RED : tokenPct >= 70 ? YELLOW : GREEN;
        const bar3 = barColor3 + '█'.repeat(Math.round(tokenPct / 10)) + '░'.repeat(10 - Math.round(tokenPct / 10)) + RESET;
        const msUntilReset = new Date(new Date().toISOString().slice(0, 10) + 'T00:00:00Z').getTime() + 86400000 - Date.now();
        const hoursLeft = Math.ceil(msUntilReset / 3600000);
        sA3 = `${bar3} ${tokenPct}%`;
        sE3 = limits.tokensUsed >= limits.tokenCap
            ? `🔒${RED}Limit hit${RESET}${DIM} — resets in ${hoursLeft}h to ◈${formatTokens(limits.tokenCap)}${RESET}`
            : `🔓${DIM}◈${formatTokens(Math.max(0, limits.tokenCap - limits.tokensUsed))} left, resets in ${hoursLeft}h${RESET}`;
    } else {
        sA3 = `${DIM}24 hours${RESET}`;
    }
    sB3 = today24Tokens > 0 ? `◈${formatTokens(today24Tokens)} ${YELLOW}${formatCost(today24Cost)}${RESET}` : '';
    sC3 = tPaths24Count > 0 ? `${DIM}🔮${tPaths24Count}${RESET}` : '';
    sD3 = todayThinkMs > 0 ? `${CC}${formatDuration(todayThinkMs)}` : '';
    sE3wall = `⏱️${formatDuration(wallClock24)}`;
    if (prevDayInfo) {
        const { d24Tokens, d24Cost } = prevDayInfo;
        const sign = d24Tokens >= 0 ? LIGHT_GREEN + '↑' : RED + '↓';
        sDelta3 = `${sign}${RESET}◈${formatTokens(Math.abs(d24Tokens))} ${YELLOW}${formatCost(Math.abs(d24Cost))}${RESET}`;
    }
    if (!limits) sF3 = `${DIM}📁This project sessions for today${RESET}`;

    const stripAnsi = s => s.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
    const showLine3 = !!limits
        || stripAnsi(sB2) !== stripAnsi(sB3)
        || stripAnsi(sD2) !== stripAnsi(sD3)
        || stripAnsi(sE2) !== stripAnsi(sE3wall)
        || !!sDelta3;

    // ── Line 4: current month ────────────────────────────────────────────────
    let sA4 = '', sB4 = '', sC4 = '', sDelta4 = '', sD4 = '', sE4 = '', sF4 = '';
    if (cm) {
        const monthName = _now.toLocaleString('en', { month: 'short', year: 'numeric' });
        sA4 = `${DIM}${monthName}${RESET}`;
        sB4 = cm.tokens > 0 ? `◈${formatTokens(cm.tokens)} ${YELLOW}${formatCost(cm.cost)}${RESET}` : '';
        sC4 = cm.transcriptCount > 0 ? `${DIM}🔮${cm.transcriptCount}${RESET}` : '';
        sD4 = cm.thinkMs > 0 ? `${CC}${formatDuration(cm.thinkMs)}` : '';
        sE4 = cm.wallClockStartMs ? `⏱️${formatDuration(Date.now() - cm.wallClockStartMs)}` : '';
        sF4 = `${DIM}🏆This month all projects${RESET}`;
        const pmSamePeriod = pm?.samePeriodTokens != null ? pm.samePeriodTokens : pm?.tokens;
        if (pmSamePeriod > 0) {
            const dTokens = cm.tokens - pmSamePeriod;
            const dCost   = cm.cost   - (pm.samePeriodCost ?? pm.cost);
            const sign = dTokens >= 0 ? LIGHT_GREEN + '↑' : RED + '↓';
            sDelta4 = `${sign}${RESET}◈${formatTokens(Math.abs(dTokens))} ${YELLOW}${formatCost(Math.abs(dCost))}${RESET}`;
        }
    }

    const hasLine4 = !!cm;

    // Column widths across all lines
    const wA     = Math.max(visLen(sA2), showLine3 ? visLen(sA3) : 0, hasLine4 ? visLen(sA4) : 0);
    const wB     = Math.max(visLen(sB2), showLine3 ? visLen(sB3) : 0, hasLine4 ? visLen(sB4) : 0);
    const wC     = Math.max(visLen(sC2), showLine3 ? visLen(sC3) : 0, hasLine4 ? visLen(sC4) : 0);
    const wDelta = Math.max(visLen(sDelta2), showLine3 ? visLen(sDelta3) : 0, hasLine4 ? visLen(sDelta4) : 0);
    const wD     = Math.max(visLen(sD2), showLine3 ? visLen(sD3) : 0, hasLine4 ? visLen(sD4) : 0);
    const wE     = Math.max(visLen(sE2), showLine3 ? visLen(sE3wall) : 0, hasLine4 ? visLen(sE4) : 0);
    const wF     = Math.max(visLen(sF2), showLine3 ? visLen(sF3) : 0, hasLine4 ? visLen(sF4) : 0);

    const l2 = padVis(sA2, wA) + SEP + padVis(sB2, wB)
        + (wC ? SEP + padVis(sC2, wC) : '')
        + (wDelta ? SEP + padVis(sDelta2, wDelta) : '')
        + (wD ? SEP + padVis(sD2, wD) : '')
        + SEP + padVis(sE2, wE)
        + (wF ? SEP + padVis(sF2, wF) : '');
    console.log(l2);

    if (showLine3) {
        const l3 = padVis(sA3, wA) + SEP + padVis(sB3, wB)
            + (wC ? SEP + padVis(sC3, wC) : '')
            + (wDelta ? SEP + padVis(sDelta3, wDelta) : '')
            + (wD ? SEP + padVis(sD3, wD) : '')
            + SEP + padVis(sE3wall, wE)
            + (sE3 ? SEP + sE3 : (wF ? SEP + sF3 : ''));
        console.log(l3);
    }

    if (hasLine4) {
        const l4 = padVis(sA4, wA) + SEP + padVis(sB4, wB)
            + (wC ? SEP + padVis(sC4, wC) : '')
            + (wDelta ? SEP + padVis(sDelta4, wDelta) : '')
            + (wD ? SEP + padVis(sD4, wD) : '')
            + SEP + padVis(sE4, wE)
            + (wF ? SEP + sF4 : '');
        console.log(l4);
    }
}

// ── Main ──────────────────────────────────────────────────────────────────────

let input = '';
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
    const data = JSON.parse(input);

    const cache        = tryReadCache(data.transcript_path || null);
    const updatedCache = updateMainCache(cache, data);
    writeCache(updatedCache);

    const mc        = loadMonthCache();
    const updatedMc = updateMonthCache(mc, data);
    saveMonthCache(updatedMc);

    renderOutput(data, updatedCache, updatedMc);
});
