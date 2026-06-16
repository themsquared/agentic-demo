# kagent Demo Runbook — Tools, Tool Servers, Promotion

A tight, focused demo of the **kagent runtime**, separate from the full-stack
[DEMO.md](DEMO.md). Three acts, ~10 minutes:

| Act | What you show | The moment to sell |
|-----|---------------|--------------------|
| 1 — Add a tool server | Register a `RemoteMCPServer`; kagent discovers its tools | Tools come from MCP servers you register independently; kagent auto-discovers them, and every call routes through the gateway. |
| 2 — Add tools to an agent | Build a declarative agent, chat, then add a 2nd tool server and grow it live | Agents are a system prompt + a model + tool refs — pure YAML, no code. Capabilities grow by registering a tool server and referencing it. |
| 3 — Promote from AgentRegistry | A packaged (container) agent: catalog `Agent` + `Deployment` → running `kagent.dev/Agent` | The governance-to-runtime story: a coded agent, cataloged in the registry, **promoted onto kagent with one declarative record** — and it still talks only through the gateway. |

```bash
./kagent-demo.sh            # full interactive demo (Enter to advance)
./kagent-demo.sh --act 3    # jump to an act (1-3)
./kagent-demo.sh --reset    # remove just this demo's resources
```

Prereqs: `./setup.sh` has run and `./port-forward.sh` is active. Have
**http://localhost:9090** open (login `demo`/`demo`). Act 3 also needs the
packaged image in-cluster — `setup.sh` Step 11.5 builds + `k3d image import`s it
(needs Docker; if Docker was absent at setup, Acts 1–2 still run).

---

## The two kinds of kagent agent (say this up front)

- **Declarative** (Acts 1–2, `manifests/kagent/agents/`, `manifests/kagent-demo/`):
  a system prompt + a `modelConfig` + tool refs. No image, no code — kagent runs
  it in its shared ADK runtime. This is how `setup.sh` deploys the demo agents.
- **BYO image** (Act 3, `agents-src/weatherwise/`): custom agent code packaged as
  a container. This is what **AgentRegistry promotes** onto the kagent runtime.
  Declarative agents have no image and can't be promoted through AR — promotion
  is the build-and-ship path.

Both reach their LLM and MCP tools **through the AgentGateway**.

---

## Act 1 — Add a tool server

`RemoteMCPServer` registers an MCP endpoint; kagent connects and discovers tools.

```bash
kubectl apply -f manifests/kagent-demo/01-tool-server-weather.yaml
kubectl get remotemcpserver kdemo-weather -n kagent                       # ACCEPTED=True
kubectl get remotemcpserver kdemo-weather -n kagent \
  -o jsonpath='{.status.discoveredTools[*].name}{"\n"}'                   # the discovered tools
```

The `url` is an AgentGateway route (`/mcp/weather`), so every tool call this
server fronts is governed by the gateway.

## Act 2 — Add tools to an agent

A declarative agent's `tools:` block is where you add tools — each entry points
at a tool server + the tool names the agent may call (**explicit, non-empty** —
see the gotcha in `manifests/README.md`).

```bash
kubectl apply -f manifests/kagent-demo/02-helpdesk-weather.yaml           # weather only
# chat → "What's the weather in Tokyo?"  (UI: Agents → helpdesk)

kubectl apply -f manifests/kagent-demo/03-tool-server-github.yaml         # 2nd tool server
kubectl apply -f manifests/kagent-demo/04-helpdesk-add-github.yaml        # re-apply with both
# chat → "Who is the GitHub user solo-io?"  (now it can do both)
```

The script chats via the in-cluster A2A endpoint; in the browser, open
**Agents → helpdesk**.

## Act 3 — Promote an agent from AgentRegistry → kagent

The image was built from `agents-src/weatherwise/` and loaded into the cluster by
`setup.sh`. Promotion is two `arctl` applies (via the in-cluster helper):

```bash
# 1. catalog the agent (carries source.image) — browsable, not yet running
kubectl exec -i deploy/arctl-helper -n agentregistry-system -- arctl-apply \
  < manifests/agentregistry/weatherwise-agent.yaml

# 2. promote: bind the catalog Agent to the kagent runtime
kubectl exec -i deploy/arctl-helper -n agentregistry-system -- arctl-apply \
  < manifests/agentregistry/deployments.yaml

# AgentRegistry materializes a native kagent Agent (type: BYO)
kubectl get agent weatherwise -n kagent                                   # READY=True
# chat → "What's the weather in Paris?"  (UI: Agents → weatherwise)
```

What just happened: a coded agent, packaged as an image, cataloged in
AgentRegistry, **promoted onto kagent with one `Deployment`** — running, on the
mesh, and still routing LLM + tools through the gateway.

---

## Why the `istiod` alias matters (operator note)

Promoted (BYO) agents get an ambient **waypoint**. Solo's istiod is named
`istiod-gloo`, but waypoints fetch their cert from the conventional
`istiod.istio-system.svc:15012`. `setup.sh` applies
`manifests/infrastructure/istiod-alias.yaml` so that name resolves — without it
the promoted agent **runs but is unreachable in-mesh** (UI chat / A2A reset).
Declarative agents have no waypoint, so this only surfaces after Act 3.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Act 3: "Packaged image not found" | Docker was unavailable at `setup.sh`. Build + import manually: `docker build -t solo-demo/weatherwise:latest agents-src/weatherwise && k3d image import solo-demo/weatherwise:latest -c ai-demo` |
| Promoted agent READY but UI chat hangs/resets | Waypoint can't get a cert — confirm `kubectl get svc istiod -n istio-system` exists (apply `manifests/infrastructure/istiod-alias.yaml`), then `kubectl rollout restart deploy -n kagent -l gateway.networking.k8s.io/gateway-name` |
| Agents page crashes after adding a tool | A tool ref lost its non-empty `toolNames` — re-apply the manifest (see `manifests/README.md` gotchas) |
| Clean slate | `./kagent-demo.sh --reset` (removes helpdesk, the kdemo tool servers, and the weatherwise promotion; leaves infra + main-demo agents + the imported image) |
