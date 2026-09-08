// ============================================================
// AI-SVC-01: OPTIONAL SKILL-GAP GUIDANCE (Edge Function)
// ============================================================
//
// SkillMatch computes the gap before any external request:
//
//   required skill ids - authenticated Worker's skill ids = missing ids
//
// The model receives only the resolved master-table names of those missing
// skills. It cannot decide or change the gap, matching, eligibility, ranking,
// acceptance, or profile state. This function performs authenticated reads
// through the caller's JWT and has no database or Storage write path.

import { createClient } from "npm:@supabase/supabase-js@2";

const GEMINI_API = "https://generativelanguage.googleapis.com/v1/interactions";
const GEMINI_MODEL = "gemini-3.5-flash-lite";
const PROVIDER_TIMEOUT_MS = 12_000;
const MAX_REQUEST_CHARS = 512;
const MAX_GUIDANCE_CHARS = 1_200;
const MAX_PROVIDER_RESPONSE_CHARS = 64_000;

export const ZERO_GAP_GUIDANCE =
  "Wala kang missing skills para sa job na ito.";

export const SYSTEM_INSTRUCTION = `You are SkillMatch's optional skill-gap guidance helper.

The missing skills listed by SkillMatch are authoritative and were already calculated deterministically.

Do not add, remove, rename, merge, or reinterpret missing skills.

Give short, practical Taglish guidance for improving or practicing only those skills.

Do not claim the Worker is eligible, qualified, guaranteed to get a job, or that guidance changes matching.

Do not claim a specific TESDA course, school, provider, certificate, price, schedule, or availability unless SkillMatch supplied it. SkillMatch supplies none of those here.

Do not invent years of experience, credentials, employment history, or other Worker facts.

Keep the answer concise.`;

type JsonObject = Record<string, unknown>;

export type SkillGapGuidanceRequest = {
  mode: "skill_gap_guidance";
  job_id: string;
};

export type NamedSkill = {
  id: string;
  name: string;
};

export type MissingSkillsResult =
  | { ok: true; missingSkills: NamedSkill[] }
  | { ok: false };

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nonBlankText(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

function compareText(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

/** Accepts exactly { mode, job_id }; every additional key is rejected. */
export function parseExactRequest(value: unknown): SkillGapGuidanceRequest | null {
  if (!isObject(value)) return null;
  const keys = Object.keys(value).sort(compareText);
  if (keys.length !== 2 || keys[0] !== "job_id" || keys[1] !== "mode") {
    return null;
  }
  if (value.mode !== "skill_gap_guidance" || !isUuid(value.job_id)) {
    return null;
  }
  return { mode: "skill_gap_guidance", job_id: value.job_id.toLowerCase() };
}

function normalizeUuidList(
  values: readonly unknown[],
  failOnMalformed: boolean,
): string[] | null {
  const ids = new Set<string>();
  for (const value of values) {
    if (!isUuid(value)) {
      if (failOnMalformed) return null;
      continue;
    }
    ids.add(value.toLowerCase());
  }
  return [...ids].sort(compareText);
}

/**
 * Pure, deterministic skill-id set difference. Required ids fail closed when
 * malformed or when their authoritative name is absent/blank. Worker ids are
 * identity only; names and proficiency never participate in the comparison.
 */
export function deterministicMissingSkills(
  requiredValues: readonly unknown[],
  workerValues: readonly unknown[],
  masterRows: readonly unknown[],
): MissingSkillsResult {
  const requiredIds = normalizeUuidList(requiredValues, true);
  if (requiredIds === null) return { ok: false };

  const workerIds = new Set(normalizeUuidList(workerValues, false) ?? []);
  const names = new Map<string, string>();
  for (const value of masterRows) {
    if (!isObject(value) || !isUuid(value.id)) continue;
    const name = nonBlankText(value.skill_name);
    if (name === null) continue;
    const id = value.id.toLowerCase();
    if (!names.has(id)) names.set(id, name);
  }

  const required: NamedSkill[] = [];
  for (const id of requiredIds) {
    const name = names.get(id);
    if (name === undefined) return { ok: false };
    required.push({ id, name });
  }

  const missingSkills = required
    .filter((skill) => !workerIds.has(skill.id))
    .sort((a, b) => compareText(a.name, b.name) || compareText(a.id, b.id));
  return { ok: true, missingSkills };
}

export function normalizeGuidance(value: unknown): string | null {
  const text = nonBlankText(value);
  if (text === null || text.length > MAX_GUIDANCE_CHARS) return null;
  return text;
}

/** Extracts text blocks from the last valid model_output step only. */
export function extractInteractionText(value: unknown): string | null {
  if (
    !isObject(value) ||
    value.status !== "completed" ||
    !Array.isArray(value.steps)
  ) {
    return null;
  }
  for (let index = value.steps.length - 1; index >= 0; index -= 1) {
    const step = value.steps[index];
    if (!isObject(step) || step.type !== "model_output" || !Array.isArray(step.content)) {
      continue;
    }
    const blocks: string[] = [];
    for (const content of step.content) {
      if (!isObject(content) || content.type !== "text" || typeof content.text !== "string") {
        continue;
      }
      blocks.push(content.text);
    }
    const text = normalizeGuidance(blocks.join("\n"));
    if (text !== null) return text;
  }
  return null;
}

function firstEnv(...names: string[]): string | undefined {
  for (const name of names) {
    const raw = Deno.env.get(name);
    if (!raw) continue;
    const value = raw.trim();
    if (value === "") continue;
    if (value.startsWith("[")) {
      try {
        const parsed = JSON.parse(value);
        if (Array.isArray(parsed) && typeof parsed[0] === "string") {
          return parsed[0].trim();
        }
      } catch {
        // Fall through to the raw value.
      }
    }
    if (name.endsWith("_KEYS") && value.includes(",")) {
      return value.split(",")[0].trim();
    }
    return value;
  }
  return undefined;
}

function json(status: number, body: JsonObject): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json",
    },
  });
}

