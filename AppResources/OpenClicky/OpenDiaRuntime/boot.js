#!/usr/bin/env node
/*
 * OpenClicky OpenDia Runtime — Node.js boot entry point.
 *
 * Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
 * OpenDia upstream (MIT) pin: 304345754cc99b24c07a3289a2e27abd5a5c19bb
 *
 * Phase 7.6b F31. Same shape as OpenConnectorRuntime/boot.js and
 * OpenCLIRuntime/boot.js, so future maintainers only need to understand
 * one subprocess boot pattern. Two networking layers:
 *
 *   1. Loopback HTTP (Swift <-> Node)
 *        POST /health             (auth-free)
 *        POST /tools              -> list of tool names/descriptors from
 *                                    the extension's register frame
 *        POST /call               body: {name, arguments, timeout_ms?}
 *                                    forwards to extension, awaits
 *                                    matched-id response, replies with
 *                                    the extension's result envelope.
 *      All non-health routes require `Authorization: Bearer <token>`
 *      where <token> is OPENCLICKY_OPENDIA_TOKEN (per-launch UUID).
 *
 *   2. WebSocket server (Node <-> extension)
 *        The Chrome/Firefox extension connects to
 *        ws://127.0.0.1:<port>/ (same port as HTTP — Node dispatches
 *        based on Upgrade header). Protocol matches Everywhere's
 *        OpenDiaBridge.cs 1:1:
 *          - register frame:  {type:"register", tools:[...]}
 *          - tool call out:   {id, method, params}
 *          - tool response:   {id, result} | {id, error}
 *          - server-push:     {type, ...} with no id (dropped for
 *                             now — Phase 7.6b does not surface push).
 *          - keepalive:       server->ext every 20s: {type:"ping",...}
 *
 * Announcement contract with the Swift subprocess manager:
 *   * Prints exactly "READY <port>\n" on stdout the moment the server
 *     is listening.
 *   * Prints diagnostic lines to stderr only.
 *   * Exits cleanly on SIGTERM/SIGINT.
 */

'use strict';

const http = require('http');
const path = require('path');

// The WS server needs the `ws` npm package. We vendor a copy under
// OpenDiaRuntime/node_modules/ws/ so this runtime is self-contained
// and requires zero on-first-launch install step. Two additional
// fallbacks kept for dev / partial-install scenarios.
const VENDORED_WS_PATH = path.join(__dirname, 'node_modules', 'ws');
const OPENDIA_MCP_WS_PATH = path.join(__dirname, 'opendia-mcp', 'node_modules', 'ws');

let WebSocketServer = null;
for (const candidate of [VENDORED_WS_PATH, OPENDIA_MCP_WS_PATH, 'ws']) {
    try {
        // eslint-disable-next-line global-require
        WebSocketServer = require(candidate).Server;
        break;
    } catch (_e) {
        // try next candidate
    }
}
if (!WebSocketServer) {
    process.stderr.write(
        '[opendia] ws module missing. Reinstall OpenClicky to restore ' +
        'the vendored runtime at AppResources/OpenClicky/OpenDiaRuntime/' +
        'node_modules/ws/.\n'
    );
    process.exit(3);
}

const TOKEN = process.env.OPENCLICKY_OPENDIA_TOKEN || '';
const PORT_MIN = parseInt(process.env.OPENCLICKY_OPENDIA_PORT_MIN || '56000', 10);
const PORT_MAX = parseInt(process.env.OPENCLICKY_OPENDIA_PORT_MAX || '57000', 10);

const UPSTREAM_SHA = '304345754cc99b24c07a3289a2e27abd5a5c19bb';

// --- extension state --------------------------------------------------------

let extSocket = null;
let availableTools = [];
const pending = new Map();   // id -> { resolve, reject, timer }
let callIdCounter = 0;

function nextId() {
    callIdCounter += 1;
    return String(Date.now()) + '-' + String(callIdCounter);
}

function extConnected() {
    return extSocket !== null && extSocket.readyState === 1; // OPEN
}

function safeSend(msg) {
    if (!extConnected()) return false;
    try {
        extSocket.send(JSON.stringify(msg));
        return true;
    } catch (e) {
        process.stderr.write(`[opendia] ws send failed: ${e.message}\n`);
        return false;
    }
}

