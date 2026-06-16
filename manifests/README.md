# Manifests

Every declarative resource in this demo lives here as a standalone, commented
YAML file. `setup.sh` and `demo.sh` apply these exact files — there is **no
inline YAML in the scripts**, so what you read here is what runs.

Each file is heavily commented so it stands on its own as a reference example.

> **Two apply paths.** Most files are Kubernetes resources applied with
> `kubectl apply -f`. The **`agentregistry/`** files (except `arctl-helper.yaml`)
> are **not** Kubernetes CRDs — they're AgentRegistry catalog objects
> (`ar.dev/v1alpha1`) managed through the registry API via the **`arctl`** CLI.
> Because the registry validates OIDC tokens against the in-cluster Keycloak
> issuer, the scripts run `arctl` from an in-cluster helper pod
> (`agentregistry/arctl-helper.yaml`) rather than from your laptop:
> `kubectl exec -i deploy/arctl-helper -n agentregistry-system -- arctl-apply < file.yaml`

## Layout

| Folder | What it defines | Applied in (Act) |
|--------|-----------------|------------------|
| `infrastructure/` | ServiceMeshController, Keycloak (+ realm), AgentGateway Gateway & Parameters, **`istiod-alias.yaml`** (lets BYO-agent waypoints fetch their mTLS cert) | setup only |
| `llm-providers/` | Anthropic + OpenAI `AgentgatewayBackend` + `HTTPRoute` | Act 1 |
| `mcp-servers/` | Website fetcher (local), weather + GitHub-profile (composable), GitHub remote, the MCP routes, plus the `everything` server + `virtual-mcp` federation | Acts 2 & 6 |
| `security/` | GitHub OAuth elicitation policy | Act 3 |
| `observability/` | AgentGateway tracing policy (OTLP → bundled collector → ClickHouse → UI Tracing tab) | setup only |
| `kagent/` | `ModelConfig`s, `RemoteMCPServer`s, and `agents/` | Act 4 |
| `kagent-demo/` | Numbered steps for the **kagent-focused demo** (`kagent-demo.sh`): tool servers (`kdemo-*`) + the declarative `helpdesk` agent it grows | `kagent-demo.sh` Acts 1–2 |
| `agentregistry/` | `arctl-helper` (in-cluster arctl runner), `Runtime`, catalog `MCPServer`s + `Agent`s, `AccessPolicy`s, promotion before/after (`everything-mcp-direct`/`-promoted`), federated `mcp-gateway`; **`weatherwise-agent.yaml` + `deployments.yaml`** (promote a packaged agent → kagent runtime) | Acts 5 & 6, `kagent-demo.sh` Act 3 |

> **`kagent-demo/` and the AR promotion files are applied by `kagent-demo.sh`, not
> `setup.sh`** (setup only builds + imports the `agents-src/weatherwise` image). See
> [../KAGENT-DEMO.md](../KAGENT-DEMO.md). Declarative agents (system prompt + tool
> refs) can't be promoted through AgentRegistry — promotion is the build-and-ship
> path for **BYO-image** agents (`spec.source.image`), which AR's Kagent adapter
> deploys as a `kagent.dev/Agent` of `type: BYO`.

> `agentregistry/arctl-helper.yaml` **is** a normal Kubernetes Deployment (applied
> with `kubectl`). It installs `arctl` once and exposes `arctl-apply` / `arctl-delete`
> so the other `agentregistry/` files (which are `arctl`-managed, not `kubectl`)
> can be applied from inside the cluster where the OIDC issuer resolves.

### Act 6 — "promoting" an MCP server to the gateway

There is **no one-click product feature** to promote an AgentRegistry catalog
entry onto AgentGateway. Act 6 composes two documented features to achieve it:

