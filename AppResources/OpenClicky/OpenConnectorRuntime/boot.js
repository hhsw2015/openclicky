#!/usr/bin/env node
/*
 * OpenClicky Open-Connector Runtime — Node.js boot entry point.
 *
 * Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
 * open-connector upstream pin: 847efc10cdff5d6c50b9905ac05c663246f70684
 *
 * Runs as a subprocess of the OpenClicky macOS app. Binds a loopback
 * HTTP server on a random port in the OPENCLICKY_CONNECTOR_PORT_MIN /
 * PORT_MAX range, authenticates every request against
 * OPENCLICKY_CONNECTOR_TOKEN, and exposes the six operations that back
 * the connector_* MCP tools:
 *
 *   GET  /health
 *   POST /providers            → connector_list
 *   POST /describe             → connector_describe
 *   POST /run                  → connector_run
 *   POST /oauth_authorize      → connector_connect (OAuth kickoff)
 *   POST /internal/oauth_complete    (called by Swift OAuth callback)
 *
 * PHASE 7.5 SCOPE (POC): this boot.js loads the vendored
 * open-connector `dist/connector-manifest.json` if present. When not
 * present, it seeds a minimal in-memory manifest with the two
 * providers whose TypeScript sources are guaranteed to be on disk —
 * `github` (verified by `docs/specs/everywhere-connector.md` §1) and
 * a `no_auth_demo` sanity provider. Real bundle production happens
 * in a follow-up (matches Everywhere's Phase 1 → Phase 9 rollout).
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
const crypto = require('crypto');

const TOKEN = process.env.OPENCLICKY_CONNECTOR_TOKEN || '';
const PORT_MIN = parseInt(process.env.OPENCLICKY_CONNECTOR_PORT_MIN || '52000', 10);
const PORT_MAX = parseInt(process.env.OPENCLICKY_CONNECTOR_PORT_MAX || '53000', 10);
const OAUTH_CALLBACK = process.env.OPENCLICKY_CONNECTOR_OAUTH_CALLBACK || '';
const RUNTIME_ROOT = process.env.OPENCLICKY_CONNECTOR_ROOT || __dirname;

const UPSTREAM_SHA = '847efc10cdff5d6c50b9905ac05c663246f70684';
const QUERY_CAP = 60;

// --- manifest loader --------------------------------------------------------

function readTextFileSafe(p) {
    try { return fs.readFileSync(p, 'utf8'); } catch (_) { return null; }
}

function loadManifest() {
    // 1. Bundled dist/connector-manifest.json (produced by esbuild bundle
    //    step; not present in a source-only checkout).
    const distManifest = path.join(RUNTIME_ROOT, 'open-connector', 'dist', 'connector-manifest.json');
    const distText = readTextFileSafe(distManifest);
    if (distText) {
        try {
            const parsed = JSON.parse(distText);
            if (Array.isArray(parsed.services)) return { services: parsed.services, source: 'dist' };
        } catch (e) {
            process.stderr.write(`[connector] failed to parse dist manifest: ${e.message}\n`);
        }
    }

    // 2. Fallback: minimal seeded manifest so the 6-tool surface is
    //    still exercisable end-to-end.
    return {
        source: 'seed',
        services: [
            {
                service: 'github',
                displayName: 'GitHub',
                categories: ['Developer Tools'],
                authTypes: ['oauth2', 'api_key'],
                homepageUrl: 'https://github.com',
                auth: [
                    {
                        type: 'oauth2',
                        authorizationUrl: 'https://github.com/login/oauth/authorize',
                        tokenUrl: 'https://github.com/login/oauth/access_token',
                        scopes: ['read:user', 'repo'],
                        tokenEndpointAuthMethod: 'client_secret_post'
                    },
                    {
                        type: 'api_key',
                        label: 'Personal access token',
                        placeholder: 'github_pat_...',
                        description: 'GitHub PAT used with the Authorization Bearer header.'
                    }
                ],
                actions: [
                    {
                        id: 'get_current_user',
                        name: 'get_current_user',
                        description: 'Return the authenticated user.',
                        requiredScopes: ['read:user'],
                        inputSchema: { type: 'object', properties: {}, required: [] },
                        outputSchema: null
                    },
                    {
                        id: 'list_repositories',
                        name: 'list_repositories',
                        description: 'List repositories for the authenticated user.',
                        requiredScopes: ['repo'],
                        inputSchema: { type: 'object', properties: { perPage: { type: 'integer' }, page: { type: 'integer' } } },
                        outputSchema: null
                    }
                ]
            },
            {
                service: 'no_auth_demo',
                displayName: 'No-auth demo',
                categories: ['Debug'],
                authTypes: [],
                homepageUrl: '',
                auth: [],
                actions: [
                    {
                        id: 'echo',
                        name: 'echo',
                        description: 'Echo back the arguments. Debug-only.',
                        requiredScopes: [],
                        inputSchema: { type: 'object', properties: { value: { type: 'string' } } },
                        outputSchema: { type: 'object', properties: { value: { type: 'string' } } }
                    }
                ]
            }
        ]
    };
}

const MANIFEST = loadManifest();

// --- executor registry ------------------------------------------------------

// Executors for the seeded providers. Real bundle mode replaces this
// with the esbuild-bundled `globalThis.__connectorProviders` map.
const EXECUTORS = {
    github: {
        get_current_user: async (args, credential) => {
            const token = credential && (credential.access_token || credential.api_key);
            if (!token) {
                return { ok: false, code: 'authorization_failed',
                         error: 'Configure github API key credentials first.',
                         hint: 'Call connector_connect(service:"github", api_key:"<PAT>")' };
            }
            const res = await fetchJson('https://api.github.com/user', {
                headers: {
                    'Authorization': 'Bearer ' + token,
                    'Accept': 'application/vnd.github+json',
                    'User-Agent': 'OpenClicky-Connector/1.0'
                }
            });
            if (!res.ok) {
                return {
                    ok: false,
                    code: res.status === 401 ? 'authorization_failed' : 'provider_error',
                    error: `GitHub /user returned ${res.status}: ${res.text.slice(0, 200)}`
                };
            }
            return { ok: true, data: safeParseJson(res.text) };
        },
        list_repositories: async (args, credential) => {
            const token = credential && (credential.access_token || credential.api_key);
            if (!token) {
                return { ok: false, code: 'authorization_failed',
                         error: 'Configure github API key credentials first.' };
            }
            const perPage = Math.min(100, Math.max(1, parseInt(args.perPage || 30, 10)));
            const page = Math.max(1, parseInt(args.page || 1, 10));
            const url = `https://api.github.com/user/repos?per_page=${perPage}&page=${page}&sort=updated`;
            const res = await fetchJson(url, {
                headers: {
                    'Authorization': 'Bearer ' + token,
                    'Accept': 'application/vnd.github+json',
                    'User-Agent': 'OpenClicky-Connector/1.0'
                }
            });
            if (!res.ok) {
                return {
                    ok: false,
                    code: res.status === 401 ? 'authorization_failed' : 'provider_error',
                    error: `GitHub /user/repos returned ${res.status}: ${res.text.slice(0, 200)}`
                };
            }
            return { ok: true, data: safeParseJson(res.text) };
        }
    },
    no_auth_demo: {
        echo: async (args, _credential) => {
            return { ok: true, data: { value: (args && args.value) || '' } };
        }
    }
};

// --- minimal fetch (Node 18+ has global fetch; keep compat fallback) --------

async function fetchJson(url, init) {
    if (typeof fetch === 'function') {
        try {
            const r = await fetch(url, init);
            const text = await r.text();
            return { ok: r.ok, status: r.status, text };
        } catch (e) {
            return { ok: false, status: 0, text: e.message || 'fetch failed' };
        }
    }
    // Very old Node fallback: bail out with a clear message.
    return { ok: false, status: 0, text: 'Node built-in fetch unavailable; upgrade to Node 18+.' };
}

function safeParseJson(text) {
    try { return JSON.parse(text); } catch (_) { return text; }
}

// --- OAuth pending state (subprocess side) ----------------------------------

const OAUTH_CLIENTS = {};   // provider → {client_id, client_secret, redirect_uri}
const OAUTH_STATES = {};    // state → {provider, connection, code_verifier}

function nextState() {
    return crypto.randomBytes(16).toString('hex');
}

// --- HTTP wiring -----------------------------------------------------------

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

function findService(serviceName) {
    if (!serviceName) return null;
    const needle = serviceName.trim().toLowerCase();
    return MANIFEST.services.find((s) => s.service.toLowerCase() === needle) || null;
}

async function routeProviders(req, res) {
    const body = req.parsedBody || {};
    const service = body.service && String(body.service).trim();
    const query = body.query && String(body.query).trim();

    if (service) {
        const svc = findService(service);
        if (!svc) {
            return json(res, 200, {
                schema_version: '1', ok: false,
                service, code: 'RUNTIME_NOT_FOUND',
                error: `service '${service}' not in catalog`,
                upstream_sha: UPSTREAM_SHA
            });
        }
        return json(res, 200, {
            schema_version: '1', ok: true,
            service: svc.service,
            displayName: svc.displayName,
            categories: svc.categories || [],
            authTypes: svc.authTypes || [],
            homepageUrl: svc.homepageUrl || '',
            actions: (svc.actions || []).map((a) => ({
                id: a.id, name: a.name, description: a.description,
                requiredScopes: a.requiredScopes || []
            })),
            upstream_sha: UPSTREAM_SHA
        });
    }

    if (query) {
        const q = query.toLowerCase();
        const matches = [];
        for (const svc of MANIFEST.services) {
            for (const a of (svc.actions || [])) {
                if (svc.service.toLowerCase().includes(q)
                    || a.name.toLowerCase().includes(q)
                    || (a.description || '').toLowerCase().includes(q)) {
                    matches.push({ service: svc.service, name: a.name, description: a.description });
                }
            }
        }
        const shown = matches.slice(0, QUERY_CAP);
        return json(res, 200, {
            schema_version: '1', ok: true, mode: 'query', query,
            matches: shown, total_matches: matches.length,
            truncated: matches.length > QUERY_CAP,
            upstream_sha: UPSTREAM_SHA
        });
    }

    // Default index.
    const services = [...MANIFEST.services].sort((a, b) => a.service.localeCompare(b.service));
    return json(res, 200, {
        schema_version: '1', ok: true, mode: 'index',
        services: services.map((s) => ({
            service: s.service,
            displayName: s.displayName,
            actionCount: (s.actions || []).length,
            authTypes: s.authTypes || []
        })),
        total_services: services.length,
        hint: 'call connector_list({service:"<name>"}) to drill in, or connector_list({query:"<text>"}) for fuzzy search',
        upstream_sha: UPSTREAM_SHA
    });
}

async function routeDescribe(req, res) {
    const body = req.parsedBody || {};
    const service = body.service && String(body.service);
    const name = body.name && String(body.name);
    if (!service || !name) {
        return json(res, 200, {
            schema_version: '1', ok: false, service, name,
            code: 'invalid_input',
            error: 'connector_describe requires service and name'
        });
    }
    const svc = findService(service);
    if (!svc) {
        return json(res, 200, {
            schema_version: '1', ok: false, service, name,
            code: 'RUNTIME_NOT_FOUND',
            error: `service '${service}' not in catalog`
        });
    }
    const action = (svc.actions || []).find(a => a.name.toLowerCase() === name.toLowerCase());
    if (!action) {
        return json(res, 200, {
            schema_version: '1', ok: false, service, name,
            code: 'RUNTIME_NOT_FOUND',
            error: `action '${service}.${name}' not in catalog`
        });
    }
    return json(res, 200, {
        schema_version: '1', ok: true,
        service: svc.service, name: action.name, id: action.id,
        description: action.description,
        requiredScopes: action.requiredScopes || [],
        inputSchema: action.inputSchema || null,
        outputSchema: action.outputSchema || null,
        upstream_sha: UPSTREAM_SHA
    });
}

async function routeRun(req, res) {
    const body = req.parsedBody || {};
    const service = body.service;
    const name = body.name;
    const args = body.arguments || {};
    const credential = body.credential || null;
    if (!service || !name) {
        return json(res, 200, {
            schema_version: '1', ok: false, service, name,
            code: 'invalid_input', error: 'run requires service and name'
        });
    }
    const svc = findService(service);
    if (!svc) {
        return json(res, 200, {
            schema_version: '1', ok: false, service, name,
            code: 'RUNTIME_NOT_FOUND',
            error: `service '${service}' not in catalog`
        });
    }
    const bundle = EXECUTORS[svc.service];
    const fn = bundle && bundle[name];
    if (!fn) {
        return json(res, 200, {
            schema_version: '1', ok: false, service, name,
            code: 'RUNTIME_NOT_FOUND',
            error: `executor for '${service}.${name}' not bundled in this runtime build`,
            hint: 'Real 831-provider bundle is deferred; only seeded actions execute in this POC.'
        });
    }
    try {
        const result = await fn(args, credential);
        const out = Object.assign({ schema_version: '1', service, name }, result || {});
        if (typeof out.ok === 'undefined') out.ok = false;
        return json(res, 200, out);
    } catch (e) {
        return json(res, 200, {
            schema_version: '1', ok: false, service, name,
            code: 'provider_error',
            error: (e && e.message) || String(e)
        });
    }
}

async function routeOauthAuthorize(req, res) {
    const body = req.parsedBody || {};
    const service = body.service;
    const connection = body.connection || null;
    const svc = findService(service);
    if (!svc) {
        return json(res, 200, {
            schema_version: '1', ok: false, service,
            code: 'RUNTIME_NOT_FOUND',
            error: `service '${service}' not in catalog`
        });
    }
    const oauthDef = (svc.auth || []).find(a => a.type === 'oauth2');
    if (!oauthDef) {
        return json(res, 200, {
            schema_version: '1', ok: false, service,
            code: 'invalid_input',
            error: `service '${service}' does not support OAuth2`
        });
    }
    const client = OAUTH_CLIENTS[svc.service];
    if (!client) {
        return json(res, 200, {
            schema_version: '1', ok: false, service,
            code: 'authorization_failed',
            error: `OAuth client not configured for '${service}'. Register client_id/client_secret first (Phase 3).`,
            hint: 'OAuth client configuration UI is deferred to a follow-up milestone.'
        });
    }
    const state = nextState();
    OAUTH_STATES[state] = { provider: svc.service, connection, createdAt: Date.now() };
    const redirect = OAUTH_CALLBACK || '';
    const scopes = (oauthDef.scopes || []).join(' ');
    const url = new URL(oauthDef.authorizationUrl);
    url.searchParams.set('client_id', client.client_id);
    if (redirect) url.searchParams.set('redirect_uri', redirect);
    url.searchParams.set('response_type', 'code');
    if (scopes) url.searchParams.set('scope', scopes);
    url.searchParams.set('state', state);
    return json(res, 200, {
        schema_version: '1', ok: true, service: svc.service,
        auth_type: 'oauth2',
        authorization_url: url.toString(),
        state
    });
}

async function routeOauthComplete(req, res) {
    const body = req.parsedBody || {};
    const state = body.state;
    const code = body.code;
    const pending = state && OAUTH_STATES[state];
    if (!pending) {
        return json(res, 200, { ok: false, code: 'invalid_input', error: 'unknown or expired state' });
    }
    delete OAUTH_STATES[state];
    // NOTE: real token exchange is deferred to when OAuth client
    // config lands (Phase 3 in Everywhere terms). We record the
    // provisional record so the Swift-side callback UX completes.
    return json(res, 200, {
        ok: true,
        service: pending.provider,
        connection: pending.connection,
        note: 'OAuth token exchange stub — real client credentials + refresh land in follow-up.',
        auth_code_received: !!code
    });
}

const ROUTES = {
    'GET /health': async (req, res) => {
        return json(res, 200, {
            ok: true,
            providers: MANIFEST.services.length,
            manifest_source: MANIFEST.source,
            upstream_sha: UPSTREAM_SHA,
            oauth_callback: OAUTH_CALLBACK || null
        });
    },
    'POST /providers': routeProviders,
    'POST /describe': routeDescribe,
    'POST /run': routeRun,
    'POST /oauth_authorize': routeOauthAuthorize,
    'POST /internal/oauth_complete': routeOauthComplete
};

async function handleRequest(req, res) {
    const key = req.method + ' ' + req.url.split('?')[0];
    const handler = ROUTES[key];
    if (!handler) {
        return json(res, 404, { ok: false, error: 'not found' });
    }
    // Health endpoint is auth-free so the Swift side can probe before
    // it starts sending Authorization headers.
    if (key !== 'GET /health' && !authenticate(req)) {
        // Layer-7 audit log: signal every bad Bearer so Console.app
        // can pair a rejected call with the Swift-side dispatch log.
        // Never log the offered token, only the reason class.
        process.stderr.write('[connector] openclicky.connector.auth_reject reason=bad_bearer path=' + key + '\n');
        return json(res, 401, { ok: false, error: 'unauthorized' });
    }
    if (req.method === 'POST') {
        const raw = await readBody(req);
        try { req.parsedBody = raw ? JSON.parse(raw) : {}; }
        catch (e) { return json(res, 400, { ok: false, error: 'invalid json body' }); }
    }
    try { await handler(req, res); }
    catch (e) {
        process.stderr.write(`[connector] handler error: ${e.stack || e}\n`);
        json(res, 500, { ok: false, error: (e && e.message) || String(e) });
    }
}

// --- port allocation --------------------------------------------------------

function pickPort() {
    // Deterministic random in [MIN, MAX). Node's server.listen(0) would
    // also work, but keeping the port in a stable range makes debugging
    // curl commands easier.
    const span = Math.max(1, PORT_MAX - PORT_MIN);
    return PORT_MIN + Math.floor(Math.random() * span);
}

function startServer(attempt) {
    if (attempt > 10) {
        process.stderr.write('[connector] no free port in range\n');
        process.exit(2);
    }
    const port = pickPort();
    const server = http.createServer(handleRequest);
    server.on('error', (e) => {
        if (e.code === 'EADDRINUSE') {
            setTimeout(() => startServer(attempt + 1), 20);
        } else {
            process.stderr.write(`[connector] listen error: ${e.message}\n`);
            process.exit(1);
        }
    });
    server.listen(port, '127.0.0.1', () => {
        process.stdout.write(`READY ${port}\n`);
    });
    process.on('SIGTERM', () => { server.close(() => process.exit(0)); });
    process.on('SIGINT',  () => { server.close(() => process.exit(0)); });
}

startServer(1);
