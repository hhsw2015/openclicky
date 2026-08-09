#!/usr/bin/env node
/*
 * OpenClicky OpenCLI Runtime — Node.js boot entry point.
 *
 * Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
 * OpenCLI upstream pin: 9161d99d96ec107cd77f13a30315614129179a1a (v1.8.5)
 *
 * Runs as a subprocess of the OpenClicky macOS app. Binds a loopback
 * HTTP server on a random port in the OPENCLICKY_OPENCLI_PORT_MIN /
 * PORT_MAX range, authenticates every request against
 * OPENCLICKY_OPENCLI_TOKEN, and exposes the three operations that back
 * the opencli_* MCP tools (mirrors Everywhere.Mcp.Tools.OpenCliTools):
 *
 *   GET  /health
 *   POST /list       -> opencli_list
 *   POST /describe   -> opencli_describe
 *   POST /run        -> opencli_run
 *
 * PHASE 7.6a SCOPE (POC): boot.js loads cli-manifest.json from the
 * vendored `opencli/` tree and services list/describe against it
 * directly. `opencli_run` executes public/fetch-only adapters inline
 * with a minimal pipeline interpreter (`fetch`, `limit`, `map`,
 * `filter`, `select`, `sort` steps). Browser-strategy adapters
 * (cookie / intercept / ui) return {ok:false, code:"BROWSER_NOT_READY"}
 * until F31 (OpenDia) lands, matching SPEC §2.1 verbatim.
 *
 * Announcement contract with the Swift subprocess manager:
 *   * Prints exactly "READY <port>\n" on stdout the moment the server
 *     is listening.
 *   * Prints diagnostic lines to stderr only.
 *   * Exits cleanly on SIGTERM/SIGINT.
 */

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

const TOKEN = process.env.OPENCLICKY_OPENCLI_TOKEN || '';
const PORT_MIN = parseInt(process.env.OPENCLICKY_OPENCLI_PORT_MIN || '55000', 10);
const PORT_MAX = parseInt(process.env.OPENCLICKY_OPENCLI_PORT_MAX || '56000', 10);
const RUNTIME_ROOT = process.env.OPENCLICKY_OPENCLI_ROOT || __dirname;

const UPSTREAM_SHA_FILE = path.join(RUNTIME_ROOT, 'UPSTREAM_SHA');
const MANIFEST_FILE = path.join(RUNTIME_ROOT, 'opencli', 'cli-manifest.json');
const QUERY_CAP = 60;

// --- manifest loader --------------------------------------------------------

function readTextFileSafe(p) {
    try { return fs.readFileSync(p, 'utf8'); } catch (_) { return null; }
}

function loadUpstreamSha() {
    const raw = readTextFileSafe(UPSTREAM_SHA_FILE);
    return (raw || '').trim() || 'unknown';
}

function loadManifest() {
    const text = readTextFileSafe(MANIFEST_FILE);
    if (!text) {
        process.stderr.write(`[opencli] manifest missing at ${MANIFEST_FILE}\n`);
        return { adapters: [] };
    }
    try {
        const parsed = JSON.parse(text);
        if (!Array.isArray(parsed)) {
            process.stderr.write('[opencli] manifest root is not an array; expected list of cli() registrations\n');
            return { adapters: [] };
        }
        // Drop adapters whose site is empty or begins with '_'
        // (upstream convention for private/shared modules).
        const filtered = parsed.filter((e) => {
            if (!e || typeof e !== 'object') return false;
            const s = e.site;
            if (typeof s !== 'string' || !s) return false;
            if (s.startsWith('_')) return false;
            return true;
        });
        return { adapters: filtered };
    } catch (e) {
        process.stderr.write(`[opencli] failed to parse manifest: ${e.message}\n`);
        return { adapters: [] };
    }
}

const UPSTREAM_SHA = loadUpstreamSha();
const MANIFEST = loadManifest();

const SITE_INDEX = (() => {
    const map = new Map();
    for (const a of MANIFEST.adapters) {
        if (!map.has(a.site)) map.set(a.site, []);
        map.get(a.site).push(a);
    }
    for (const list of map.values()) {
        list.sort((a, b) => a.name.localeCompare(b.name));
    }
    return map;
})();

// --- envelope helpers (mirror OpenCliTools.Envelope) ------------------------

function envelope(ok, site, name, error, code, data) {
    const o = { schema_version: '1', ok };
    if (site !== null && site !== undefined) o.site = site;
    if (name !== null && name !== undefined) o.name = name;
    if (error !== null && error !== undefined) o.error = error;
    if (code !== null && code !== undefined) o.code = code;
    if (data !== null && data !== undefined) o.data = data;
    return o;
}

