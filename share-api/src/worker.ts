interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
}

interface ShareRow {
  id: string;
  schema_version: number;
  algorithm: string;
  iv: string;
  ciphertext: string;
  revoke_token_hash: string;
  created_at: string;
  expires_at: string;
  revoked_at: string | null;
  view_count: number;
  max_views: number | null;
  last_viewed_at: string | null;
}

interface RateLimitRow {
  window_start: number;
  request_count: number;
}

const MAX_CIPHERTEXT_BYTES = 256 * 1024;
const MAX_CIPHERTEXT_B64 = Math.floor(MAX_CIPHERTEXT_BYTES * 4 / 3) + 4;
const MAX_LIFETIME_MS = 30 * 24 * 60 * 60 * 1000;
const RATE_LIMIT_WINDOW_MS = 60 * 1000;
const RATE_LIMIT_REQUESTS = 60;
const RATE_LIMIT_CREATE_REQUESTS = 10;
const EXPIRED_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const REVOKED_RETENTION_MS = 24 * 60 * 60 * 1000;
const SHARE_ID_RE = /^[A-Za-z0-9_-]{20,64}$/;
const BASE64URL_RE = /^[A-Za-z0-9_-]+$/;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function errorResponse(status: number, message: string): Response {
  return json({ error: message }, status);
}

