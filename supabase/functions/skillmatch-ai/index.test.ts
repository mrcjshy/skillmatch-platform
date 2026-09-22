import {
  classifyProviderException,
  classifyProviderResponse,
} from "./index.ts";

const completed = {
  status: "completed",
  steps: [{ type: "model_output", content: [{ type: "text", text: "Practice safely." }] }],
};

Deno.test("classifies non-2xx HTTP without body details", () => {
  const result = classifyProviderResponse(429, { error: "private" });
  if (result.kind !== "failure" || result.stage !== "provider_http" || result.http_status !== 429) {
    throw new Error(`unexpected classification: ${JSON.stringify(result)}`);
  }
});

Deno.test("accepts a completed response with model output", () => {
  const result = classifyProviderResponse(200, completed);
  if (result.kind !== "success" || result.interaction_status !== "completed") {
    throw new Error(`unexpected classification: ${JSON.stringify(result)}`);
  }
});

Deno.test("classifies incomplete, failed, cancelled, and unexpected statuses", () => {
  for (const status of ["incomplete", "failed", "cancelled", "in_progress", "unexpected"]) {
    const result = classifyProviderResponse(200, { status });
    if (result.kind !== "failure" || result.stage !== "provider_interaction_not_completed" || result.interaction_status !== status) {
      throw new Error(`unexpected ${status} classification: ${JSON.stringify(result)}`);
    }
  }
});

Deno.test("classifies invalid JSON and oversized responses", () => {
  const invalid = classifyProviderResponse(200, null, { invalidJson: true });
  const oversized = classifyProviderResponse(200, null, { responseTooLarge: true });
  if (invalid.kind !== "failure" || invalid.stage !== "provider_invalid_json") {
    throw new Error(`unexpected invalid JSON classification: ${JSON.stringify(invalid)}`);
  }
  if (oversized.kind !== "failure" || oversized.stage !== "provider_response_too_large") {
    throw new Error(`unexpected oversized classification: ${JSON.stringify(oversized)}`);
  }
});

Deno.test("classifies missing or invalid model output", () => {
  for (const body of [
    { status: "completed", steps: [] },
    { status: "completed", steps: [{ type: "model_output", content: [] }] },
    { status: "completed", steps: [{ type: "other", content: [{ type: "text", text: "hidden" }] }] },
  ]) {
    const result = classifyProviderResponse(200, body);
    if (result.kind !== "failure" || result.stage !== "provider_missing_output") {
      throw new Error(`unexpected output classification: ${JSON.stringify(result)}`);
    }
  }
});

Deno.test("classifies AbortError as timeout and other errors as network", () => {
  const timeout = classifyProviderException(new DOMException("aborted", "AbortError"));
  const network = classifyProviderException(new Error("network"));
  if (timeout.stage !== "provider_timeout" || network.stage !== "provider_network") {
    throw new Error(`unexpected exception classification: ${JSON.stringify({ timeout, network })}`);
  }
});
