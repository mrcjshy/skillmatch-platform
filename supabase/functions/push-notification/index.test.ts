import {
  buildChatExpoMessages,
  buildExpoMessages,
  handleRequest,
  type MessagePushTarget,
  notificationTitle,
  parseNotificationId,
  parsePushRequest,
  timingSafeEqual,
  type PushTarget,
} from "./index.ts";

const SECRET = "r5b-local-webhook-secret";
const EXPO = "expo-local-access-token";
const NID = "11111111-1111-4111-8111-111111111111";

function env(extra: Record<string, string | undefined> = {}) {
  return {
    R5B_PUSH_WEBHOOK_SECRET: SECRET,
    EXPO_ACCESS_TOKEN: EXPO,
    SUPABASE_URL: "http://127.0.0.1:54321",
    SUPABASE_SERVICE_ROLE_KEY: "service-role-test",
    ...extra,
  };
}

function post(
  body: unknown,
  headers: Record<string, string> = {},
): Request {
  return new Request("http://localhost/push-notification", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-skillmatch-push-secret": SECRET,
      ...headers,
    },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function read(res: Response): Promise<{ status: number; body: Record<string, unknown> }> {
  return { status: res.status, body: await res.json() };
}

Deno.test("non-POST is 405", async () => {
  const res = await handleRequest(
    new Request("http://localhost/push-notification", { method: "GET" }),
    { env: env() },
  );
  const got = await read(res);
  if (got.status !== 405) throw new Error(`expected 405, got ${got.status}`);
});

Deno.test("malformed JSON is 400", async () => {
  const res = await handleRequest(post("{"), { env: env(), adminRpc: async () => ({ data: [], error: null }) });
  const got = await read(res);
  if (got.status !== 400) throw new Error(`expected 400, got ${got.status}`);
});

Deno.test("missing notification_id is 400", async () => {
  const res = await handleRequest(post({}), { env: env(), adminRpc: async () => ({ data: [], error: null }) });
  const got = await read(res);
  if (got.status !== 400) throw new Error(`expected 400, got ${got.status}`);
});

Deno.test("invalid UUID is 400", async () => {
  const res = await handleRequest(post({ notification_id: "not-a-uuid" }), {
    env: env(),
    adminRpc: async () => ({ data: [], error: null }),
  });
  const got = await read(res);
  if (got.status !== 400) throw new Error(`expected 400, got ${got.status}`);
});

Deno.test("extra caller authority fields are 400", async () => {
  const res = await handleRequest(
    post({ notification_id: NID, user_id: "x", title: "nope" }),
    { env: env(), adminRpc: async () => ({ data: [], error: null }) },
  );
  const got = await read(res);
  if (got.status !== 400) throw new Error(`expected 400, got ${got.status}`);
});

Deno.test("missing webhook secret is denied", async () => {
  const req = new Request("http://localhost/push-notification", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ notification_id: NID }),
  });
  const res = await handleRequest(req, { env: env(), adminRpc: async () => ({ data: [], error: null }) });
  const got = await read(res);
  if (got.status !== 401) throw new Error(`expected 401, got ${got.status}`);
});

Deno.test("wrong webhook secret is denied", async () => {
  const res = await handleRequest(
    post({ notification_id: NID }, { "x-skillmatch-push-secret": "wrong" }),
    { env: env(), adminRpc: async () => ({ data: [], error: null }) },
  );
  const got = await read(res);
  if (got.status !== 401) throw new Error(`expected 401, got ${got.status}`);
});

Deno.test("no targets is a safe no-op", async () => {
  const res = await handleRequest(post({ notification_id: NID }), {
    env: env(),
    adminRpc: async () => ({ data: [], error: null }),
  });
  const got = await read(res);
  if (got.status !== 200 || got.body.delivered !== 0) {
    throw new Error(`expected 200 delivered 0, got ${JSON.stringify(got)}`);
  }
});

const oneTarget: PushTarget = {
  notification_id: NID,
  notification_type: "worker_verified",
  notification_message: "Your worker profile has been verified.",
  expo_push_token: "ExponentPushToken[one]",
};

const twoTargets: PushTarget[] = [
  oneTarget,
  {
    notification_id: NID,
    notification_type: "worker_verified",
    notification_message: "Your worker profile has been verified.",
    expo_push_token: "ExponentPushToken[two]",
  },
];

