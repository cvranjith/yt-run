# Requirement: Cloudflare Worker as Personal AI Gateway / Router

## 0. How to use this document (instructions to Claude Code)

This is an **experiment and a teaching exercise**, not just a code drop. I want to
understand every step, not just run it.

Please:

1. **Explain before you build.** For each setup phase, tell me what I am about to do,
   which URL to open, what I will see there, and what I should end up with. I have
   never used Cloudflare Workers before. Assume I know backend architecture well
   (Java/Spring Boot, integration, OCI/OpenShift) but nothing about the Cloudflare
   platform or the Wrangler tooling.
2. **Stop at each checkpoint.** Where I have to do something in a browser or on a
   provider's console (sign up, copy an API key), stop and wait for me to confirm,
   rather than assuming it is done.
3. **Keep the code minimal.** This router should stay small and readable. No
   framework, no build pipeline beyond Wrangler, no dependencies unless unavoidable.
4. **Tell me what things cost** and which free-tier limit each step is consuming.

---

## 1. Goal

One always-on HTTPS endpoint that all my personal apps call for AI work. The apps
know **one URL, one auth token, and a service ID**. The router decides which model
or backend actually serves the request.

```
iPhone app (YouTube Gate)  ─┐
DeepSink (later)           ─┼──▶  Cloudflare Worker (router)  ──┬──▶ Groq API
Other personal apps        ─┘                                   ├──▶ Gemini API
                                                                └──▶ Mac mini
                                                                     (Ollama,
                                                                      Codex-style
                                                                      workloads)
```

Why a Worker: always on, no VM to patch or renew, no cold starts, free tier is
sufficient, and it runs at the edge (I am in Singapore).

## 2. Scope

**In scope**
- Cloudflare account + Worker setup, explained step by step
- A service-ID-based routing table held in config, not scattered through code
- Cloud backends: Groq and Gemini Flash
- Local backends on my Mac mini: Ollama, and a Codex-style/agentic workload endpoint
- Secrets handling
- A way to test each route with curl before any app is changed

**Out of scope for this experiment**
- Changing the iPhone app (that comes after the router works)
- Streaming responses (note where it would go, but do not build it)
- Rate limiting, quotas, billing dashboards
- Auth beyond a single shared bearer token

## 3. Setup phases I want walked through

### Phase A — Cloudflare account and tooling
- Which URL to sign up at, and what plan I end up on
- Whether I need a domain; if not, what my `*.workers.dev` URL will look like
- Installing/using Wrangler (I have Node on my Mac), logging in, and what `wrangler`
  actually does
- Creating the project, the resulting file layout, and what each file is for
- Local dev (`wrangler dev`) vs deploy (`wrangler deploy`), and how to see logs

### Phase B — Provider accounts and keys
For **each** of Groq and Gemini, tell me:
- The console URL to sign up at
- How to create an API key and where it is shown (and that I may only see it once)
- Where to find my current rate limits
- Which model IDs are current and appropriate for transcript summarisation, and how
  to check the model list rather than trusting a hardcoded name
- The exact request/response shape (Groq is OpenAI-compatible; Gemini is not)
- A `curl` I can run from my Mac to prove the key works **before** any Worker code

### Phase C — Secrets
- How to store each key as a Worker secret (`wrangler secret put`), not in code or in
  `wrangler.toml`
- How secrets differ from vars, and how to list/rotate them
- Confirm the keys never reach the client

### Phase D — Reaching the Mac mini
My Mac mini runs Ollama and will host Codex-style/agentic workloads. It is on my home
network and currently reachable over Tailscale.

**Important:** a Cloudflare Worker cannot join my tailnet. Explain the options and
recommend one:
- **Cloudflare Tunnel** (`cloudflared` on the Mac mini) exposing a hostname the Worker
  can `fetch` — likely the right answer, so explain install, login, the tunnel config,
  and how to lock it down so only my Worker can use it
- Tailscale Funnel as an alternative, with its tradeoffs
- Anything else worth knowing

Also cover: what happens when the Mac mini is **asleep or offline**, and how the
router should behave then (see FR-5).

### Phase E — Deploy and verify
- Deploy, then a `curl` per service ID proving each route end to end
- How to tail logs and debug a failing route

---

## 4. Functional requirements

### FR-1: Single request contract
All clients POST to one endpoint with a bearer token. Proposed shape — **push back if
you see a better one**:

```
POST https://<worker>.workers.dev/v1/invoke
Authorization: Bearer <GATEWAY_TOKEN>
Content-Type: application/json

{
  "service": "summarize.youtube",
  "input": "<the transcript text>",
  "options": { }          // optional, e.g. max_words
}
```

Response:

```json
{ "service": "summarize.youtube", "backend": "groq", "output": "…", "ms": 1234 }
```

Errors return a consistent JSON shape with an HTTP status, never a provider's raw error body.

