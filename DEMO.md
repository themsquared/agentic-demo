# Demo Runbook — Solo Agentic Stack

The presenter's guide. Assumes nothing beyond a Mac with the prerequisites in
[README.md](README.md). Every command and click-path in here has been run and
verified against a clean install.

---

## 0. The demo a prospect actually sees (one browser tab)

Everything below this section is operator detail. **What the audience sees is one
tab.** Lead with this — it's the "this is easy" story:

1. Open **http://localhost:9090** → sign in **demo / demo** (one screen, real SSO).
2. **Agents** → **weather-assistant** → *"What's the weather in Tokyo right now?"*
   → live answer with real numbers. *(An agent calling a tool, no setup.)*
3. **github-assistant** → *"Who am I on GitHub?"* → the agent says it needs your
   permission and shows an **Authorize** link → click it → GitHub's own consent
   screen → approve → you land **back on the same tab** → ask again → it answers
   with **your** real GitHub profile.
4. **orchestrator-agent** → *"What's the weather in London, and who is the GitHub
   user octocat?"* → one agent fans out to two specialists.
5. **Tracing** tab → open the last trace → the full call tree, every LLM + tool hop.

No curl, no second UI, no token copy-paste — all of it happens at
`localhost:9090`. The OAuth consent redirect comes **back to the same tab**
because the callback is `http://localhost:9090/age/elicitations`. The curl/Inspector
paths in §3 and §5 are how *you* verify and how you'd explain the plumbing to an
engineer — not what you click through live.

---

## 1. One-time prep (before demo day)

1. **GitHub OAuth App** (needed for the elicitation/OBO demo):
   GitHub → Settings → Developer settings → OAuth Apps → New OAuth App
   - Homepage URL: `http://localhost:9090`
   - Authorization callback URL: `http://localhost:9090/age/elicitations` *(exact — no trailing slash)*
2. **Secrets**: `cp .env.example .env`, fill in:
   - `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` — real keys (placeholders deploy fine but every LLM call 401s)
   - `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` — from the OAuth App above
3. **Hosts entry** (one-time, needed for browser SSO):
   ```bash
   echo "127.0.0.1 keycloak.keycloak.svc.cluster.local" | sudo tee -a /etc/hosts
   ```
4. **Solo licenses** — set `SOLO_LICENSE_KEY` (or the three per-product keys) in `.env`,
   *or* (Solo employees) clone `solo-io/licensing` at `~/licensing` and setup generates them,
   *or* paste each when setup prompts. See README → Prerequisites.

## 2. Stand it up (~15 min, do this before the audience arrives)

```bash
./setup.sh            # full build: cluster → mesh → AGW → kagent → AgentRegistry
./port-forward.sh     # idempotent; re-run any time forwards die
```

| URL | What | Login |
|-----|------|-------|
| **http://localhost:9090** | **Solo Enterprise UI — the entire demo + OAuth consent lands here** | **demo / demo** |
| http://localhost:8080 | Keycloak (admin console + OIDC issuer) — *operator only* | admin / admin |
| http://localhost:8081 | AgentGateway proxy (LLM + MCP routes) — *debug only* | — |
| http://localhost:12121 | AgentRegistry API (`arctl`) — *operator only* | — |

Only the **bold** row matters to the audience. The other three are for you (the
operator) — never shown on screen.

## 3. Pre-demo smoke test (2 minutes, run every time)

```bash
# LLM through the gateway (expect 200 + a completion)
curl -s localhost:8081/anthropic/v1/chat/completions -H "content-type: application/json" \
  -d '{"model":"claude-sonnet-4-6","max_tokens":30,"messages":[{"role":"user","content":"say hi"}]}' | jq -r '.choices[0].message.content'

# Agent end-to-end with a real tool call (expect a weather report with numbers)
kubectl exec deploy/arctl-helper -n agentregistry-system -- sh -c \
  'curl -s -m 90 http://weather-assistant.kagent.svc.cluster.local:8080/ -H "content-type: application/json" \
   -d "{\"jsonrpc\":\"2.0\",\"id\":\"smoke\",\"method\":\"message/send\",\"params\":{\"message\":{\"role\":\"user\",\"kind\":\"message\",\"messageId\":\"m-smoke\",\"parts\":[{\"kind\":\"text\",\"text\":\"weather in Tokyo?\"}]}}}"' \
  | jq -r '[.. | objects | select(.kind=="text") | .text] | last'

# Traces flowing into storage (expect a growing number)
kubectl exec kagent-mgmt-clickhouse-shard0-0 -n kagent -- clickhouse-client -q \
  "SELECT ServiceName, count() FROM platformdb.otel_traces_json GROUP BY ServiceName"
```