function fail(status: number, code: string): Response {
  return json(status, { error: code });
}

function rowValue(row: unknown, key: string): unknown {
  return isObject(row) ? row[key] : undefined;
}

function skillIdsFromRows(rows: unknown): unknown[] | null {
  if (!Array.isArray(rows)) return null;
  return rows.map((row) => rowValue(row, "skill_id"));
}

export async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") return fail(405, "method_not_allowed");

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return fail(401, "unauthenticated");

  const supabaseUrl = firstEnv("SUPABASE_URL");
  const callerKey = firstEnv(
    "SUPABASE_ANON_KEY",
    "SUPABASE_PUBLISHABLE_KEY",
    "SUPABASE_PUBLISHABLE_KEYS",
  );
  if (!supabaseUrl || !callerKey) return fail(500, "server_misconfigured");

  const callerClient = createClient(supabaseUrl, callerKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: authData, error: authError } = await callerClient.auth.getUser();
  const caller = authData?.user;
  if (authError || !caller?.id) return fail(401, "unauthenticated");

  let rawBody: string;
  try {
    rawBody = await req.text();
  } catch {
    return fail(400, "invalid_request");
  }
  if (rawBody.length > MAX_REQUEST_CHARS) return fail(400, "invalid_request");

  let parsedBody: unknown;
  try {
    parsedBody = JSON.parse(rawBody);
  } catch {
    return fail(400, "invalid_request");
  }
  const request = parseExactRequest(parsedBody);
  if (request === null) return fail(400, "invalid_request");

  const { data: account, error: accountError } = await callerClient
    .from("users")
    .select("role, is_active")
    .eq("id", caller.id)
    .maybeSingle();
  if (
    accountError ||
    !account ||
    account.role !== "worker" ||
    account.is_active !== true
  ) {
    return fail(403, "not_authorized");
  }

  const { data: opportunityRows, error: opportunityError } = await callerClient
    .rpc("list_my_job_opportunities");
  if (opportunityError || !Array.isArray(opportunityRows)) {
    return fail(403, "guidance_unavailable");
  }
  const jobAllowed = opportunityRows.some((row) => {
    const id = rowValue(row, "job_id");
    return isUuid(id) && id.toLowerCase() === request.job_id;
  });
  if (!jobAllowed) return fail(403, "guidance_unavailable");

  const { data: profile, error: profileError } = await callerClient
    .from("worker_profiles")
    .select("id")
    .eq("user_id", caller.id)
    .maybeSingle();
  const workerProfileId = rowValue(profile, "id");
  if (profileError || !isUuid(workerProfileId)) {
    return fail(403, "guidance_unavailable");
  }

  const [workerSkillsResult, jobSkillsResult] = await Promise.all([
    callerClient
      .from("worker_skills")
      .select("skill_id")
      .eq("worker_id", workerProfileId),
    callerClient
      .from("job_skills")
      .select("skill_id")
      .eq("job_id", request.job_id),
  ]);
  if (workerSkillsResult.error || jobSkillsResult.error) {
    return fail(403, "guidance_unavailable");
  }

  const workerSkillIds = skillIdsFromRows(workerSkillsResult.data);
  const requiredSkillValues = skillIdsFromRows(jobSkillsResult.data);
  if (workerSkillIds === null || requiredSkillValues === null) {
    return fail(403, "guidance_unavailable");
  }
  const requiredSkillIds = normalizeUuidList(requiredSkillValues, true);
  if (requiredSkillIds === null) return fail(403, "guidance_unavailable");

  let masterRows: unknown[] = [];
  if (requiredSkillIds.length > 0) {
    const { data, error } = await callerClient
      .from("skills")
      .select("id, skill_name")
      .in("id", requiredSkillIds);
    if (error || !Array.isArray(data)) return fail(403, "guidance_unavailable");
    masterRows = data;
  }

  const gap = deterministicMissingSkills(
    requiredSkillIds,
    workerSkillIds,
    masterRows,
  );
  if (!gap.ok) return fail(403, "guidance_unavailable");

  const missingSkillNames = gap.missingSkills.map((skill) => skill.name);
  if (missingSkillNames.length === 0) {
    return json(200, {
      mode: "skill_gap_guidance",
      missing_skills: [],
      guidance: ZERO_GAP_GUIDANCE,
      source: "deterministic",
    });
  }

  // Read only after every local/auth/data gate and after the non-zero gap is
  // established. Earlier callers cannot probe provider configuration.
  const geminiApiKey = firstEnv("GEMINI_API_KEY");
  if (!geminiApiKey) return fail(500, "server_misconfigured");

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), PROVIDER_TIMEOUT_MS);
  try {
    const providerResponse = await fetch(GEMINI_API, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "content-type": "application/json",
        "x-goog-api-key": geminiApiKey,
      },
      body: JSON.stringify({
        model: GEMINI_MODEL,
        input: `Authoritative missing skill names: ${JSON.stringify(missingSkillNames)}`,
        system_instruction: SYSTEM_INSTRUCTION,
        store: false,
        generation_config: {
          max_output_tokens: 192,
          thinking_level: "minimal",
        },
      }),
    });
    if (!providerResponse.ok) return fail(502, "provider_unavailable");

    const providerText = await providerResponse.text();
    if (providerText.length > MAX_PROVIDER_RESPONSE_CHARS) {
      return fail(502, "provider_unavailable");
    }
    let providerBody: unknown;
    try {
      providerBody = JSON.parse(providerText);
    } catch {
      return fail(502, "provider_unavailable");
    }
    const guidance = extractInteractionText(providerBody);
    if (guidance === null) return fail(502, "provider_unavailable");

    return json(200, {
      mode: "skill_gap_guidance",
      missing_skills: missingSkillNames,
      guidance,
      source: "gemini",
    });
  } catch {
    return fail(502, "provider_unavailable");
  } finally {
    clearTimeout(timeout);
  }
}

// Guarded so pure helpers can be imported by local verification without
// binding a port.
if (import.meta.main) {
  Deno.serve(handleRequest);
}