Deno.test("one target sends one Expo message from DB values", async () => {
  let sentUrl = "";
  let sentInit: RequestInit = {};
  const res = await handleRequest(post({ notification_id: NID }), {
    env: env(),
    adminRpc: async () => ({ data: [oneTarget], error: null }),
    fetchImpl: (async (url, init) => {
      sentUrl = String(url);
      sentInit = init ?? {};
      return new Response("{}", { status: 200 });
    }) as typeof fetch,
  });
  const got = await read(res);
  if (got.status !== 200 || got.body.delivered !== 1) {
    throw new Error(`expected delivered 1, got ${JSON.stringify(got)}`);
  }
  if (sentUrl === "") throw new Error("Expo was not called");
  if (sentUrl !== "https://exp.host/--/api/v2/push/send") {
    throw new Error(`wrong Expo URL ${sentUrl}`);
  }
  const headers = sentInit.headers as Record<string, string>;
  if (headers.Authorization !== `Bearer ${EXPO}`) {
    throw new Error("EXPO_ACCESS_TOKEN was not used");
  }
  const messages = JSON.parse(String(sentInit.body));
  if (messages.length !== 1) throw new Error("expected one message");
  if (messages[0].to !== "ExponentPushToken[one]") throw new Error("token not from DB");
  if (messages[0].body !== "Your worker profile has been verified.") {
    throw new Error("body not from DB");
  }
  if (messages[0].title !== "Verification update") throw new Error("title not type label");
  if (JSON.stringify(messages[0].data) !== JSON.stringify({ notification_id: NID })) {
    throw new Error("data must be notification_id only");
  }
});

Deno.test("multiple targets send every active token", async () => {
  let messages: unknown[] = [];
  const res = await handleRequest(post({ notification_id: NID }), {
    env: env(),
    adminRpc: async () => ({ data: twoTargets, error: null }),
    fetchImpl: (async (_url, init) => {
      messages = JSON.parse(String(init?.body));
      return new Response("{}", { status: 200 });
    }) as typeof fetch,
  });
  const got = await read(res);
  if (got.status !== 200 || got.body.delivered !== 2) {
    throw new Error(`expected delivered 2, got ${JSON.stringify(got)}`);
  }
  if (messages.length !== 2) throw new Error("expected two Expo messages");
});

Deno.test("payload ignores caller body text", async () => {
  let messages: Array<{ body: string }> = [];
  const req = post({ notification_id: NID });
  const res = await handleRequest(req, {
    env: env(),
    adminRpc: async () => ({ data: [oneTarget], error: null }),
    fetchImpl: (async (_url, init) => {
      messages = JSON.parse(String(init?.body));
      return new Response("{}", { status: 200 });
    }) as typeof fetch,
  });
  await read(res);
  if (messages[0]?.body !== oneTarget.notification_message) {
    throw new Error("caller must not supply OS body");
  }
});

Deno.test("provider failure is sanitized and does not throw secrets", async () => {
  const res = await handleRequest(post({ notification_id: NID }), {
    env: env(),
    adminRpc: async () => ({ data: [oneTarget], error: null }),
    fetchImpl: (async () => new Response("nope", { status: 500 })) as typeof fetch,
  });
  const got = await read(res);
  if (got.status !== 200 || got.body.delivered !== false) {
    throw new Error(`expected fail-open 200, got ${JSON.stringify(got)}`);
  }
  const text = JSON.stringify(got.body);
  if (text.includes(SECRET) || text.includes(EXPO) || text.includes("ExponentPushToken")) {
    throw new Error("response leaked a secret or token");
  }
});

// ---------- W7 booking chat push ----------

const MID = "22222222-2222-4222-8222-222222222222";
const BID = "33333333-3333-4333-8333-333333333333";

const chatTarget: MessagePushTarget = {
  message_id: MID,
  booking_id: BID,
  expo_push_token: "ExponentPushToken[recipient]",
};

Deno.test("notification pushes use the versioned SkillMatch channel", () => {
  const built = buildExpoMessages([oneTarget]);
  if (built[0].channelId !== "skillmatch_alerts_v1") {
    throw new Error(`expected skillmatch_alerts_v1, got ${built[0].channelId}`);
  }
});

Deno.test("every notification type pushes at high priority with a titled alert", () => {
  // Normal priority lets Android hold the alert while the phone idles.
  for (const type of ["booking_request", "booking_confirmed", "booking_cancelled", "booking_completed",
    "no_show_strike", "account_suspended", "payment_received", "worker_verified", "report_submitted"]) {
    const built = buildExpoMessages([{ ...oneTarget, notification_type: type }]);
    if (built[0].priority !== "high") throw new Error(`${type} priority ${built[0].priority}`);
    if (built[0].title === "SkillMatch") throw new Error(`${type} has no title`);
  }
});

