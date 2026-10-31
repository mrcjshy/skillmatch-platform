// ============================================================
// RF-02 / D-011 — privileged call maintenance shared by booking-call,
// booking-call-reconcile and livekit-webhook. Service-role RPCs only; no
// participant authorization here (that lives in rf02_start / rf02_act).
// ============================================================

import { revokeCutoff, type RoomService } from "./livekit.ts";

export type RpcError = { code?: string; message?: string } | null;
export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: RpcError }>;
export type CallDeps = { rpc: Rpc; rooms: RoomService; nowSeconds: () => number };
export type CallRef = { call_id: string; room_name: string; caller_id?: string; callee_id?: string; provision_attempts?: number };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class RpcFailure extends Error {
  constructor(readonly code: string | undefined) {
    super(`rpc failed${code ? ` (${code})` : ""}`);
  }
}

export async function rpcData<T>(deps: Pick<CallDeps, "rpc">, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await deps.rpc(fn, args);
  if (error) throw new RpcFailure(error.code);
  return data as T;
}

/** Is the room listed? true / false, or null when the listing itself is not known. */
function providerList(body: Record<string, unknown>, key: string, identityKey: string): Record<string, unknown>[] | null {
  const value = body[key];
  // Protobuf JSON may omit an empty repeated field; a present invalid field
  // or nameless entry is uncertainty, not evidence of an empty collection.
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.some((item) => typeof item !== "object" || item === null ||
    Array.isArray(item) || typeof item[identityKey] !== "string" || item[identityKey] === "")) return null;
  return value;
}

async function roomListed(deps: CallDeps, room: string): Promise<boolean | null> {
  const listed = await deps.rooms.listRooms([room]);
  if (listed.kind !== "ok") return null;
  const rooms = providerList(listed.body, "rooms", "name");
  return rooms === null ? null : rooms.some((r) => r.name === room);
}

/** Ensures the provider room exists. Records and returns the result. */
export async function provisionCall(deps: CallDeps, call: CallRef): Promise<"ready" | "rejected" | "unknown"> {
  const created = await deps.rooms.createRoom(call.room_name);
  let result: "ready" | "rejected" | "unknown";
  if (created.kind === "ok") {
    result = "ready";
  } else {
    // Ambiguous or refused create: the room may still exist (lost response,
    // already-exists). Only a provable absence after a definitive refusal is
    // a rejection.
    const listed = await roomListed(deps, call.room_name);
    result = listed === true ? "ready"
      : listed === false && created.kind === "rejected" ? "rejected"
      : "unknown";
  }
  await rpcData(deps, "rf02_call_record_provisioning", { p_call_id: call.call_id, p_result: result });
  return result;
}

/** Revokes both identities' tokens (cutoff), deletes the room, confirms
 * absence, and records the outcome. Returns true only when confirmed. */
export async function cleanupCall(deps: CallDeps, call: CallRef): Promise<boolean> {
  const cutoff = revokeCutoff(deps.nowSeconds());
  let revoked = true;
  for (const identity of [call.caller_id, call.callee_id]) {
    if (!identity) {
      revoked = false;
      continue;
    }
    const r = await deps.rooms.removeParticipant(call.room_name, identity, cutoff);
    if (r.kind !== "ok" && r.kind !== "absent") revoked = false;
  }
  const deleted = await deps.rooms.deleteRoom(call.room_name);
  const deleteOk = deleted.kind === "ok" || deleted.kind === "absent";
  const listed = await roomListed(deps, call.room_name);
  const confirmed = revoked && deleteOk && listed === false;
  const recorded = await rpcData<string>(deps, "rf02_call_mark_cleanup", {
    p_call_id: call.call_id, p_ok: confirmed, p_provision_attempts: call.provision_attempts ?? null,
  });
  return confirmed && recorded === "confirmed";
}

type Batch = { presence?: CallRef[]; provisioning?: CallRef[]; cleanup?: CallRef[] };

/** One reconciliation pass. Each item is independent; one failure does not
 * stop the others. */
export async function reconcileTick(deps: CallDeps): Promise<{ presence: number; provisioned: number; cleaned: number; errors: number }> {
  const batch = (await rpcData<Batch>(deps, "rf02_call_reconcile_batch", { p_limit: 50 })) ?? {};
  const summary = { presence: 0, provisioned: 0, cleaned: 0, errors: 0 };

  for (const call of batch.presence ?? []) {
    try {
      const listed = await deps.rooms.listParticipants(call.room_name);
      if (listed.kind !== "ok" && listed.kind !== "absent") continue; // unknown: infer nothing
      const participants = listed.kind === "absent" ? [] : providerList(listed.body, "participants", "identity");
      if (participants === null) continue;
      const present = participants.map((p) => p.identity).filter((i): i is string => typeof i === "string" && UUID_RE.test(i));
      await rpcData(deps, "rf02_call_record_presence", { p_call_id: call.call_id, p_present: present });
      summary.presence++;
    } catch {
      summary.errors++;
    }
  }
  for (const call of batch.provisioning ?? []) {
    try {
      if (await provisionCall(deps, call) === "ready") summary.provisioned++;
    } catch {
      summary.errors++;
    }
  }
  for (const call of batch.cleanup ?? []) {
    try {
      if (await cleanupCall(deps, call)) summary.cleaned++;
    } catch {
      summary.errors++;
    }
  }
  return summary;
}