- **Virtual MCP** (`mcp-servers/virtual-mcp.yaml`) — one `AgentgatewayBackend`
  federates multiple MCP targets behind a single `/mcp/federated` endpoint.
  ([docs](https://docs.solo.io/agentgateway/latest/mcp/virtual/))
- **Repointing a catalog entry** — `agentregistry/everything-mcp-direct.yaml`
  (URL → raw Service) vs `…-promoted.yaml` (URL → gateway). Applying the second
  over the first is the "promotion": raw/ungoverned → governed via the gateway.

## Apply order (what setup.sh does)

```
infrastructure/service-mesh-controller.yaml
infrastructure/keycloak-realm.yaml
infrastructure/keycloak.yaml
infrastructure/agentgateway-parameters.yaml
infrastructure/agentgateway-gateway.yaml
llm-providers/anthropic.yaml
llm-providers/openai.yaml
mcp-servers/website-fetcher.yaml
mcp-servers/github-remote.yaml
mcp-servers/weather-composable.yaml
mcp-servers/github-profile-composable.yaml
mcp-servers/routes.yaml
mcp-servers/everything-server.yaml      (Virtual MCP federation member)
mcp-servers/virtual-mcp.yaml            (federated /mcp/federated endpoint)
security/github-elicitation-policy.yaml
kagent/modelconfigs.yaml
kagent/remote-mcp-servers.yaml
kagent/agents/            (whole directory)
observability/agentgateway-tracing.yaml (applied after kagent — the collector lives in the kagent ns)
agentregistry/arctl-helper.yaml         (kubectl — deploys the in-cluster arctl runner)
# the remaining agentregistry/ files are applied via the helper (arctl, not kubectl):
agentregistry/runtime.yaml
agentregistry/mcp-servers.yaml
agentregistry/mcp-gateway.yaml          (federated endpoint as a catalog entry)
agentregistry/agents.yaml
agentregistry/access-policies.yaml
```

(`agentregistry/everything-mcp-direct.yaml` and `…-promoted.yaml` are applied by
`demo.sh` Act 6 to show the before/after of promotion, not by `setup.sh`.)

Apply a single Kubernetes file by hand:

```bash
kubectl apply -f mcp-servers/weather-composable.yaml
```

Apply a single **AgentRegistry catalog** file by hand (via the helper):

```bash
kubectl exec -i deploy/arctl-helper -n agentregistry-system -- arctl-apply \
  < agentregistry/runtime.yaml
```

## Secrets are NOT in these files

Anything holding a credential is created imperatively by the scripts from your
environment variables — never checked into a manifest. The backends/configs here
just reference them by name. The secrets are:

| Secret | Namespace | Created from | Referenced by |
|--------|-----------|--------------|---------------|
| `anthropic-secret` | `agentgateway-system` | `$ANTHROPIC_API_KEY` | `llm-providers/anthropic.yaml` |
| `openai-secret` | `agentgateway-system` | `$OPENAI_API_KEY` | `llm-providers/openai.yaml` |
| `elicitation-oidc` | `agentgateway-system` | `$GITHUB_CLIENT_ID` / `$GITHUB_CLIENT_SECRET` | `security/github-elicitation-policy.yaml` |
| `anthropic-api-key` | `kagent` | `$ANTHROPIC_API_KEY` | `kagent/modelconfigs.yaml` |
| `openai-api-key` | `kagent` | `$OPENAI_API_KEY` | `kagent/modelconfigs.yaml` |
| `kagent-openai` | `kagent` | `$OPENAI_API_KEY` | built-in k8s-agent's `default-model-config` |
| `jwt` | `kagent` | `openssl genrsa` (OBO signing key) | kagent controller |

To create them yourself (the script does this for you):

```bash
kubectl create secret generic anthropic-secret -n agentgateway-system \
  --from-literal=Authorization="$ANTHROPIC_API_KEY"
```

## Hardcoded service URLs

Namespaces are fixed, so in-cluster service URLs are written out literally
rather than templated — e.g. the AgentGateway proxy is always reachable at:

```
http://agentgateway-proxy.agentgateway-system.svc.cluster.local
```

That URL is what the kagent `ModelConfig` `baseUrl`s, the kagent
`RemoteMCPServer` `url`s, and the AgentRegistry catalog `MCPServer` `url`s all
point at — so every agent's LLM and tool traffic flows through the gateway.

## Gotchas encoded in these manifests

- **`kagent/agents/*`: every `mcpServer` tool sets explicit, non-empty `toolNames`.**
  Omitting it crashes the agent pod (the ADK requires a list), and `[]` is dropped
  by the controller API (omitempty) → the kagent UI agents page does
  `mcpServer.toolNames.map(...)` unguarded and crashes on `undefined`. If a
  composable MCP's tools change, update the matching `toolNames`.
- **OBO / chat-as-the-user (github-assistant) requires TWO settings that work together:**
  1. `SKIP_OBO=true` on the kagent controller (set by `setup.sh` — patches
     `kagent-enterprise-config` + restarts the controller). Default `false` makes
     the controller mint its OWN OBO JWT (issuer `kagent.kagent`) that AGW's STS
     (trusts Keycloak) rejects → chat OBO fails. `true` = pass the raw user token
     through and let **AgentGateway's STS** perform the exchange.
  2. `KAGENT_PROPAGATE_TOKEN=true` on the agent (`spec.declarative.deployment.env`
     in `agents/github-assistant.yaml`) — forwards the caller's `Authorization`
     to the MCP call. (`allowedHeaders: [Authorization]` on the tool too.)
  The GitHub OAuth MCP can't be server-side-discovered (no user token at discover
  time), so `agw-github-remote` stays `Accepted=False`/no `discoveredTools` — fine,
  because the agent declares EXPLICIT verified `toolNames`, so no discovery is needed
  and the UI page doesn't crash. STS tokens are in-pod SQLite (≈24h TTL) → re-consent
  at localhost:9090/age/elicitations each session.
- **LLM `HTTPRoute`s strip `Origin`/`Referer`.** Anthropic rejects browser-origin
  requests (CORS guard) — without the filter, the UI playground gets 401s.
- **The `tracing` policy is infrastructure — never bulk-delete AGW policies.**
  `demo.sh` reset once did `delete enterpriseagentgatewaypolicy --all` and silently
  killed the UI Tracing tab (no act re-creates the policy). Reset now deletes only
  demo-owned policies and defensively re-applies `observability/agentgateway-tracing.yaml`.
- **Via-gateway ModelConfigs use `provider: OpenAI` — even for Claude.**
  AgentGateway's LLM routes speak the unified OpenAI-compatible API and translate
  to the provider's native API upstream. kagent's `Anthropic` provider speaks
  Anthropic-native, which the gateway rejects with
  `failed to marshal request: missing field 'type'` the moment an agent sends
  tool definitions (chat without tools works, so this hides until agents use tools).

## API groups at a glance

| API group | Kind(s) | Source |
|-----------|---------|--------|
| `gateway.networking.k8s.io/v1` | `Gateway`, `HTTPRoute` | upstream Gateway API |
| `agentgateway.dev/v1alpha1` | `AgentgatewayBackend` | AgentGateway OSS |
| `enterpriseagentgateway.solo.io/v1alpha1` | `EnterpriseAgentgatewayBackend`, `...Policy`, `...Parameters` | AgentGateway Enterprise (composable MCP, elicitation, STS) |
| `kagent.dev/v1alpha2` | `Agent`, `ModelConfig`, `RemoteMCPServer` | kagent |
| `ar.dev/v1alpha1` | `Runtime`, `MCPServer`, `Agent`, `AccessPolicy` | AgentRegistry |
| `operator.gloo.solo.io/v1` | `ServiceMeshController` | Gloo Operator (ambient mesh) |
