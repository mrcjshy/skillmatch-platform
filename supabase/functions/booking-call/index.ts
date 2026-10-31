import { createClient } from "npm:@supabase/supabase-js@2";
import { roomService } from "../_shared/livekit.ts";
import { handleBookingCall, type PushMessage } from "./handler.ts";

const EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send";

Deno.serve((req) => {
  const env = Deno.env.toObject();
  const admin = createClient(env.SUPABASE_URL ?? "", env.SUPABASE_SERVICE_ROLE_KEY ?? "", {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handleBookingCall(req, {
    env,
    resolveUser: async (jwt) => (await admin.auth.getUser(jwt)).data.user?.id ?? null,
    rpc: async (fn, args) => {
      const { data, error } = await admin.rpc(fn, args);
      return { data, error: error ? { code: error.code, message: error.message } : null };
    },
    rooms: roomService({ url: env.LIVEKIT_URL ?? "", apiKey: env.LIVEKIT_API_KEY ?? "", apiSecret: env.LIVEKIT_API_SECRET ?? "" }),
    sendPush: async (messages: PushMessage[]) => {
      if (!env.EXPO_ACCESS_TOKEN) return false;
      const res = await fetch(EXPO_PUSH_URL, {
        method: "POST",
        headers: { authorization: `Bearer ${env.EXPO_ACCESS_TOKEN}`, "content-type": "application/json" },
        body: JSON.stringify(messages),
        signal: AbortSignal.timeout(10_000),
      });
      await res.body?.cancel();
      return res.ok;
    },
    nowSeconds: () => Math.floor(Date.now() / 1000),
  });
});
