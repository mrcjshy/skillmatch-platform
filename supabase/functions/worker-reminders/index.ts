// ============================================================
// Lane C: worker-reminders Edge Function entry (Deno wiring only)
// ============================================================
//
// Proposed config.toml: [functions.worker-reminders] verify_jwt = false.
// Boundary: x-skillmatch-dispatch-secret == SKILLMATCH_DISPATCH_WEBHOOK_SECRET.
// Requires the service_role-only RPCs proposed in the Lane C approvals file:
//   get_worker_reminder_candidates, get_worker_reminder_push_targets,
//   claim_outbound_dispatch, finish_outbound_dispatch.
// Sends only when WORKER_REMINDERS_ENABLED is exactly "true"; otherwise
// every tick is a dry run that reports how many reminders are due.

import { createClient } from "npm:@supabase/supabase-js@2";
import { handleReminderTick } from "./handler.ts";

function env(name: string): string | undefined {
  const value = Deno.env.get(name)?.trim();
  return value ? value : undefined;
}

export function serve(req: Request): Promise<Response> {
  const url = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    return Promise.resolve(
      new Response(JSON.stringify({ error: "server configuration incomplete" }), {
        status: 500,
        headers: { "content-type": "application/json" },
      }),
    );
  }
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  return handleReminderTick(req, {
    env: {
      webhookSecret: env("SKILLMATCH_DISPATCH_WEBHOOK_SECRET"),
      expoAccessToken: env("EXPO_ACCESS_TOKEN"),
      enabled: env("WORKER_REMINDERS_ENABLED"),
    },
    now: () => Date.now(),
    listCandidates: async (fromIso, toIso, limit) => {
      const { data, error } = await admin.rpc("get_worker_reminder_candidates", {
        p_from: fromIso,
        p_to: toIso,
        p_limit: limit,
      });
      if (error) throw new Error("candidates unavailable");
      return Array.isArray(data) ? data : [];
    },
    getPushTokens: async (bookingId, workerId, scheduledAtIso) => {
      const { data, error } = await admin.rpc("get_worker_reminder_push_targets", {
        p_booking_id: bookingId,
        p_worker_id: workerId,
        p_scheduled_at: scheduledAtIso,
      });
      if (error) throw new Error("targets unavailable");
      return (Array.isArray(data) ? data : [])
        .map((row: { expo_push_token?: unknown }) => row.expo_push_token)
        .filter((t: unknown): t is string => typeof t === "string" && t.length > 0);
    },
    claim: async (dedupKey, bookingId, maxAttempts) => {
      const { data, error } = await admin.rpc("claim_outbound_dispatch", {
        p_dedup_key: dedupKey,
        p_kind: "worker_reminder",
        p_booking_id: bookingId,
        p_max_attempts: maxAttempts,
      });
      if (error) throw new Error("ledger unavailable");
      return data === true;
    },
    finish: async (dedupKey, sent, error) => {
      await admin.rpc("finish_outbound_dispatch", {
        p_dedup_key: dedupKey,
        p_sent: sent,
        p_provider_ref: null,
        p_error: error,
      });
    },
  });
}

if (import.meta.main) Deno.serve(serve);