// --- HTTP handling ----------------------------------------------------------

function json(res, status, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(status, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
}

function authenticate(req) {
    const hdr = req.headers['authorization'] || '';
    return hdr === 'Bearer ' + TOKEN;
}

function readBody(req) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let size = 0;
        req.on('data', (c) => {
            size += c.length;
            if (size > 8 * 1024 * 1024) {
                req.destroy();
                reject(new Error('body too large'));
                return;
            }
            chunks.push(c);
        });
        req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        req.on('error', reject);
    });
}

async function handleHttp(req, res) {
    const url = req.url.split('?')[0];
    const key = req.method + ' ' + url;

    // Health endpoint is auth-free so the Swift side can probe before
    // it starts sending Authorization headers.
    if (key === 'GET /health' || key === 'POST /health') {
        return json(res, 200, {
            ok: true,
            extension_connected: extConnected(),
            available_tools: availableTools.length,
            upstream_sha: UPSTREAM_SHA,
        });
    }

    if (!authenticate(req)) {
        // Layer-7 audit log: signal every bad Bearer so Console.app
        // can pair a rejected call with the Swift-side dispatch log.
        process.stderr.write('[opendia] openclicky.opendia.auth_reject reason=bad_bearer path=' + key + '\n');
        return json(res, 401, { ok: false, error: 'unauthorized' });
    }

    if (key === 'POST /tools' || key === 'GET /tools') {
        return json(res, 200, {
            ok: true,
            extension_connected: extConnected(),
            tools: availableTools,
        });
    }

    if (key === 'POST /call') {
        let raw;
        try { raw = await readBody(req); }
        catch (e) { return json(res, 413, { ok: false, error: e.message }); }
        let body;
        try { body = raw ? JSON.parse(raw) : {}; }
        catch (_e) { return json(res, 400, { ok: false, error: 'invalid json body' }); }

        const name = String(body.name || '').trim();
        if (!name) {
            return json(res, 400, { ok: false, code: 'BAD_ARGS', error: 'name required' });
        }
        if (!extConnected()) {
            return json(res, 200, {
                ok: false,
                code: 'BROWSER_NOT_READY',
                error: 'OpenDia browser extension not connected. Install the extension in Chrome/Firefox — see AppResources/OpenClicky/OpenDiaRuntime/README.md.',
            });
        }
        const argsObj = (body.arguments && typeof body.arguments === 'object')
            ? body.arguments
            : {};
        const timeoutMs = Math.max(1000, Math.min(300000, parseInt(body.timeout_ms || 30000, 10)));

        const id = nextId();
        const sent = safeSend({ id: id, method: name, params: argsObj });
        if (!sent) {
            return json(res, 200, {
                ok: false,
                code: 'BROWSER_NOT_READY',
                error: 'extension socket dropped mid-send',
            });
        }
        try {
            const result = await new Promise((resolve, reject) => {
                const timer = setTimeout(() => {
                    if (pending.has(id)) {
                        pending.delete(id);
                        reject(new Error('extension response timeout after ' + timeoutMs + 'ms'));
                    }
                }, timeoutMs);
                pending.set(id, { resolve, reject, timer });
            });
            return json(res, 200, { ok: true, name: name, result: result });
        } catch (e) {
            return json(res, 200, {
                ok: false,
                code: 'PROVIDER_ERROR',
                error: e.message || String(e),
            });
        }
    }

    return json(res, 404, { ok: false, error: 'not found' });
}

// --- WebSocket wiring -------------------------------------------------------

