# Solo Agentic Demo

A complete, scripted demo of Solo's agentic stack on a local k3d cluster:

- **Ambient Mesh** (Istio, via Gloo Operator) — automatic mTLS
- **AgentGateway Enterprise** — LLM + MCP gateway with auth, composable MCP, elicitation
- **kagent Enterprise** — Kubernetes-native AI agent runtime
- **AgentRegistry Enterprise** — agent/MCP catalog with RBAC and tracing
- **Keycloak** — OIDC for the UIs and RBAC

Two LLM providers (Anthropic + OpenAI), five MCP servers (local, remote, two
composable, plus a federated "Virtual MCP" endpoint), and five agents —
including a multi-model A2A orchestrator — all wired so every LLM and tool call
flows through AgentGateway, with **distributed tracing** on every call
(gateway spans + kagent agent spans → ClickHouse → the UI Tracing tab).

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | One-shot full deployment — cluster, mesh, AGW, kagent, AgentRegistry, all resources |
| `demo.sh` | Interactive, act-by-act walkthrough that builds the stack live (resets first) |
| `DEMO.md` | **Presenter's runbook** — prep, smoke test, act-by-act talking points, elicitation walkthrough, troubleshooting |
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
./demo.sh --act 4     # reset, then play acts 1..N (1-7)
./demo.sh --reset     # clear demo resources, keep infrastructure
```

The seven acts:

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

### Agent Substrate sidetrack (alpha / experimental)

A separate sandbox for [Agent Substrate](https://github.com/agent-substrate/substrate)
— the Google-adjacent open-source layer that multiplexes many agent-like
"actors" onto a small pool of warm Kubernetes pods, with per-actor gVisor
isolation and full RAM/FS state snapshots across suspend/resume cycles.

Runs in **its own `kind` cluster**, does NOT touch the main k3d demo:

```bash
./setup-substrate.sh           # creates kind cluster + installs Substrate + counter demo
./substrate-demo.sh            # 4 acts: model → resume → density → suspend
./substrate-demo.sh --reset    # delete created actors, keep the pool
./teardown-substrate.sh        # nuke the kind cluster
```

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
OAuth consent (it redirects back to `:9090/age/elicitations`), and tracing all
live there — no second tab, no curl. The other three ports are operator/debug.

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
```

## Good to know

- **Tracing** — every LLM/MCP call through the gateway and every agent run emits
  OTel spans (token counts, models, tools) → ClickHouse → the UI **Tracing** tab.
  Wired by `manifests/observability/agentgateway-tracing.yaml` + kagent's
  `otel.tracing` helm values (both applied by `setup.sh`).
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
