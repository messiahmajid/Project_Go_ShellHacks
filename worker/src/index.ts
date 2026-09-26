/**
 * Go worker
 *
 * Holds Go's API keys as Cloudflare secrets so the app never ships with them,
 * and serves the few routes the app calls.
 *
 * Every route requires the header `X-Go-Client-Key` to equal the secret
 * `GO_CLIENT_KEY`; without it this worker would be an open proxy for every
 * key it holds. If the secret is unset, every request is refused.
 *
 * Routes (all POST):
 *   /go-plan            → Gemini planner for Go's guided steps (src/go-plan.ts)
 *   /gemini-live-token  → Gemini Live API ephemeral token, one use, model locked
 *   /tts                → ElevenLabs text to speech (Go's spoken voice)
 *
 * Secrets:
 *   GO_CLIENT_KEY, GEMINI_API_KEY, ELEVENLABS_API_KEY
 * Vars (wrangler.toml):
 *   ELEVENLABS_VOICE_ID
 */

import { handleGoPlan } from "./go-plan";

interface Env {
  GO_CLIENT_KEY?: string;
  GEMINI_API_KEY?: string;
  ELEVENLABS_API_KEY?: string;
  ELEVENLABS_VOICE_ID?: string;
}

const GEMINI_LIVE_MODEL = "gemini-3.1-flash-live-preview";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // The guard runs before routing and before the method check, so an
    // unauthenticated caller learns nothing about which routes exist.
    const refusal = await refuseUnlessClientKeyMatches(request, env);
    if (refusal) {
      return refusal;
    }

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      switch (url.pathname) {
        case "/go-plan":
          return await handleGoPlan(request, env.GEMINI_API_KEY);
        case "/gemini-live-token":
          return await handleGeminiLiveToken(env);
        case "/tts":
          return await handleTTS(request, env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return jsonResponse({ error: String(error) }, 500);
    }

    return new Response("Not found", { status: 404 });
  },
};

// MARK: - Client guard

async function refuseUnlessClientKeyMatches(request: Request, env: Env): Promise<Response | null> {
  if (!env.GO_CLIENT_KEY) {
    // Fail closed: a forgotten secret must not quietly turn the guard off.
    return jsonResponse(
      { error: "GO_CLIENT_KEY is unset on this worker, so every request is refused. Set it with `wrangler secret put GO_CLIENT_KEY`." },
      503
    );
  }
  const presentedKey = request.headers.get("X-Go-Client-Key") ?? "";
  if (!(await constantTimeEquals(presentedKey, env.GO_CLIENT_KEY))) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  return null;
}

/**
 * Compares SHA-256 digests byte by byte without an early exit. Hashing first
 * makes both inputs 32 bytes, so neither the position of the first differing
 * byte nor the length of the real key shows up in the response time.
 */
async function constantTimeEquals(presented: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [presentedDigest, expectedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(presented)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const presentedBytes = new Uint8Array(presentedDigest);
  const expectedBytes = new Uint8Array(expectedDigest);
  let difference = 0;
  for (let index = 0; index < expectedBytes.length; index++) {
    difference |= presentedBytes[index] ^ expectedBytes[index];
  }
  return difference === 0;
}

// MARK: - Helpers

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Names the missing secret instead of sending the string "undefined" upstream. */
function missingSecretResponse(secretName: string): Response {
  return jsonResponse({ error: `${secretName} is unset on this worker.` }, 500);
}

async function upstreamErrorResponse(routeName: string, response: Response): Promise<Response> {
  const errorBody = await response.text();
  console.error(`[${routeName}] upstream error ${response.status}: ${errorBody}`);
  return new Response(errorBody, {
    status: response.status,
    headers: { "content-type": response.headers.get("content-type") || "application/json" },
  });
}

// MARK: - Gemini

async function handleGeminiLiveToken(env: Env): Promise<Response> {
  if (!env.GEMINI_API_KEY) return missingSecretResponse("GEMINI_API_KEY");

  const now = Date.now();
  // https://ai.google.dev/gemini-api/docs/ephemeral-tokens and
  // https://ai.google.dev/api/live#ephemeral-auth-tokens
  // `bidiGenerateContentSetup` + `fieldMask` is the wire form the official SDKs
  // send for `liveConnectConstraints`. The field mask matters: with an EMPTY
  // mask the server takes the whole setup from the token and ignores the
  // client's setup (system instruction, activity detection) entirely. A mask of
  // "model" locks only the model and leaves the rest to the connection.
  const tokenRequest = {
    uses: 1,
    expireTime: new Date(now + 10 * 60 * 1000).toISOString(),
    newSessionExpireTime: new Date(now + 60 * 1000).toISOString(),
    bidiGenerateContentSetup: { model: `models/${GEMINI_LIVE_MODEL}` },
    fieldMask: "model",
  };

  const response = await fetch("https://generativelanguage.googleapis.com/v1beta/auth_tokens", {
    method: "POST",
    headers: {
      "x-goog-api-key": env.GEMINI_API_KEY,
      "content-type": "application/json",
    },
    body: JSON.stringify(tokenRequest),
  });

  if (!response.ok) {
    return upstreamErrorResponse("/gemini-live-token", response);
  }

  const createdToken = (await response.json()) as { name?: string };
  if (!createdToken.name) {
    return jsonResponse({ error: "Gemini returned no token name" }, 502);
  }
  // The token only; nothing else from the upstream response leaves the worker.
  return jsonResponse({ token: createdToken.name }, 200);
}

// MARK: - ElevenLabs

async function handleTTS(request: Request, env: Env): Promise<Response> {
  if (!env.ELEVENLABS_API_KEY) return missingSecretResponse("ELEVENLABS_API_KEY");
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    return upstreamErrorResponse("/tts", response);
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