All three pass → you're demo-ready. Any fail → see §8.

## 4. The guided demo (`./demo.sh`)

```bash
./demo.sh             # full walkthrough — press Enter to advance, Ctrl-C to bail
./demo.sh --act 4     # jump to an act (1–6)
./demo.sh --reset     # wipe demo resources, keep infrastructure (tracing survives)
```

The script **resets first**, then builds each layer live, showing the real
manifest before applying it. Have a browser open alongside.

| Act | What you build | The moment to sell |
|-----|----------------|--------------------|
| 1 — AgentGateway | Anthropic + OpenAI backends + routes | One `curl`, **no API key in the request** — the gateway injects it. Two providers, one unified OpenAI-compatible API. |
| 2 — MCP Servers | Local pod MCP, two **composable** MCPs (pure YAML, zero code), remote GitHub MCP, routes | The weather MCP is an HTTP API turned into agent tools with CEL — no container, no code. Demo live in MCP Inspector. |
| 3 — Security | Ambient mTLS check + GitHub elicitation policy | Every pod-to-pod hop is mTLS with zero sidecars; tool access can require **per-user OAuth consent** (run §5 here if you want the full flow). |
| 4 — kagent | ModelConfigs, RemoteMCPServers, 4 agents | Agents are CRDs. All LLM **and** tool traffic flows through the gateway. Chat live in the UI (§6 prompts). |
| 5 — AgentRegistry | Runtime, catalog entries, 3-tier RBAC | The governance layer — catalog, discovery, RBAC mapped to Keycloak groups. Applied via in-cluster `arctl` (not kubectl). |
| 6 — Promotion | "Everything" MCP server federated onto the gateway, catalog repointed | Lifecycle story: raw/ungoverned → governed + federated behind one `/mcp/federated` endpoint. *(Composed workflow, not a one-click product feature — say so.)* |

MCP Inspector (for Acts 2/3/6): `npx @modelcontextprotocol/inspector@0.21.2`,
Transport **Streamable HTTP**, URLs `http://localhost:8081/mcp/weather`,
`/mcp/github-profile`, `/mcp/federated`.

## 5. GitHub elicitation / OBO workflow (the auth showpiece)

The flow: agent calls a protected MCP → gateway has no stored token for the
user → returns an elicitation → user approves via GitHub OAuth → token stored
in the gateway STS → calls proceed **on behalf of the user**.

1. **Get a user token** (you are "demo"):
   ```bash
   curl -s -X POST "http://keycloak.keycloak.svc.cluster.local:8080/realms/agentgateway/protocol/openid-connect/token" \
     -d grant_type=password -d client_id=ar-cli-password -d username=demo -d password=demo -d scope=openid | jq -r .access_token
   ```
2. **Trigger**: MCP Inspector → Streamable HTTP → `http://localhost:8081/mcp/github-remote`
   → add header `Authorization: Bearer <token>` → **Connect**.
   It fails with *"request needs a token exchange, but token not available in STS"* —
   **that failure is the elicitation being created.** Show the error; it names the approval URL.
3. **Approve**: open **http://localhost:9090/age/elicitations** (demo/demo) →
   pending GitHub elicitation → authorize → real GitHub consent screen → approve →
   redirected back to the same tab, token now in the STS.
4. **Retry** the Inspector connect (same header) → GitHub tool list appears,
   acting as **your** GitHub account.
