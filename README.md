# Solo Agentic Demo

> 📖 **Read the write-up:** [Capping LLM Spend at the AI Gateway: Budgets and Virtual Keys](https://webofmike.com/llm-cost-controls-ai-gateway/)

A complete, scripted demo of Solo's agentic stack on a local k3d cluster:

- **Ambient Mesh** (Istio, via Gloo Operator) — automatic mTLS
- **AgentGateway Enterprise** — LLM + MCP gateway with auth, composable MCP,
  elicitation, and **cost controls** (virtual keys, priced spend, budgets)
- **kagent Enterprise** — Kubernetes-native AI agent runtime
- **AgentRegistry Enterprise** — agent/MCP catalog with RBAC and tracing
- **Keycloak** — OIDC for the UIs and RBAC

Validated versions: AgentGateway Enterprise **v2026.8.2**, kagent Enterprise +
Solo Enterprise UI **0.5.5**, AgentRegistry Enterprise **2026.8.0**. Override any
of them in `.env` (`AGW_VERSION`, `KAGENT_ENT_VERSION`, `AR_VERSION`).

Two LLM providers (Anthropic + OpenAI), five MCP servers (local, remote, two
composable, plus a federated "Virtual MCP" endpoint), and five agents —
including a multi-model A2A orchestrator — all wired so every LLM and tool call
flows through AgentGateway, with **distributed tracing** on every call
(gateway spans + kagent agent spans → ClickHouse → the UI Tracing tab) and
**priced, attributed spend** on every LLM call (→ the UI Cost Management tab).

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | One-shot full deployment — cluster, mesh, AGW, kagent, AgentRegistry, all resources |
| `demo.sh` | Interactive, act-by-act walkthrough that builds the stack live (resets first) |
| `DEMO.md` | **Presenter's runbook** — prep, smoke test, act-by-act talking points, elicitation walkthrough, troubleshooting |
| `governance-demo.sh` | Security/governance walkthrough — identity & OBO, locale-scoped model access in CEL, WAF for LLM & MCP, agent forensics, audit output (`--check` smoke-tests it) |
| `GOVERNANCE-DEMO.md` | Runbook for the above — personas, act-by-act results, the gotchas, and what it deliberately does *not* claim |
| `port-forward.sh` | Exposes all UIs/APIs locally (re-run if forwards die) |
| `teardown.sh` | Deletes the k3d cluster |
| `.env.example` | Template for secrets — `cp .env.example .env` and fill in (`.env` is gitignored) |
| `manifests/` | Every YAML resource, commented and standalone — see `manifests/README.md` |

## Prerequisites

- `k3d`, `kubectl`, `helm`, `jq`, `openssl`
- **Solo licenses** — one of:
  - `SOLO_LICENSE_KEY` in `.env` (a single trial license usually covers all products), or
    the per-product keys `AGENTGATEWAY_LICENSE_KEY` / `SOLO_ISTIO_LICENSE_KEY` / `KAGENT_LICENSE_KEY`; or
  - *(Solo employees)* the `solo-io/licensing` repo cloned at `~/licensing` — setup auto-generates
    them (this path also needs `go` 1.24+); or
  - nothing set — setup will **prompt** you to paste each license.
- A GitHub OAuth App (callback URL `http://localhost:9090/age/elicitations`)
- Secrets in `.env` (preferred — set once) or exported env vars (or you'll be prompted):
  - `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`
  - `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`

```bash
cp .env.example .env   # then fill in real values — both scripts source it automatically
```

## Quick start

```bash
./setup.sh            # build everything (~15 min)
./port-forward.sh     # expose the UIs (started automatically by setup too)
```

Then open the **Solo Enterprise UI** at <http://localhost:9090> (demo/demo).

## Run the interactive demo

```bash
./demo.sh             # full walkthrough, press Enter to advance
./demo.sh --act 4     # reset, then play acts 1..N (1-8)
./demo.sh --reset     # clear demo resources, keep infrastructure
```

The eight acts:

1. **AgentGateway** — add Anthropic + OpenAI, call them through the gateway
2. **MCP Servers** — local, composable (zero-code), and remote MCP
3. **Enterprise Security** — ambient mTLS + GitHub OAuth elicitation (the OBO
   flow lives at the gateway layer — test it with MCP Inspector against
   `/mcp/github-remote`; it can't be a kagent tool because kagent discovers
   tools server-side without a user token)
4. **kagent** — ModelConfigs, RemoteMCPServers, and 5 agents (incl. A2A orchestrator)
5. **AgentRegistry** — catalog the agents/MCPs with 3-tier RBAC (applied via an
   in-cluster `arctl` helper pod — `ar.dev` objects are registry-API resources,
   not Kubernetes CRDs; see `manifests/README.md`)
6. **Promote an MCP server to the gateway** — take a cataloged-but-ungoverned MCP server, federate it onto AgentGateway (Virtual MCP), and repoint the catalog entry at the governed endpoint. *(A composed workflow on documented features — not a one-click product action.)*
7. **Advanced AgentGateway** — four "gateway power-user" capabilities:
   **Eager Auth** (apiKey + real OIDC/JWT against Keycloak, requests rejected at
   the gateway before backends are touched), **Prompt Policies** (PII masking,
   system-message injection, request defaults — all on the LLM backend),
   **OpenAPI → MCP** (auto-generate MCP tools from a REST spec, zero code), and
   **Code Mode** (one script tool that replaces N tool round-trips).
   See `manifests/agw-advanced/` for the manifests.
8. **Cost Management** — the FinOps story, end to end: a **model cost catalog**
   (per-token USD rates on the Gateway, so token counts become dollars),
   **virtual keys** that attribute every request to a user and a team,
   **budgets** (`EnterpriseAgentgatewayBudget`) in token and USD units with
   `Block` (HTTP 429) or `Audit` actions, and the **Cost Management UI** — spend
   by provider/model/group/user/key with CSV export, the price catalog, budget
   usage, dimensions, and virtual-key admin. See `manifests/cost-management/`.

`demo.sh` shows and applies the **same files** in `manifests/`, so the on-screen
YAML is exactly what runs. Browse `manifests/` to read the examples directly.

### kagent-focused demo

A separate, tighter walkthrough of the kagent runtime — adding tools, adding
tool servers, and **promoting an agent from AgentRegistry onto kagent**:

```bash
./kagent-demo.sh            # 3 acts: tool server → agent tools → AR promotion
./kagent-demo.sh --act 3    # jump to an act (1-3)
./kagent-demo.sh --reset    # remove just this demo's resources
```

See [KAGENT-DEMO.md](KAGENT-DEMO.md) for the runbook. Act 3 promotes a packaged
(container) agent whose source lives in [`agents-src/weatherwise/`](agents-src/weatherwise/);
`setup.sh` builds that image and loads it into k3d (Docker required for Act 3).

### Security & governance demo

A walkthrough aimed at security architecture and AI-governance audiences —
identity, locale-scoped model access, WAF for AI traffic, agent forensics, and
the audit output:

```bash
./governance-demo.sh            # 5 acts: identity/OBO → locale + allowlist (CEL) →
                                #   WAF for LLM & MCP → forensics → observability
./governance-demo.sh --check    # non-interactive smoke test of every assertion
./governance-demo.sh --act 3    # reset, fast-forward acts 1..2, play act 3
./governance-demo.sh --reset    # clear this demo's resources only
```

See [GOVERNANCE-DEMO.md](GOVERNANCE-DEMO.md) for the runbook. Its manifests live
in [`manifests/governance/`](manifests/governance/) and are **scoped to their own
routes** (`/governed-llm`, `/mcp/governed`), so this demo neither disturbs nor is
disturbed by `demo.sh` / `agentgateway-demo.sh`. It needs two objects those
create — `anthropic-secret` and the `weather-mcp` backend — both of which
`setup.sh` provides.

Run `--check` before any live delivery: it exercises all 42 assertions in about
four minutes and prints a pass/fail line for each.

### Agent Substrate sidetrack (alpha / experimental)

A separate sandbox for [Agent Substrate](https://github.com/agent-substrate/substrate)
— the Google-adjacent open-source layer that multiplexes many agent-like
"actors" onto a small pool of warm Kubernetes pods, with per-actor gVisor
isolation and full RAM/FS state snapshots across suspend/resume cycles.

Runs in **its own `kind` cluster** (with kagent OSS + UI), does NOT touch the
main k3d demo:

```bash
./setup-substrate.sh           # kind cluster + Substrate + counter demo + kagent OSS/UI
./substrate-demo.sh            # 5 acts: model → resume → density → suspend →
                               #   deploy OpenClaw AgentHarness in the kagent UI
./substrate-demo.sh --reset    # delete created actors + harness, keep the pools
./teardown-substrate.sh        # nuke the kind cluster
```

Act 5 is the headline: a kagent **AgentHarness** (`runtime: substrate`,
`backend: openclaw`) deployed and driven **from the kagent UI** — a real
coding agent, gVisor-sandboxed on Substrate. The OpenClaw model config is
built from your `.env` Anthropic key.

See [SUBSTRATE-DEMO.md](SUBSTRATE-DEMO.md) for the runbook. Substrate is
explicitly **pre-stable** per upstream — *"VERY early development. APIs are
almost guaranteed to change."* Pinned to a known-good commit in
`setup-substrate.sh`; bump deliberately + re-validate.

## URLs (after `port-forward.sh`)

| URL | What | Login |
|-----|------|-------|
| **<http://localhost:9090>** | **Solo Enterprise UI — the whole demo, incl. the GitHub OAuth consent redirect** | **demo / demo** |
| <http://localhost:8080> | Keycloak (admin console **and** the OIDC issuer) — operator only | admin / admin |
| <http://localhost:8081> | AgentGateway Proxy (LLM + MCP routes) — debug only | — |
| <http://localhost:12121> | AgentRegistry API (for `arctl`) — operator only | — |

The audience only ever sees **`localhost:9090`**. Login, agent chat, the GitHub
OAuth consent (it redirects back to `:9090/age/elicitations`), tracing, and
**Cost Management** (`:9090/age/` → Cost Management) all live there — no second
tab, no curl. The other three ports are operator/debug.

> **One-time host entry (required for browser SSO).** The Solo UI logs in via the
> in-cluster OIDC issuer `keycloak.keycloak.svc.cluster.local:8080`. Map it to the
> Keycloak port-forward so your browser can reach it:
> ```bash
> echo "127.0.0.1 keycloak.keycloak.svc.cluster.local" | sudo tee -a /etc/hosts
> ```
> This is why Keycloak is forwarded on `8080` (matching the issuer) and AgentGateway
> moved to `8081`.

## Architecture

```
User → Enterprise UI → AgentRegistry (catalog + RBAC)
  → kagent (runs agents as pods)
    → AgentGateway (LLM routing + auth)        → Anthropic / OpenAI
    → AgentGateway (MCP routing + elicitation) → MCP servers (local/remote/composable)
    → A2A protocol (agent-to-agent delegation)
  All pod-to-pod traffic encrypted by Ambient Mesh (ztunnel)

Cost path (same gateway, same request):
  virtual key → attribution (virtualKey / user / group)
    → model cost catalog → realized USD on the span
      → budget check → allow, audit, or 429
        → spans → ClickHouse → Cost Management dashboard
```

## Good to know

- **Tracing** — every LLM/MCP call through the gateway and every agent run emits
  OTel spans (token counts, models, tools) → ClickHouse → the UI **Tracing** tab.
  Wired by `manifests/observability/agentgateway-tracing.yaml` + kagent's
  `otel.tracing` helm values (both applied by `setup.sh`). The **Cost Management**
  dashboard rides the same pipeline — no tracing, no spend charts.
- **Cost Management is opt-in.** `setup.sh` sets
  `products.agentgateway.features.cost-management=true` (plus
  `cost-management-writes=true`) on the management chart. It ships **off** because
  the ClickHouse reads behind the spend charts aren't optimized yet — fine at demo
  scale, a deliberate decision in production. Set writes to `false` for a
  read-only FinOps view.
- **Cost numbers are only as good as the catalog.** Models the catalog can't price
  add `$0` rather than erroring, so a partial catalog quietly undercounts. Check
  `agentgateway_cost_catalog_lookups_total` on the proxy's `:15020/metrics`
  (`status="Exact"` = priced). Rates in `manifests/cost-management/01-model-costs.yaml`
  are illustrative demo values — generate real ones with
  `agctl costs import --providers openai,anthropic`.
- **Budgets are approximate and fail open.** Token counts aren't known until the
  response, so usage is debited after the fact (a burst can overshoot slightly),
  and if the rate limit service is unreachable requests are allowed through.
  Say both out loud before a customer finds them.
- **AgentRegistry → Gateways page is empty by design.** AR's managed-gateway
  feature (`ar.dev Gateway`) only supports cloud runtimes (AWS BedrockAgentCore /
  Gemini) in v2026.5.4 — it provisions an EC2 AgentGateway. The kagent runtime
  has no gateway support, so `/are/gateways` stays empty for this stack.
- **Placeholder keys** — if `.env` still has template values, deployment works
  but live LLM calls (playground, agents) return 401s from the providers.
- **k3d CNI quirk is auto-handled** — `setup.sh` bind-mounts k3s's CNI conf dir
  and symlinks the istio-cni binary on each node; without this, istio ambient
  never activates on k3d (and in the worst case pod creation breaks).

## Teardown

```bash
./teardown.sh         # deletes the 'ai-demo' k3d cluster
```