function handleExtensionSocket(ws) {
    // Replace-on-reconnect semantics matches Everywhere OpenDiaBridge.cs.
    // Chrome MV3 service workers churn sockets aggressively, so we always
    // take the newest one and close the previous gracefully. Pending
    // tool calls are NOT rejected on replace — the extension may still
    // reply on the new socket with the same id.
    if (extSocket && extSocket !== ws) {
        try { extSocket.close(1000, 'replaced'); } catch (_e) {}
    }
    extSocket = ws;

    // 20s keepalive so the MV3 service worker idle timer keeps getting
    // reset (Chrome 124+: WS activity resets the SW idle deadline).
    const keepalive = setInterval(() => {
        if (!extConnected()) return;
        safeSend({ type: 'ping', timestamp: Date.now() });
    }, 20000);

    ws.on('message', (data) => {
        let msg;
        try { msg = JSON.parse(data.toString('utf8')); }
        catch (_e) { return; }
        if (!msg || typeof msg !== 'object') return;

        // Register frame: extension announces its tool list.
        if (msg.type === 'register') {
            availableTools = Array.isArray(msg.tools) ? msg.tools : [];
            process.stderr.write(
                `[opendia] extension registered ${availableTools.length} tools\n`
            );
            return;
        }

        // Pong or unrelated push — drop.
        if (msg.type === 'pong') return;

        // Server-push frames (chat_appended, chat_deleted, etc). Phase
        // 7.6b does not surface them; drop with a diagnostic so we can
        // trace missing events during bring-up.
        // TODO: bridge server-push frames to Swift subscribers.
        // Everywhere's OpenDiaBridge.cs streams these to Cebian's chat
        // store — openclicky needs an equivalent NotificationCenter /
        // pub-sub wire before F32/chat-bus work lands.
        if (msg.type && !msg.id) {
            process.stderr.write(
                `[opendia] dropping server-push frame type=${msg.type}\n`
            );
            return;
        }

        // Tool response — match by id.
        const id = msg.id;
        if (!id) return;
        const p = pending.get(id);
        if (!p) return;
        pending.delete(id);
        clearTimeout(p.timer);

        if (msg.error) {
            const em = (msg.error && typeof msg.error === 'object')
                ? (msg.error.message || JSON.stringify(msg.error))
                : String(msg.error);
            p.reject(new Error(em));
            return;
        }
        p.resolve(msg.result);
    });

    ws.on('close', () => {
        clearInterval(keepalive);
        // Only clear if THIS socket is still the active one (defence
        // against stale-close events for already-replaced sockets).
        if (extSocket === ws) {
            extSocket = null;
            availableTools = [];
            for (const [id, p] of pending.entries()) {
                clearTimeout(p.timer);
                p.reject(new Error('OpenDia extension disconnected mid-call'));
                pending.delete(id);
            }
        }
    });

    ws.on('error', (e) => {
        process.stderr.write(`[opendia] ws error: ${e.message}\n`);
    });
}

// --- port + server bring-up -------------------------------------------------

function pickPort() {
    const span = Math.max(1, PORT_MAX - PORT_MIN);
    return PORT_MIN + Math.floor(Math.random() * span);
}

function startServer(attempt) {
    if (attempt > 10) {
        process.stderr.write('[opendia] no free port in range\n');
        process.exit(2);
    }
    const port = pickPort();
    const server = http.createServer(handleHttp);

    // Attach WS server to the HTTP listener so we only need one port.
    // Accept any path so the extension can connect at '/', '/opendia',
    // or whatever discovery URL it selects — Everywhere's OpenDiaBridge
    // binds broadly and we should match to stay drop-in compatible.
    const wss = new WebSocketServer({ noServer: true });
    server.on('upgrade', (req, socket, head) => {
        wss.handleUpgrade(req, socket, head, (ws) => {
            wss.emit('connection', ws, req);
        });
    });
    wss.on('connection', handleExtensionSocket);
    wss.on('error', (e) => {
        process.stderr.write(`[opendia] wss error: ${e.message}\n`);
    });

    server.on('error', (e) => {
        if (e.code === 'EADDRINUSE') {
            setTimeout(() => startServer(attempt + 1), 20);
        } else {
            process.stderr.write(`[opendia] listen error: ${e.message}\n`);
            process.exit(1);
        }
    });
    server.listen(port, '127.0.0.1', () => {
        process.stdout.write(`READY ${port}\n`);
    });
    const shutdown = () => {
        try { wss.close(); } catch (_e) {}
        server.close(() => process.exit(0));
        setTimeout(() => process.exit(0), 1500).unref();
    };
    process.on('SIGTERM', shutdown);
    process.on('SIGINT', shutdown);
}

startServer(1);