5. **Agent-driven OBO from the UI chat (the money demo).** Once consent is
   granted, open **github-assistant** in the UI and ask **"Who am I on GitHub?"**
   The agent answers with *your* real profile — private repo counts included —
   because the whole chain runs as you: UI chat (your Keycloak token) → kagent
   controller (`SKIP_OBO=true`, passes your raw token through) → agent
   (`KAGENT_PROPAGATE_TOKEN=true`, forwards it) → AgentGateway STS (exchanges it
   for your stored GitHub token) → GitHub. OBO is performed entirely by the
   **AgentGateway**, not kagent. Same chain works for "search my repositories",
   "list my open PRs", etc.

   Why those two settings matter: by default the controller mints its OWN OBO JWT
   (issuer `kagent.kagent`) that the AGW STS (which trusts Keycloak) rejects —
   that's the "doesn't work in chat" failure. `SKIP_OBO=true` defers OBO to the
   gateway. Both settings are applied by `setup.sh`.

> Tokens live in the STS's in-pod SQLite — an AGW control-plane restart **or any
> setup.sh rebuild** clears them and the consent must be redone (fine for a demo;
> Postgres is the durable option). Symptom: "token not available in STS" returns.

## 6. Chatting with agents (UI)

UI → **Agents** → pick an agent → chat. Verified prompts:

- **weather-assistant**: `What's the weather in Tokyo right now?` *(live Open-Meteo data via composable MCP)*
- **research-agent**: `Look up the GitHub user solo-io and summarize what they work on.`
- **github-assistant**: `Who am I on GitHub?` *(OBO — answers with YOUR profile via your GitHub token; requires the §5 consent done once this session)*
- **orchestrator-agent**: `What's the weather in London, and who is the GitHub user octocat?` —
  the money prompt: **GPT-4o** delegates over A2A to two **Claude** specialists, all through one gateway.
- **k8s-agent**: `What pods are running in the kagent namespace?`

## 7. The observability payoff

UI → **Tracing**. Every chat from §6 produced spans from *both* layers:
gateway spans (per LLM call with `gen_ai.*` model/token attributes; per MCP
method like `tools/list`) and agent execution spans. Open a trace from the
orchestrator prompt to show the full delegation tree.

## 8. If something's off (symptom → fix)

| Symptom | Cause / fix |
|---------|-------------|
| UI login redirect fails to resolve | Missing `/etc/hosts` entry (§1.3) |
| Login error `invalid_scope` | Keycloak booted with a stale realm — `kubectl rollout restart deploy/keycloak -n keycloak`, re-run `./port-forward.sh` |
| Playground / LLM calls 401 | Placeholder keys in `.env` → fix `.env`, re-run `./setup.sh` (or recreate the two LLM secrets + restart nothing) |
| Agent chat: `missing field type` | A via-gateway ModelConfig was switched to `provider: Anthropic` — must stay `OpenAI` (gateway speaks the unified API; see `manifests/README.md` gotchas) |
| Agents page crashes ("error with the agents list") | An agent MCP tool lost its non-empty `toolNames`, or a RemoteMCPServer can't discover tools — `kubectl apply -f manifests/kagent/agents/` restores known-good |
| Tracing tab empty | The `tracing` policy was deleted (old demo.sh did this) — `kubectl apply -f manifests/observability/agentgateway-tracing.yaml` |
| Elicitation approval page unreachable | The 9090 UI forward died — re-run `./port-forward.sh` |
| Elicitation approved but Inspector still fails | If the error is `invalid request`: your Inspector reconnect dropped the `Authorization` header — re-add it. If it's still `token not available` / `elicitation pending`: the elicitation record is stuck — delete it and redo one clean trigger+approve: `TOKEN=$(<§5 step 1>); kubectl exec deploy/arctl-helper -n agentregistry-system -- curl -s -X DELETE -H "Authorization: Bearer $TOKEN" http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/elicitations/<ID>` (list IDs at the same URL without `/<ID>`) |
| Agent returns `Error code: 529 ... Overloaded` | Transient Anthropic capacity blip. The gateway now retries 429/5xx/529 (3 attempts) — sustained 529s mean Anthropic is genuinely saturated; wait a minute or demo an OpenAI-backed agent instead |
| Agent says a tool was "not found" | The LLM called a tool by a shortened name — gateway-exposed tool names are prefixed (`get-weather_get-weather`). Prompts now pin exact names; just re-ask |
| Anything weird after experiments | `./demo.sh --reset` rebuilds demo resources; nuclear: `./teardown.sh && ./setup.sh` |

## 9. Reset & teardown

```bash
./demo.sh --reset     # clean slate for demo resources; infra + tracing stay
./teardown.sh         # delete the whole k3d cluster
```