### FR-2: Service registry as config
A single declarative map — service ID → backend, model, prompt, options — kept at the
top of the Worker (or in a separate module, or KV if you argue for it). Adding a new
service must mean editing this map only, never the routing logic.

Initial services (names are a proposal, suggest better if the convention is weak):

| Service ID | Backend | Notes |
|---|---|---|
| `summarize.youtube` | Groq | Transcript → TL;DR + key points. The one I need first. |
| `summarize.long` | Gemini Flash | Same job, long-context model, for big transcripts |
| `chat.generic` | Gemini Flash | Passthrough prompt, no baked-in system prompt |
| `local.ollama` | Mac mini → Ollama | Model name passed in options, default configurable |
| `local.codex` | Mac mini → agent endpoint | Pass through as-is; the Mac mini owns the contract |

System prompts live in the registry, server-side, so I can change them without
shipping an app update. That is a main reason this router exists.

### FR-3: Provider adapters
One small function per backend, converting the common request into that provider's
format and its response back into the common shape:
- **Groq** — OpenAI-compatible, `https://api.groq.com/openai/v1/chat/completions`
- **Gemini** — its own `generateContent` shape
- **Mac mini (Ollama)** — Ollama's API
- **Mac mini (Codex/agent)** — as-is passthrough, minimal transformation

Adding a provider later (Anthropic, OpenAI, a different local model) should mean one
new adapter plus registry entries, nothing else.

### FR-4: Auth
- A single shared secret bearer token, stored as a Worker secret, checked on every
  request; reject with 401 otherwise.
- Tell me how to rotate it and what changes on the client side when I do.
- Note anything I should add later if I ever share this with anyone else.

### FR-5: Failure behaviour
- If a backend errors or times out, return a clear error naming which backend failed —
  never a silent empty summary.
- **Mac mini offline** must produce a distinct, recognisable error so the app can say
  "local model unavailable" rather than "something went wrong".
- Optional per-service `fallback` in the registry (e.g. `local.ollama` falls back to
  Groq). Implement it only if it stays simple; otherwise note it as future work.
- Set a sane timeout per backend and explain what the Worker does when it fires.

### FR-6: Stay inside the free tier
The free plan's **10 ms CPU limit per invocation** is the real constraint. Wall-clock
waiting on a slow model is free and unlimited while the client stays connected, but
parsing/serialising a large transcript is real CPU work.

So:
- Avoid parsing or re-stringifying large bodies where possible; prefer streaming or
  pass-through construction of the upstream body.
- If the service ID can be read from a header or query param instead of parsing the
  JSON body, say so and show that variant.
- Flag anywhere in the code that could blow the 10 ms budget on a ~100k-character
  transcript.
- Tell me plainly if you think this design needs the $5/month Workers Paid plan
  (30 s CPU) — I would rather pay $5 than fight the limit, but I want to know why.
- Also note the free-tier caps on requests/day and subrequests per invocation.

### FR-7: Observability
- Log per request: service ID, backend, latency, status, approximate input size.
- No transcript content in logs.
- Show me how to tail these live and where they appear in the dashboard.

## 5. Non-functional

- **Simplicity over cleverness.** I should be able to read the whole Worker in one sitting.
- **No secrets in the repo.** Include a `.gitignore` and a `.dev.vars.example`.
- **Portability.** The routing logic should be plain enough that I could move it to a
  small Node service on a VM later without a rewrite. Keep Cloudflare-specific
  surface confined to the entry point.
- **Latency.** Router overhead should be negligible; the model call dominates.

## 6. Deliverables

1. The Worker source (keep it to a few files)
2. `wrangler.toml` / `wrangler.jsonc` with comments explaining each setting
3. `README.md` — the step-by-step setup, written so I could redo it from scratch
4. `test.sh` or a curl cheat sheet, one call per service ID
5. `.dev.vars.example`
6. A short note on what I would change to add streaming, and what I would change to
   move off Cloudflare

## 7. Acceptance criteria

1. `curl` against `summarize.youtube` with a real transcript returns a usable summary.
2. `curl` against `summarize.long` returns a summary from Gemini; response says which
   backend served it.
3. `curl` against `local.ollama` returns a completion from my Mac mini while it is awake.
4. With the Mac mini asleep, the same call returns a clear, distinct error within the
   configured timeout.
5. A bad or missing bearer token returns 401.
6. An unknown service ID returns a clear 400 listing valid service IDs.
7. Adding a hypothetical new service requires editing only the registry — demonstrate
   this by adding one.
8. No key or token appears in the repo or in any response body.

## 8. Open questions for you to raise with me

Ask me rather than assuming, if you hit:
- Whether I want a custom domain or `*.workers.dev` is fine
- Whether to use KV for the registry instead of in-code config
- Whether `local.codex` should be a passthrough proxy or have a defined contract
- Anything where the free-tier limits would push the design in a direction I did not ask for