function adapterToListEntry(a) {
    const o = {
        site: a.site,
        name: a.name,
        description: a.description || '',
        strategy: a.strategy || 'public',
        browser: !!a.browser,
        args: Array.isArray(a.args) ? a.args : []
    };
    if (Array.isArray(a.aliases) && a.aliases.length > 0) {
        o.aliases = a.aliases.slice();
    }
    return o;
}

function adapterToDescribeJson(a) {
    const o = {
        schema_version: '1',
        site: a.site,
        name: a.name,
        description: a.description || '',
        strategy: a.strategy || 'public',
        browser: !!a.browser,
        args: Array.isArray(a.args) ? a.args : [],
        columns: Array.isArray(a.columns) ? a.columns : []
    };
    if (a.access) o.access = a.access;
    if (a.domain) o.domain = a.domain;
    if (Array.isArray(a.aliases) && a.aliases.length > 0) {
        o.aliases = a.aliases.slice();
    }
    return o;
}

// --- routes -----------------------------------------------------------------

async function routeList(req, res) {
    const body = req.parsedBody || {};
    const site = typeof body.site === 'string' ? body.site.trim() : '';
    const query = typeof body.query === 'string' ? body.query.trim() : '';

    if (site) {
        const list = SITE_INDEX.get(site);
        if (!list || list.length === 0) {
            return json(res, 200, envelope(false, site, null, `site '${site}' not in catalog`, 'RUNTIME_NOT_FOUND'));
        }
        return json(res, 200, {
            schema_version: '1',
            ok: true,
            mode: 'site',
            site,
            commands: list.map(adapterToListEntry),
            upstream_sha: UPSTREAM_SHA
        });
    }

    if (query) {
        const q = query.toLowerCase();
        const all = [];
        for (const a of MANIFEST.adapters) {
            if (a.site.toLowerCase().includes(q)
                || a.name.toLowerCase().includes(q)
                || (a.description || '').toLowerCase().includes(q)) {
                all.push(a);
            }
        }
        const shown = all.slice(0, QUERY_CAP);
        return json(res, 200, {
            schema_version: '1',
            ok: true,
            mode: 'query',
            query,
            commands: shown.map(adapterToListEntry),
            total_matches: all.length,
            truncated: all.length > QUERY_CAP,
            upstream_sha: UPSTREAM_SHA
        });
    }

    // Default index. Collapse to per-site rows.
    const sites = [];
    for (const [siteKey, list] of Array.from(SITE_INDEX.entries()).sort((a, b) => a[0].localeCompare(b[0]))) {
        const sample = list[0];
        sites.push({
            site: siteKey,
            count: list.length,
            description: sample.domain || sample.description || ''
        });
    }
    return json(res, 200, {
        schema_version: '1',
        ok: true,
        mode: 'index',
        sites,
        total_commands: MANIFEST.adapters.length,
        hint: 'call opencli_list({site:"<name>"}) to drill into one site, or opencli_list({query:"<text>"}) for fuzzy search',
        upstream_sha: UPSTREAM_SHA
    });
}

async function routeDescribe(req, res) {
    const body = req.parsedBody || {};
    const site = typeof body.site === 'string' ? body.site.trim() : '';
    const name = typeof body.name === 'string' ? body.name.trim() : '';
    if (!site || !name) {
        return json(res, 200, envelope(false, site || null, name || null,
            'opencli_describe requires site and name', 'invalid_input'));
    }
    const list = SITE_INDEX.get(site);
    if (!list) {
        return json(res, 200, envelope(false, site, name,
            `site '${site}' not in catalog`, 'RUNTIME_NOT_FOUND'));
    }
    const found = list.find((a) => a.name === name);
    if (!found) {
        return json(res, 200, envelope(false, site, name,
            `action '${site}.${name}' not in catalog`, 'RUNTIME_NOT_FOUND'));
    }
    const out = adapterToDescribeJson(found);
    out.upstream_sha = UPSTREAM_SHA;
    return json(res, 200, out);
}