function rateLimitedResponse(): Response {
  return new Response(JSON.stringify({ error: "rate limit exceeded" }), {
    status: 429,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "Retry-After": "60",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function isoDate(value: Date): string {
  return value.toISOString().replace(".000Z", "Z");
}

function parseDate(value: unknown): Date | null {
  if (typeof value !== "string") return null;
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) return null;
  return new Date(timestamp);
}

function decodeBase64URL(value: string): Uint8Array | null {
  try {
    const normalized = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
    const binary = atob(normalized);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

function validBase64URL(value: unknown, maxLength = MAX_CIPHERTEXT_B64, exactLength?: number): value is string {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength || !BASE64URL_RE.test(value)) return false;
  const decoded = decodeBase64URL(value);
  return decoded !== null && (exactLength === undefined || decoded.length === exactLength);
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function consumeRateLimit(request: Request, env: Env, scope: string, maxRequests: number): Promise<boolean> {
  const client = request.headers.get("CF-Connecting-IP") || "anonymous";
  const key = await sha256Hex(`password-entry:${scope}:${client}`);
  const windowStart = Math.floor(Date.now() / RATE_LIMIT_WINDOW_MS) * RATE_LIMIT_WINDOW_MS;
  const row = await env.DB.prepare("SELECT window_start, request_count FROM rate_limits WHERE key = ?").bind(key).first<RateLimitRow>();
  if (!row || row.window_start !== windowStart) {
    await env.DB.prepare("INSERT INTO rate_limits (key, window_start, request_count) VALUES (?, ?, 1) ON CONFLICT(key) DO UPDATE SET window_start = excluded.window_start, request_count = 1").bind(key, windowStart).run();
    return true;
  }
  if (row.request_count >= maxRequests) return false;
  await env.DB.prepare("UPDATE rate_limits SET request_count = request_count + 1 WHERE key = ? AND window_start = ?").bind(key, windowStart).run();
  return true;
}

async function cleanupStorage(env: Env): Promise<void> {
  const now = Date.now();
  const expiredCutoff = isoDate(new Date(now - EXPIRED_RETENTION_MS));
  const revokedCutoff = isoDate(new Date(now - REVOKED_RETENTION_MS));
  const oldWindow = Math.floor((now - RATE_LIMIT_WINDOW_MS * 2) / RATE_LIMIT_WINDOW_MS) * RATE_LIMIT_WINDOW_MS;
  await env.DB.batch([
    env.DB.prepare("DELETE FROM shares WHERE expires_at < ? OR (revoked_at IS NOT NULL AND revoked_at < ?)").bind(expiredCutoff, revokedCutoff),
    env.DB.prepare("DELETE FROM rate_limits WHERE window_start < ?").bind(oldWindow),
  ]);
}

function sharePageRequest(request: Request): Request {
  const assetURL = new URL("/share.html", request.url);
  return new Request(assetURL, { method: "GET", headers: request.headers });
}

async function createShare(request: Request, env: Env): Promise<Response> {
  const contentLength = Number(request.headers.get("Content-Length") || 0);
  if (contentLength > MAX_CIPHERTEXT_B64 + 4096) return errorResponse(413, "share payload too large");

  let body: Record<string, unknown>;
  try {
    const text = await request.text();
    if (text.length > MAX_CIPHERTEXT_B64 + 4096) return errorResponse(413, "share payload too large");
    const parsed: unknown = JSON.parse(text);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return errorResponse(400, "invalid JSON");
    body = parsed as Record<string, unknown>;
  } catch {
    return errorResponse(400, "invalid JSON");
  }

  const shareID = body.shareId;
  const schemaVersion = body.schemaVersion;
  const algorithm = body.algorithm;
  const iv = body.iv;
  const ciphertext = body.ciphertext;
  const expiresAt = parseDate(body.expiresAt);
  const revokeTokenHash = body.revokeTokenHash;
  const now = new Date();

  if (typeof shareID !== "string" || !SHARE_ID_RE.test(shareID)) return errorResponse(400, "invalid share payload");
  if (schemaVersion !== 1 || algorithm !== "A256GCM") return errorResponse(400, "invalid share payload");
  if (!validBase64URL(iv, 128, 12) || !validBase64URL(ciphertext)) return errorResponse(400, "invalid share payload");
  if (typeof revokeTokenHash !== "string" || !/^[0-9a-f]{64}$/.test(revokeTokenHash)) return errorResponse(400, "invalid share payload");
  if (!expiresAt || expiresAt <= now || expiresAt.getTime() > now.getTime() + MAX_LIFETIME_MS) return errorResponse(400, "invalid share payload");

  try {
    await env.DB.prepare(
      "INSERT INTO shares (id, schema_version, algorithm, iv, ciphertext, revoke_token_hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    ).bind(shareID, schemaVersion, algorithm, iv, ciphertext, revokeTokenHash, isoDate(now), isoDate(expiresAt)).run();
    return json({ shareId: shareID, expiresAt: isoDate(expiresAt) }, 201);
  } catch (error) {
    const message = String(error).toLowerCase();
    if (message.includes("unique") || message.includes("constraint")) return errorResponse(409, "share id already exists");
    return errorResponse(500, "share service unavailable");
  }
}

async function getShare(shareID: string, env: Env): Promise<Response> {
  try {
    const row = await env.DB.prepare("SELECT * FROM shares WHERE id = ?").bind(shareID).first<ShareRow>();
    if (!row) return errorResponse(404, "share not found");
    const now = new Date();
    if (row.revoked_at !== null || new Date(row.expires_at) <= now) return errorResponse(410, "share expired or revoked");
    if (row.max_views !== null && row.view_count >= row.max_views) return errorResponse(410, "share view limit reached");
    await env.DB.prepare("UPDATE shares SET view_count = view_count + 1, last_viewed_at = ? WHERE id = ?").bind(isoDate(now), shareID).run();
    return json({
      schemaVersion: row.schema_version,
      algorithm: row.algorithm,
      iv: row.iv,
      ciphertext: row.ciphertext,
      expiresAt: row.expires_at,
    });
  } catch {
    return errorResponse(500, "share service unavailable");
  }
}

async function revokeShare(shareID: string, request: Request, env: Env): Promise<Response> {
  const revokeToken = request.headers.get("X-Revoke-Token") || "";
  const revokeTokenHash = await sha256Hex(revokeToken);
  try {
    const result = await env.DB.prepare(
      "UPDATE shares SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL AND revoke_token_hash = ?",
    ).bind(isoDate(new Date()), shareID, revokeTokenHash).run();
    if (!result.meta.changes) return errorResponse(404, "share not found or token invalid");
    return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
  } catch {
    return errorResponse(500, "share service unavailable");
  }
}

async function api(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, X-Revoke-Token",
        "Access-Control-Max-Age": "600",
      },
    });
  }
  const scope = request.method === "POST" ? "create" : "api";
  const limit = request.method === "POST" ? RATE_LIMIT_CREATE_REQUESTS : RATE_LIMIT_REQUESTS;
  if (!(await consumeRateLimit(request, env, scope, limit))) return rateLimitedResponse();
  await cleanupStorage(env);
  if (request.method === "POST" && url.pathname === "/v1/shares") return createShare(request, env);
  const match = url.pathname.match(/^\/v1\/shares\/([A-Za-z0-9_-]+)$/);
  if (!match) return errorResponse(404, "not found");
  if (request.method === "GET") return getShare(match[1], env);
  if (request.method === "DELETE") return revokeShare(match[1], request, env);
  return errorResponse(405, "method not allowed");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/v1/")) return api(request, env);
    if (url.pathname.match(/^\/s\/[A-Za-z0-9_-]{20,64}$/)) return env.ASSETS.fetch(sharePageRequest(request));
    return env.ASSETS.fetch(request);
  },
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    await cleanupStorage(env);
  },
};
