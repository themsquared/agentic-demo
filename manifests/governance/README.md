# manifests/governance/ — Security, Governance, and Compliance

The manifests behind [`governance-demo.sh`](../../governance-demo.sh). Each file is
standalone, heavily commented, and carries its own verification commands in the
header — read them directly, or watch `governance-demo.sh` apply them in order.

Everything here hangs off **one route**, `/governed-llm`, plus one MCP route,
`/mcp/governed`. Nothing in this directory touches the shared backends, routes,
or secrets that `demo.sh` and `agentgateway-demo.sh` own, so this set can be
applied and reset independently of either.

| File | Creates | Control it demonstrates |
|---|---|---|
| `01-governed-llm-route.yaml` | `AgentgatewayBackend anthropic-governed`, `HTTPRoute governed-llm`, `EnterpriseAgentgatewayPolicy governed-llm-identity` | **Identity.** Strict JWT validation against the corporate IdP's JWKS, before any backend is contacted |
| `02-ofac-model-allowlist.yaml` | `EnterpriseAgentgatewayPolicy governed-llm-access` | **Authorization.** CEL over the JWT `country` claim (OFAC scoping) AND a model allowlist, in one expression |
| `03-model-aliases.yaml` | `EnterpriseAgentgatewayPolicy governed-llm-aliases` | **Abstraction.** Virtual model names (`acme-standard` / `acme-premium`) that decouple callers from vendors |
| `04-waf-llm.yaml` | `WAFPolicy` + `EnterpriseAgentgatewayPolicy governed-llm-waf` | **Payload inspection, LLM.** OWASP CRS + custom prompt-injection / jailbreak signatures over the request body |
| `05-waf-mcp.yaml` | `HTTPRoute mcp-governed`, `WAFPolicy` + `EnterpriseAgentgatewayPolicy mcp-governed-waf` | **Payload inspection, MCP.** JSON-RPC method allowlist + CRS and custom rules over tool arguments |
| `06-access-logs.yaml` | `EnterpriseAgentgatewayPolicy access-logs` | **Evidence.** Identity-enriched structured access logs, exported to ClickHouse over OTLP |

Apply the whole set:

```bash
kubectl apply -f manifests/governance/
```

## Prerequisites

Two objects these manifests reference are created by `setup.sh` (and by
`agentgateway-demo.sh` Acts 1–2):

- `Secret anthropic-secret` in `agentgateway-system` — the provider key that
  `01-governed-llm-route.yaml` injects
- `EnterpriseAgentgatewayBackend weather-mcp` — the MCP server that
  `05-waf-mcp.yaml` puts behind a governed route

The demo personas (`maria` = US, `pat` = IR) come from
`manifests/infrastructure/keycloak-realm.yaml`.

## Three findings worth knowing before you edit these

Each cost real debugging time on AgentGateway Enterprise v2026.8.2. All three
are also documented inline in the files themselves.

**1. `matchExpressions` entries are OR'ed, not AND'ed.**
A request is allowed if *any* expression matches. Splitting the OFAC check and
the model allowlist into two entries means a sanctioned user with an approved
model gets through. Both conditions are joined with `&&` inside a **single**
expression in `02-ofac-model-allowlist.yaml`.

**2. `llm.*` variables are not populated during traffic authorization.**
`llm.requestModel` is a backend/AI-phase variable. Referencing it from
`traffic.authorization` makes the expression unresolvable, and *every* request
403s — including the ones that should pass. Read the model from
`json(request.body).model` instead.

**3. A WAF policy that fails to compile fails CLOSED (HTTP 500).**
If a route starts 500ing after a WAF change, it is a rule compilation error, not
runtime blocking. Check `kubectl describe wafpolicy <name> -n agentgateway-system`
for `status.conditions[type=Ready]`.

One more, for the access logs: don't give an attribute a name that is both a
scalar and a prefix (`user` and `user.country`). ClickHouse's JSON column cannot
hold both shapes at that path and one silently wins. Everything here lives under
the `identity.` prefix for that reason.

## Querying the output

The access logs land in `platformdb.otel_logs_json`. Use **typed JSON
subcolumns** — an untyped path is a `Dynamic` and ClickHouse refuses to group or
aggregate on it:

```sql
SELECT LogAttributes.identity.user.:String    AS user,
       LogAttributes.identity.country.:String AS country,
       LogAttributes.http.status.:Int64       AS status,
       count() AS requests
FROM platformdb.otel_logs_json
WHERE LogAttributes.route.:String = 'agentgateway-system/governed-llm'
GROUP BY user, country, status
ORDER BY requests DESC
```