async function routeRun(req, res) {
    const body = req.parsedBody || {};
    const site = typeof body.site === 'string' ? body.site.trim() : '';
    const name = typeof body.name === 'string' ? body.name.trim() : '';
    if (!site || !name) {
        return json(res, 200, envelope(false, site || null, name || null,
            'opencli_run requires site and name', 'invalid_input'));
    }
    const argsJson = typeof body.arguments_json === 'string' ? body.arguments_json : '{}';
    let args = {};
    if (argsJson.trim()) {
        try {
            const parsed = JSON.parse(argsJson);
            if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
                return json(res, 200, envelope(false, site, name,
                    'arguments_json must be a JSON object', 'BAD_ARGS'));
            }
            args = parsed;
        } catch (e) {
            return json(res, 200, envelope(false, site, name,
                `arguments_json invalid JSON: ${e.message}`, 'BAD_ARGS'));
        }
    }
    const list = SITE_INDEX.get(site);
    if (!list) {
        return json(res, 200, envelope(false, site, name,
            `site '${site}' not in catalog`, 'RUNTIME_NOT_FOUND'));
    }
    const def = list.find((a) => a.name === name);
    if (!def) {
        return json(res, 200, envelope(false, site, name,
            `action '${site}.${name}' not in catalog`, 'RUNTIME_NOT_FOUND'));
    }

    // SPEC §2.1: browser-strategy adapters MUST return
    // {ok:false, code:"BROWSER_NOT_READY"} until OpenDia bridge lands.
    const strategy = (def.strategy || 'public').toLowerCase();
    if (def.browser || strategy === 'cookie' || strategy === 'intercept' || strategy === 'ui') {
        return json(res, 200, envelope(false, site, name,
            'opendia-not-connected', 'BROWSER_NOT_READY'));
    }
    if (strategy === 'local') {
        return json(res, 200, envelope(false, site, name,
            "OpenCLI 'local' strategy is out of scope", 'RUNTIME_NOT_IMPLEMENTED'));
    }

    // strategy === 'public': attempt to load the adapter module and
    // execute the pipeline if it is fetch-only.
    const t0 = Date.now();
    try {
        const modulePath = def.modulePath ? path.join(RUNTIME_ROOT, 'opencli', 'clis', def.modulePath) : null;
        if (!modulePath || !fs.existsSync(modulePath)) {
            return json(res, 200, envelope(false, site, name,
                `adapter module missing at ${def.modulePath || '<unset>'}`, 'RUNTIME_NOT_FOUND'));
        }
        // Adapter modules are ESM and depend on '@jackwener/opencli/registry'
        // which we do not ship. For F30 POC we cannot execute the raw
        // module. Extract its pipeline from the manifest (upstream
        // manifest denormalises `pipeline` for many adapters; when it
        // is missing we cannot run inline).
        if (!Array.isArray(def.pipeline)) {
            return json(res, 200, envelope(false, site, name,
                'inline pipeline execution requires manifest.pipeline; adapter did not export a pipeline (POC limitation)',
                'RUNTIME_NOT_IMPLEMENTED'));
        }
        const data = await executePipeline(def.pipeline, args);
        const elapsed = Date.now() - t0;
        return json(res, 200, {
            schema_version: '1',
            ok: true,
            site,
            name,
            data,
            elapsed_ms: elapsed
        });
    } catch (e) {
        return json(res, 200, envelope(false, site, name,
            (e && e.message) || String(e), 'RUNTIME_HOST_ERROR'));
    }
}

// --- minimal pipeline interpreter (subset) ---------------------------------

// Supported steps: fetch, limit, map, filter, select, sort. Template
// syntax `${{ expr }}` evaluated against a scope containing `args`,
// `item`, `index`, and `data`.

function render(template, scope) {
    if (typeof template !== 'string') return template;
    // Full-value template: `${{ expr }}` — return raw evaluated value.
    const full = template.match(/^\s*\$\{\{(.+)\}\}\s*$/);
    if (full) {
        return evalExpr(full[1], scope);
    }
    // Partial: interpolate.
    return template.replace(/\$\{\{(.+?)\}\}/g, (_, expr) => {
        const v = evalExpr(expr, scope);
        return v === undefined || v === null ? '' : String(v);
    });
}

function evalExpr(expr, scope) {
    const keys = Object.keys(scope);
    const vals = keys.map((k) => scope[k]);
    try {
        // eslint-disable-next-line no-new-func
        const fn = new Function(...keys, `"use strict"; return (${expr});`);
        return fn(...vals);
    } catch (e) {
        throw new Error(`template eval failed for '${expr}': ${e.message}`);
    }
}

async function executePipeline(pipeline, args) {
    let data = null;
    for (const stepObj of pipeline) {
        if (!stepObj || typeof stepObj !== 'object') continue;
        for (const [op, params] of Object.entries(stepObj)) {
            data = await runStep(op, params, data, args);
        }
    }
    return data;
}