Deno.test("message_id body resolves chat targets through the message RPC", async () => {
  let rpcName = "";
  let rpcArgs: Record<string, unknown> = {};
  let messages: Array<Record<string, unknown>> = [];
  const res = await handleRequest(post({ message_id: MID }), {
    env: env(),
    adminRpc: async (fn, args) => {
      rpcName = fn;
      rpcArgs = args;
      return { data: [chatTarget], error: null };
    },
    fetchImpl: (async (_url, init) => {
      messages = JSON.parse(String(init?.body));
      return new Response("{}", { status: 200 });
    }) as typeof fetch,
  });
  const got = await read(res);
  if (got.status !== 200 || got.body.delivered !== 1) {
    throw new Error(`expected delivered 1, got ${JSON.stringify(got)}`);
  }
  if (rpcName !== "get_message_push_targets") throw new Error(`wrong RPC ${rpcName}`);
  if (JSON.stringify(rpcArgs) !== JSON.stringify({ p_message_id: MID })) {
    throw new Error(`wrong RPC args ${JSON.stringify(rpcArgs)}`);
  }
  const m = messages[0];
  if (m.to !== "ExponentPushToken[recipient]") throw new Error("token not from DB");
  if (m.title !== "New SkillMatch message") throw new Error(`title ${m.title}`);
  if (m.body !== "Open SkillMatch to view the message.") throw new Error(`body ${m.body}`);
  if (m.channelId !== "skillmatch_alerts_v1") throw new Error(`channel ${m.channelId}`);
  if (m.priority !== "high") throw new Error(`priority ${m.priority}`);
  if (JSON.stringify(m.data) !== JSON.stringify({ kind: "message", booking_id: BID })) {
    throw new Error(`data must be kind + booking_id only, got ${JSON.stringify(m.data)}`);
  }
});

Deno.test("chat push copy is fixed and never carries message content", () => {
  const built = buildChatExpoMessages([chatTarget]);
  const text = JSON.stringify(built);
  if (text.includes(MID)) throw new Error("message id must not be sent to the device");
  if (Object.keys(built[0]).sort().join(",") !== "body,channelId,data,priority,sound,title,to") {
    throw new Error(`unexpected keys ${Object.keys(built[0]).join(",")}`);
  }
});

Deno.test("message_id with no targets is a safe no-op", async () => {
  let called = false;
  const res = await handleRequest(post({ message_id: MID }), {
    env: env(),
    adminRpc: async () => ({ data: [], error: null }),
    fetchImpl: (async () => {
      called = true;
      return new Response("{}", { status: 200 });
    }) as typeof fetch,
  });
  const got = await read(res);
  if (got.status !== 200 || got.body.delivered !== 0 || called) {
    throw new Error(`expected no-op, got ${JSON.stringify(got)} called=${called}`);
  }
});

Deno.test("both ids together are 400", async () => {
  const res = await handleRequest(post({ message_id: MID, notification_id: NID }), {
    env: env(),
    adminRpc: async () => ({ data: [], error: null }),
  });
  const got = await read(res);
  if (got.status !== 400) throw new Error(`expected 400, got ${got.status}`);
});

Deno.test("message_id with caller copy or recipient fields is 400", async () => {
  for (const body of [
    { message_id: MID, body: "leak" },
    { message_id: MID, user_id: "x" },
    { message_id: "not-a-uuid" },
  ]) {
    const res = await handleRequest(post(body), {
      env: env(),
      adminRpc: async () => ({ data: [], error: null }),
    });
    const got = await read(res);
    if (got.status !== 400) throw new Error(`expected 400 for ${JSON.stringify(body)}, got ${got.status}`);
  }
});

Deno.test("message_id still requires the webhook secret", async () => {
  const res = await handleRequest(
    post({ message_id: MID }, { "x-skillmatch-push-secret": "wrong" }),
    { env: env(), adminRpc: async () => ({ data: [chatTarget], error: null }) },
  );
  const got = await read(res);
  if (got.status !== 401) throw new Error(`expected 401, got ${got.status}`);
});

Deno.test("parsePushRequest distinguishes the two id kinds", () => {
  const n = parsePushRequest({ notification_id: NID });
  const m = parsePushRequest({ message_id: MID });
  if (!n.ok || n.kind !== "notification" || n.id !== NID) throw new Error("notification parse");
  if (!m.ok || m.kind !== "message" || m.id !== MID) throw new Error("message parse");
  if (parsePushRequest({}).ok) throw new Error("empty must fail");
});

Deno.test("parseNotificationId helpers", () => {
  if (parseNotificationId({ notification_id: NID }).ok !== true) {
    throw new Error("valid id should parse");
  }
  if (parseNotificationId({ notification_id: NID, extra: 1 }).ok !== false) {
    throw new Error("extra fields must fail");
  }
  if (notificationTitle("booking_confirmed") !== "Booking confirmed") {
    throw new Error("type label mismatch");
  }
  if (!timingSafeEqual("abc", "abc") || timingSafeEqual("abc", "abd")) {
    throw new Error("timingSafeEqual mismatch");
  }
  const built = buildExpoMessages([oneTarget]);
  if (Object.keys(built[0].data).join(",") !== "notification_id") {
    throw new Error("data keys must be notification_id only");
  }
});
