# Agent Substrate Sidetrack — Runbook

A separate, experimental demo of **Agent Substrate** (the Google-adjacent
open-source project at [agent-substrate/substrate](https://github.com/agent-substrate/substrate)).
Runs on its own `kind` cluster. **Does not touch the main k3d demo cluster** —
Acts 1–7 of `./demo.sh` keep working unchanged.

> Substrate's own README on its maturity:
> *"VERY early development. It is not ready for production use, and the APIs
>  are almost guaranteed to change."*
>
> Treat this whole sidetrack the same way. It's the new hotness — but pin to
> commits when you build on it, and re-validate when you bump.

## 30-second pitch

Kubernetes pods don't know an "agent" from a microservice. They're always-on,
take seconds to boot, and cost the same idle as active. Agents are mostly idle
— so we want lots of them, on few pods, sandboxed from each other.

Agent Substrate is a layer over Kubernetes that does exactly that:

- **WorkerPool**: a fixed-size pool of warm pods (the "workers").
- **ActorTemplate**: a spec ("agent definition") — declared once.
- **Actor**: a running instantiation of a template, multiplexed onto a worker.
  Suspends to durable storage when idle, resumes on the next request, preserves
  RAM + filesystem state via full snapshots.
- **Sandbox** (gVisor): every actor is kernel-isolated from every other actor
  on the same pod.

Upstream's headline demo: **250 stateful actors on 8 pods**. Ours is scaled
down (21 actors on 5 pods), same shape.

## What's running

| Resource | Namespace | What it is |
|---|---|---|
| `kind` cluster `substrate-demo` | n/a | K8s v1.36.1 with feature gates `PodCertificateRequest`, `ClusterTrustBundle`, `ClusterTrustBundleProjection` |
| ate-system | `ate-system` | The Substrate control plane: api-server, controller, atelet, atenet-router, dns, rustfs, valkey (6-node) |
| `workerpools.ate.dev` `counter` | `ate-demo-counter` | 5 warm pods waiting to host actors (raw-primitive demo) |
| `actortemplates.ate.dev` `counter` | `ate-demo-counter` | CLASS=gvisor (every actor sandboxed) |
| **kagent OSS + UI** | `kagent` | kagent v0.9.9 with `controller.substrate.enabled=true` — the layer that lets you **see + deploy agents on Substrate in a UI**. NOT the Enterprise build on the main cluster. |
| `workerpools.ate.dev` `kagent-default` | `kagent` | the pool kagent schedules AgentHarness actors onto |
| `modelconfigs.kagent.dev` `default-model-config` | `kagent` | Anthropic (claude-haiku-4-5), built from your `.env` key — OpenClaw's LLM |
| `agentharnesses.kagent.dev` `openclaw-demo` | `kagent` | the OpenClaw coding agent, `runtime: substrate` (deployed by Act 5) |
| `kubectl-ate` | local binary in `$HOME/go/bin` | CLI plugin to manage raw actors |

## Prerequisites

- Docker, `kind` v0.31+, `kubectl`, `go` 1.22+, `git`, `curl`
- ~5GB disk for the cluster + Substrate's local docker registry
- Port `8000` free (port-forward for the atenet-router)

## Setup

```bash
./setup-substrate.sh
```

What it does (idempotent — safe to re-run):

1. Clones [`agent-substrate/substrate`](https://github.com/agent-substrate/substrate)
   pinned to a known-good commit into `.substrate-src/` (gitignored).
2. Creates a `kind` cluster (`substrate-demo`) with the required K8s feature
   gates + a local docker registry.
3. Installs the Substrate control plane via their `hack/install-ate-kind.sh
   --deploy-ate-system`. *(First run builds ~10 container images via `ko` —
   takes 3–8 minutes. Re-runs are quick.)*
4. Installs the counter demo (WorkerPool with 5 pods + ActorTemplate
   `counter`) via `hack/install-ate-kind.sh --deploy-demo-counter`.
5. Installs the `kubectl-ate` plugin via `go install ./cmd/kubectl-ate`.

After setup:

```bash
export PATH="$HOME/go/bin:$PATH"   # ensure kubectl-ate is on PATH
kubectl config use-context kind-substrate-demo
```

## The demo

```bash
./substrate-demo.sh             # full walkthrough, 4 acts
./substrate-demo.sh --reset     # delete all created actors, keep pool + template
./substrate-demo.sh --act 3     # reset, fast-forward acts 1..2 silently, then play 3 live
```

| Act | What you see | The moment to sell |
|---|---|---|
| **1** Mental model | WorkerPool (5 pods) + ActorTemplate (gvisor) listed via kubectl | One template → many actors. Every actor in its own gVisor sandbox even when sharing a pod. |
| **2** Create + resume | `kubectl ate create actor my-counter-1` → `STATUS_SUSPENDED` (no pod, zero resources). First HTTP request → resumes onto a worker → returns with `preserved memory count: 1` | Cold-start under a second. Pod assigned only when needed. |
| **3** Density | Create 20 more actors, hit each once. Total: 21 actors. Pool still 5 pods. | Multiplexing: actors are scheduled ONTO workers, not given their own pods. 4× oversubscription here; upstream demo shows 30×. |
| **4** Suspend + resume with state | `kubectl ate suspend actor counter-2` — `STATUS_SUSPENDED`, ATEOM POD goes `<none>`. Next request transparently resumes; counter continues from where it was. | Full RAM + FS state preserved across a hibernation cycle, no app-level checkpointing. *"Instant Session Teleport"* — the upstream's headline feature. |
| **5** Deploy a real agent in the kagent UI | `kubectl apply` a kagent **AgentHarness** (`runtime: substrate`, `backend: openclaw`). kagent generates the ActorTemplate + actor on Substrate. Open the **kagent UI** → the harness is there → the **OpenClaw Control UI** loads, proxied through Substrate's atenet-router. | This is the product experience: ONE kagent resource → a real coding agent, gVisor-sandboxed on Substrate, suspend/resume-able, driven from the UI. Acts 1–4 were the plumbing; this is what a user actually deploys. |

### Act 5 — the kagent UI flow in detail

After `setup-substrate.sh` (which installs kagent + UI), Act 5 deploys
[`manifests/substrate/openclaw-agentharness.yaml`](manifests/substrate/openclaw-agentharness.yaml).
To drive it in the browser:

```bash
kubectl --context kind-substrate-demo port-forward -n kagent svc/kagent-ui 8001:8080
open http://localhost:8001          # → openclaw-demo
```

If the OpenClaw Control UI asks you to connect a gateway:

- **Gateway URL:** `http://localhost:8001/api/agentharnesses/kagent/openclaw-demo/gateway/` (trailing slash REQUIRED)
- **Gateway token:** `test-token` (the `spec.substrate.gatewayToken`)

kagent proxies that path to the actor's OpenClaw gateway through Substrate's
atenet-router (Envoy), keyed by the actor `Host` header. The first hit may
cold-resume the actor (a few seconds); after that it's instant.

Each act has a `scene` + a live `kubectl ate` / `curl` call. The actual cluster
is mutated as you go; no smoke and mirrors.

## Actor lifecycle (verified empirically — kubectl-ate help doesn't spell this out)

```
                  create
                    │
                    ▼
              STATUS_SUSPENDED ─────┐
                    │               │
        first req   │               │  delete
                    ▼               │  (only from SUSPENDED)
              STATUS_RESUMING       │
                    │               │
                    ▼               │
              STATUS_RUNNING        ▼
              ┌─────┬─────┐       (gone)
              │     │     │
          pause   suspend  (idle)
              │     │
              ▼     ▼
        STATUS_PAUSED   STATUS_SUSPENDED ← (and back via `resume` → RUNNING)
        (lightweight,      (full snapshot,
         no snapshot)       durable storage,
                            prerequisite for delete)
```

Key gotcha: `kubectl ate delete actor` returns
`FailedPrecondition` unless the actor is `STATUS_SUSPENDED`. From `PAUSED`,
you must `resume` first, then `suspend`, then `delete`. `substrate-demo.sh
--reset` walks this state machine automatically.

## Teardown

```bash
./teardown-substrate.sh
```

Deletes the kind cluster. Leaves the local docker registry container running
*if* you have other kind clusters; removes it if not.

## Where the upstream YAML lives

- Control plane install: [`.substrate-src/manifests/ate-install/`](.substrate-src/manifests/ate-install/)
  - `ate-api-server.yaml`, `ate-controller.yaml`, `atelet.yaml`,
    `atenet-router.yaml`, `valkey.yaml`, `pod-certificate-controller.yaml`,
    `sandboxconfig-gvisor.yaml`, …
- Counter demo: [`.substrate-src/demos/counter/`](.substrate-src/demos/counter/)
- kind cluster config (with feature gates): generated by
  `.substrate-src/hack/create-kind-cluster.sh` into `bin/kind-config.yaml`

`.substrate-src/` is `.gitignore`d — pinned to the
`SUBSTRATE_PIN` commit in `setup-substrate.sh`. To bump, edit `SUBSTRATE_PIN`,
`./teardown-substrate.sh && ./setup-substrate.sh`, re-validate.

## Why this is separate from the main demo

Three things made coexistence too risky:

1. **K8s feature gates** — Substrate needs `PodCertificateRequest` +
   `ClusterTrustBundle` + `ClusterTrustBundleProjection`. Alpha in 1.34, beta
   in 1.35, off-by-default in 1.36. Our main k3d cluster is on k3s v1.33 which
   doesn't ship them.
2. **CRD collision** — Substrate's kagent integration uses OSS kagent v0.9+
   which ships `kagent.dev/v1alpha2` resources. Our main cluster runs kagent
   Enterprise 0.3.17 which owns the same CRD group. Installing OSS on top
   would replace our working Enterprise integration (Solo UI, AgentRegistry,
   OBO flow — Acts 1–7).
3. **Substrate is explicitly pre-stable** — "APIs are almost guaranteed to
   change." Confining experimental churn to a sandboxed cluster keeps the
   demo we ship to customers stable.

## What's NOT in this demo yet

- **Multi-template / agent-secret / claude-code-multiplex** demos — those
  exist under `.substrate-src/demos/` but aren't wired into our script. The
  `claude-code-multiplex` one in particular (many Claude Code sessions
  multiplexed onto a pool) is a natural follow-up to Act 5.
- **Deploying the AgentHarness *from* the UI** (vs `kubectl apply`). Act 5
  applies the manifest then views/uses it in the UI. kagent's UI can also
  create harnesses directly — not scripted here.
- **OpenClaw actually doing coding work** — Act 5 proves the agent deploys,
  runs on Substrate, and its Control UI is reachable. Driving a real coding
  task through it (and showing the session survive a suspend/resume) is the
  obvious next beat.

## References

- Upstream: <https://github.com/agent-substrate/substrate>
- Solo blog: <https://www.solo.io/blog/kagent-3-agent-substrate-a-101-installation-configuration-guide>
- Cloud Native Deep Dive series:
  - <https://www.cloudnativedeepdive.com/agent-substrate-the-agentic-ai-isolation-layer-on-k8s/>
  - <https://www.cloudnativedeepdive.com/kagent-agent-substrate-configuration-setup/>
  - <https://www.cloudnativedeepdive.com/agent-substrate-building-actors-and-workers/>
