import { createClient } from "npm:@supabase/supabase-js@2";
import { reconcileTick } from "../_shared/call-ops.ts";
import { roomService } from "../_shared/livekit.ts";
import { handleWebhook } from "./handler.ts";

Deno.serve((req) => {
  const env = Deno.env.toObject();
  const admin = createClient(env.SUPABASE_URL ?? "", env.SUPABASE_SERVICE_ROLE_KEY ?? "", {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await admin.rpc(fn, args);
    return { data, error: error ? { code: error.code, message: error.message } : null };
  };
  const nowSeconds = () => Math.floor(Date.now() / 1000);
  return handleWebhook(req, {
    env,
    lookupCall: async (room) => {
      const { data } = await rpc("rf02_call_by_room", { p_room_name: room });
      return typeof data === "string" ? data : null;
    },
    reconcile: async () => {
      await reconcileTick({
        rpc,
        rooms: roomService({ url: env.LIVEKIT_URL ?? "", apiKey: env.LIVEKIT_API_KEY ?? "", apiSecret: env.LIVEKIT_API_SECRET ?? "" }),
        nowSeconds,
      });
    },
    nowSeconds,
  });
});
