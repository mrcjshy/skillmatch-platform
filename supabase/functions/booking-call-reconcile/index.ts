import { createClient } from "npm:@supabase/supabase-js@2";
import { roomService } from "../_shared/livekit.ts";
import { handleReconcile } from "./handler.ts";

Deno.serve((req) => {
  const env = Deno.env.toObject();
  const admin = createClient(env.SUPABASE_URL ?? "", env.SUPABASE_SERVICE_ROLE_KEY ?? "", {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handleReconcile(req, {
    env,
    rpc: async (fn, args) => {
      const { data, error } = await admin.rpc(fn, args);
      return { data, error: error ? { code: error.code, message: error.message } : null };
    },
    rooms: roomService({ url: env.LIVEKIT_URL ?? "", apiKey: env.LIVEKIT_API_KEY ?? "", apiSecret: env.LIVEKIT_API_SECRET ?? "" }),
    nowSeconds: () => Math.floor(Date.now() / 1000),
  });
});
