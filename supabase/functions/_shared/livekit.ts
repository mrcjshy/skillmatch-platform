// ============================================================
// RF-02 / D-011 — LiveKit server helpers (Web Crypto only, no SDK)
// ============================================================
//
// Server-side only. The API secret never leaves the Edge Function; clients
// receive only short-lived, single-room join tokens.
//
// ponytail: hand-rolled HS256 + Twirp JSON instead of npm:livekit-server-sdk.
// The surface used here is five RoomService calls and two token shapes; the
// SDK becomes worth it if more provider APIs are needed.
//
// Provider results are classified, never assumed:
//   ok        2xx
//   absent    404 (room/participant does not exist)
//   rejected  other 4xx except 408/429: definitive refusal
//   unknown   408, 429, 5xx, network error, timeout: outcome not known

export type ProviderResult =
  | { kind: "ok"; status: number; body: Record<string, unknown> }
  | { kind: "absent"; status: number }
  | { kind: "rejected"; status: number }
  | { kind: "unknown"; status: number | null };

const enc = new TextEncoder();
const JOIN_TTL_MAX_S = 300;
const ADMIN_TTL_S = 60;
const PROVIDER_TIMEOUT_MS = 8_000;

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function b64urlDecode(s: string): Uint8Array<ArrayBuffer> {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  return Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad), (c) => c.charCodeAt(0));
}

async function hmacKey(secret: string, usage: "sign" | "verify"): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [usage]);
}

async function signJwt(claims: Record<string, unknown>, secret: string): Promise<string> {
  const head = b64url(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = b64url(enc.encode(JSON.stringify(claims)));
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(secret, "sign"), enc.encode(`${head}.${body}`)));
  return `${head}.${body}.${b64url(sig)}`;
}

export function httpBaseUrl(url: string): string {
  return url.replace(/^wss:/, "https:").replace(/^ws:/, "http:").replace(/\/+$/, "");
}

/** Tokens issued before the cutoff are rejected on reconnect (LiveKit Cloud).
 * +1 s so a token minted in the same second as the revocation is covered. */
export function revokeCutoff(nowSeconds: number): number {
  return nowSeconds + 1;
}

export async function mintJoinToken(input: {
  apiKey: string;
  apiSecret: string;
  identity: string;
  room: string;
  nowSeconds: number;
  ttlSeconds?: number;
}): Promise<string> {
  const ttl = input.ttlSeconds ?? JOIN_TTL_MAX_S;
  if (!input.identity || !input.room || !(ttl > 0 && ttl <= JOIN_TTL_MAX_S)) {
    throw new Error("invalid join token request");
  }
  return signJwt({
    iss: input.apiKey,
    sub: input.identity,
    nbf: input.nowSeconds,
    exp: input.nowSeconds + ttl,
    video: {
      room: input.room,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: false,
      canPublishSources: ["camera", "microphone"],
      canUpdateOwnMetadata: false,
    },
  }, input.apiSecret);
}

export async function adminToken(input: {
  apiKey: string;
  apiSecret: string;
  nowSeconds: number;
  room?: string;
}): Promise<string> {
  return signJwt({
    iss: input.apiKey,
    sub: "skillmatch-server",
    nbf: input.nowSeconds,
    exp: input.nowSeconds + ADMIN_TTL_S,
    video: { roomCreate: true, roomList: true, roomAdmin: true, ...(input.room ? { room: input.room } : {}) },
  }, input.apiSecret);
}

export function classifyProviderResponse(status: number): ProviderResult {
  if (status >= 200 && status < 300) return { kind: "ok", status, body: {} };
  if (status === 404) return { kind: "absent", status };
  if (status === 408 || status === 429 || status >= 500) return { kind: "unknown", status };
  return { kind: "rejected", status };
}

export function roomService(cfg: {
  url: string;
  apiKey: string;
  apiSecret: string;
  fetch?: typeof fetch;
  nowSeconds?: () => number;
}) {
  const doFetch = cfg.fetch ?? fetch;
  const now = cfg.nowSeconds ?? (() => Math.floor(Date.now() / 1000));
  const base = `${httpBaseUrl(cfg.url)}/twirp/livekit.RoomService/`;

  async function call(method: string, body: Record<string, unknown>, room?: string): Promise<ProviderResult> {
    let response: Response;
    try {
      const token = await adminToken({ apiKey: cfg.apiKey, apiSecret: cfg.apiSecret, nowSeconds: now(), room });
      response = await doFetch(base + method, {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
      });
    } catch {
      return { kind: "unknown", status: null };
    }
    const result = classifyProviderResponse(response.status);
    if (result.kind !== "ok") {
      await response.body?.cancel();
      return result;
    }
    try {
      const parsed: unknown = await response.json();
      if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
        return { kind: "unknown", status: response.status };
      }
      return { kind: "ok", status: response.status, body: parsed as Record<string, unknown> };
    } catch {
      return { kind: "unknown", status: response.status };
    }
  }

  return {
    createRoom: (name: string) =>
      call("CreateRoom", { name, empty_timeout: 60, departure_timeout: 20, max_participants: 2 }),
    deleteRoom: (room: string) => call("DeleteRoom", { room }, room),
    listRooms: (names: string[]) => call("ListRooms", { names }),
    listParticipants: (room: string) => call("ListParticipants", { room }, room),
    removeParticipant: (room: string, identity: string, revokeTokenTs: number) =>
      call("RemoveParticipant", { room, identity, revoke_token_ts: revokeTokenTs }, room),
  };
}

export type RoomService = ReturnType<typeof roomService>;

/** Verifies a LiveKit webhook (HS256 JWT in Authorization, sha256 body claim).
 * Returns the parsed event, or null for anything not provably authentic. */
export async function verifyWebhook(input: {
  apiKey: string;
  apiSecret: string;
  authHeader: string | null;
  body: string;
  nowSeconds: number;
}): Promise<Record<string, unknown> | null> {
  try {
    const token = (input.authHeader ?? "").replace(/^Bearer\s+/i, "");
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    const header = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0])));
    if (header.alg !== "HS256") return null;
    const ok = await crypto.subtle.verify("HMAC", await hmacKey(input.apiSecret, "verify"),
      b64urlDecode(parts[2]), enc.encode(`${parts[0]}.${parts[1]}`));
    if (!ok) return null;
    const claims = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1])));
    const skew = 10;
    if (claims.iss !== input.apiKey) return null;
    if (typeof claims.exp !== "number" || claims.exp + skew < input.nowSeconds) return null;
    if (typeof claims.nbf === "number" && claims.nbf - skew > input.nowSeconds) return null;
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(input.body)));
    let raw = "";
    for (const b of digest) raw += String.fromCharCode(b);
    if (claims.sha256 !== btoa(raw)) return null;
    const event = JSON.parse(input.body);
    return typeof event === "object" && event !== null ? event : null;
  } catch {
    return null;
  }
}