async function runStep(op, params, data, args) {
    const scope = { args, data, item: null, index: 0 };
    switch (op) {
        case 'fetch': {
            const url = render(params.url, scope);
            const init = {};
            if (params.headers) init.headers = params.headers;
            if (params.method) init.method = params.method;
            const r = await fetch(url, init);
            const text = await r.text();
            try { return JSON.parse(text); } catch (_) { return text; }
        }
        case 'limit': {
            if (!Array.isArray(data)) return data;
            const nRaw = typeof params === 'object' ? params.count : params;
            const n = parseInt(render(nRaw, { args }), 10) || 0;
            return data.slice(0, n);
        }
        case 'map': {
            if (!Array.isArray(data)) return data;
            const out = [];
            for (let i = 0; i < data.length; i++) {
                const item = data[i];
                const scope2 = { args, data, item, index: i };
                if (typeof params === 'string') {
                    out.push(render(params, scope2));
                } else if (typeof params === 'object') {
                    // If params has a `fetch` sub-op, evaluate it per item.
                    if (params.fetch) {
                        const url = render(params.fetch.url, scope2);
                        const r = await fetch(url);
                        const text = await r.text();
                        try { out.push(JSON.parse(text)); } catch (_) { out.push(text); }
                    } else {
                        const row = {};
                        for (const [k, v] of Object.entries(params)) {
                            row[k] = render(v, scope2);
                        }
                        out.push(row);
                    }
                }
            }
            return out;
        }
        case 'filter': {
            if (!Array.isArray(data)) return data;
            const out = [];
            for (let i = 0; i < data.length; i++) {
                const item = data[i];
                const scope2 = { args, data, item, index: i };
                const keep = evalExpr(params, scope2);
                if (keep) out.push(item);
            }
            return out;
        }
        case 'select': {
            if (!Array.isArray(data)) return data;
            if (typeof params !== 'object') return data;
            return data.map((item) => {
                const row = {};
                for (const [k, v] of Object.entries(params)) {
                    row[k] = render(v, { args, data, item, index: 0 });
                }
                return row;
            });
        }
        case 'sort': {
            if (!Array.isArray(data)) return data;
            const key = params.by || params.key;
            const dir = params.desc ? -1 : 1;
            return [...data].sort((a, b) => {
                const av = key ? a[key] : a;
                const bv = key ? b[key] : b;
                if (av < bv) return -1 * dir;
                if (av > bv) return 1 * dir;
                return 0;
            });
        }
        default:
            throw new Error(`pipeline step '${op}' not supported by POC interpreter`);
    }
}

// --- HTTP wiring ------------------------------------------------------------

function readBody(req) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        req.on('data', (c) => chunks.push(c));
        req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        req.on('error', reject);
    });
}

function json(res, status, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
    res.end(body);
}

function authenticate(req) {
    const hdr = req.headers['authorization'] || '';
    return hdr === 'Bearer ' + TOKEN;
}

const ROUTES = {
    'GET /health': async (req, res) => {
        return json(res, 200, {
            ok: true,
            sites: SITE_INDEX.size,
            adapters: MANIFEST.adapters.length,
            upstream_sha: UPSTREAM_SHA
        });
    },
    'POST /list': routeList,
    'POST /describe': routeDescribe,
    'POST /run': routeRun
};

async function handleRequest(req, res) {
    const key = req.method + ' ' + req.url.split('?')[0];
    const handler = ROUTES[key];
    if (!handler) {
        return json(res, 404, { ok: false, error: 'not found' });
    }
    if (key !== 'GET /health' && !authenticate(req)) {
        // Layer-7 audit log: signal every bad Bearer so Console.app
        // can pair a rejected call with the Swift-side dispatch log.
        process.stderr.write('[opencli] openclicky.opencli.auth_reject reason=bad_bearer path=' + key + '\n');
        return json(res, 401, { ok: false, error: 'unauthorized' });
    }
    if (req.method === 'POST') {
        const raw = await readBody(req);
        try { req.parsedBody = raw ? JSON.parse(raw) : {}; }
        catch (e) { return json(res, 400, { ok: false, error: 'invalid json body' }); }
    }
    try { await handler(req, res); }
    catch (e) {
        process.stderr.write(`[opencli] handler error: ${e.stack || e}\n`);
        json(res, 500, { ok: false, error: (e && e.message) || String(e) });
    }
}

// --- port allocation --------------------------------------------------------

function pickPort() {
    const span = Math.max(1, PORT_MAX - PORT_MIN);
    return PORT_MIN + Math.floor(Math.random() * span);
}

function startServer(attempt) {
    if (attempt > 10) {
        process.stderr.write('[opencli] no free port in range\n');
        process.exit(2);
    }
    const port = pickPort();
    const server = http.createServer(handleRequest);
    server.on('error', (e) => {
        if (e.code === 'EADDRINUSE') {
            setTimeout(() => startServer(attempt + 1), 20);
        } else {
            process.stderr.write(`[opencli] listen error: ${e.message}\n`);
            process.exit(1);
        }
    });
    server.listen(port, '127.0.0.1', () => {
        process.stderr.write(`[opencli] serving ${MANIFEST.adapters.length} adapters across ${SITE_INDEX.size} sites on 127.0.0.1:${port}\n`);
        process.stdout.write(`READY ${port}\n`);
    });
    process.on('SIGTERM', () => { server.close(() => process.exit(0)); });
    process.on('SIGINT',  () => { server.close(() => process.exit(0)); });
}

startServer(1);
