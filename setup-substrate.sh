#!/usr/bin/env bash
#
# Solo Agentic Demo — Agent Substrate Sidetrack Setup
#
# Builds a SEPARATE kind cluster running Agent Substrate
# (github.com/agent-substrate/substrate). This does NOT touch the main k3d
# "ai-demo" cluster — Acts 1–7 of the main demo keep running unchanged.
#
# Why a separate cluster: Substrate needs K8s feature gates that are alpha
# in v1.34 / beta in v1.35 (PodCertificateRequest, ClusterTrustBundle), AND
# kagent OSS v0.9+ which ships an `AgentHarness` CRD that conflicts with
# our cluster's kagent Enterprise install. Substrate's own README says:
#   "VERY early development. It is not ready for production use, and the
#    APIs are almost guaranteed to change."
# Hybrid keeps that experimental track sandboxed.
#
# What this script does:
#   1. Pre-flight: kind, go, kubectl, docker, git.
#   2. Clone the upstream substrate repo (pinned commit) into a working dir.
#   3. Run their `hack/create-kind-cluster.sh` — creates kind cluster
#      "substrate-demo" with k8s v1.36 + the right feature gates + a
#      local docker registry.
#   4. Run their `hack/install-ate-kind.sh --deploy-ate-system` — installs
#      the Substrate control plane (ate-api-server, ate-controller, atelet,
#      atenet-router, dns, rustfs, valkey, pod-certificate-controller).
#   5. Run their `hack/install-ate-kind.sh --deploy-demo-counter` — installs
#      the counter demo (WorkerPool with 5 pods + ActorTemplate).
#   6. `go install ./cmd/kubectl-ate` — the CLI plugin the demo uses.
#
# Usage:
#   ./setup-substrate.sh              # build it
#   ./teardown-substrate.sh           # tear it down (separate script)
#
# Switching contexts:
#   kubectl config use-context kind-substrate-demo   # the substrate cluster
#   kubectl config use-context k3d-ai-demo           # the main demo cluster

set -euo pipefail

###############################################################################
# Config
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-substrate-demo}"
SUBSTRATE_REPO="${SUBSTRATE_REPO:-https://github.com/agent-substrate/substrate}"
# Pin to a known-good commit. Bump deliberately, then re-run + re-verify.
# Substrate's APIs are explicitly unstable, so chasing main risks breakage.
SUBSTRATE_PIN="${SUBSTRATE_PIN:-f5df01bd82620fb1c5c2a1d1884e21533ff6b184}"
WORKDIR="${SUBSTRATE_WORKDIR:-${SCRIPT_DIR}/.substrate-src}"

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
header(){ echo -e "\n${BOLD}═══════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}═══════════════════════════════════════════════════${NC}\n"; }

###############################################################################
# Preflight
###############################################################################
header "Preflight"
for cmd in kind kubectl docker go git; do
  command -v "$cmd" >/dev/null 2>&1 || { err "$cmd is required but not found"; exit 1; }
  ok "$cmd found"
done

if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
  warn "kind cluster '${KIND_CLUSTER_NAME}' already exists."
  warn "If you want a fresh start, run ./teardown-substrate.sh first."
  warn "Proceeding will re-run installers idempotently against the existing cluster."
fi

###############################################################################
# Step 1 — Fetch the substrate repo (pinned)
###############################################################################
header "Step 1: Fetch Agent Substrate (${SUBSTRATE_PIN:0:8})"

if [ -d "${WORKDIR}/.git" ]; then
  info "Updating ${WORKDIR} to pinned commit..."
  (cd "${WORKDIR}" && git fetch --depth=50 origin && git checkout "${SUBSTRATE_PIN}" 2>&1) | sed 's/^/    /' || true
else
  info "Cloning ${SUBSTRATE_REPO} → ${WORKDIR}"
  git clone "${SUBSTRATE_REPO}" "${WORKDIR}" 2>&1 | tail -3 | sed 's/^/    /'
  (cd "${WORKDIR}" && git checkout "${SUBSTRATE_PIN}" 2>&1) | sed 's/^/    /' || true
fi
ok "Substrate repo at ${WORKDIR} (commit $(cd "${WORKDIR}" && git rev-parse --short HEAD))"

###############################################################################
# Step 2 — Create the kind cluster (their script: feature gates + local registry)
#
# Their hack/create-kind-cluster.sh writes a kind-config.yaml that turns on
# featureGates: PodCertificateRequest, ClusterTrustBundle, ClusterTrustBundleProjection.
# These are alpha in K8s 1.34 / beta in 1.35 / off by default in 1.36. Kind's
# featureGates: block at the cluster level applies them to all components.
###############################################################################
header "Step 2: Create kind cluster '${KIND_CLUSTER_NAME}'"

if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
  info "kind cluster already present — skipping create"
else
  ( cd "${WORKDIR}" && KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME}" bash hack/create-kind-cluster.sh ) 2>&1 | tail -8 | sed 's/^/    /'
fi
kubectl --context "kind-${KIND_CLUSTER_NAME}" wait --for=condition=Ready nodes --all --timeout=120s >/dev/null 2>&1
ok "kind cluster ready ($(kubectl --context "kind-${KIND_CLUSTER_NAME}" get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'))"

###############################################################################
# Step 3 — Install the Agent Substrate control plane
###############################################################################
header "Step 3: Install Agent Substrate (--deploy-ate-system)"
info "This builds + pushes ~10 container images to the local registry (3-8 minutes on first run)..."
( cd "${WORKDIR}" && KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME}" bash hack/install-ate-kind.sh --deploy-ate-system ) 2>&1 | tail -15 | sed 's/^/    /'

info "Waiting for ate-system pods to become Ready..."
kubectl --context "kind-${KIND_CLUSTER_NAME}" wait --for=condition=Ready pods --all -n ate-system --timeout=300s 2>/dev/null || \
  warn "Some ate-system pods aren't Ready yet — check 'kubectl get pods -n ate-system'"
ok "Substrate control plane running"

###############################################################################
# Step 4 — Install the counter demo
###############################################################################
header "Step 4: Install Counter Demo (WorkerPool + ActorTemplate)"
( cd "${WORKDIR}" && KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME}" bash hack/install-ate-kind.sh --deploy-demo-counter ) 2>&1 | tail -10 | sed 's/^/    /'

POOL_REPLICAS=$(kubectl --context "kind-${KIND_CLUSTER_NAME}" get workerpool counter -n ate-demo-counter -o jsonpath='{.status.replicas}' 2>/dev/null || echo "?")
ok "Counter demo: WorkerPool 'counter' with ${POOL_REPLICAS} warm pods, ActorTemplate 'counter' (gvisor sandbox)"

###############################################################################
# Step 5 — Install kubectl-ate plugin
###############################################################################
header "Step 5: Install kubectl-ate plugin"
( cd "${WORKDIR}" && go install ./cmd/kubectl-ate ) 2>&1 | tail -3 | sed 's/^/    /'

if ! command -v kubectl-ate >/dev/null 2>&1; then
  # go install puts it in $GOPATH/bin or $HOME/go/bin — point that out if not on PATH
  if [ -x "$HOME/go/bin/kubectl-ate" ]; then
    warn "kubectl-ate installed to \$HOME/go/bin/kubectl-ate but not on PATH."
    warn "Add this to your shell rc:  export PATH=\"\$HOME/go/bin:\$PATH\""
  else
    err "kubectl-ate not found after install"; exit 1
  fi
fi
ok "kubectl-ate installed ($(kubectl ate version 2>/dev/null | head -1 || echo 'version cmd unavailable, plugin works'))"

###############################################################################
# Step 6 — Install kagent OSS + UI with the Substrate integration enabled
#
# This is what lets you DEPLOY AND SEE agents in the kagent UI running on
# Substrate (the OpenClaw AgentHarness flow). It's kagent OSS v0.9.9 — NOT the
# Enterprise build on the main cluster — installed here only.
#
# The substrate flags match kagent's own examples/substrate-openclaw README:
#   controller.substrate.enabled         — turn on the AgentHarness→Substrate path
#   controller.substrate.ateApiEndpoint  — the ate-api-server installed in Step 3
#   substrateWorkerPool.create=true       — kagent provisions a WorkerPool
#                                           (kagent-default) for harnesses to use
#   substrateWorkerPool.replicas=2        — size the pool to 1 + (long-lived
#                                           AgentHarnesses). A long-lived harness
#                                           (openclaw-demo) pins one worker slot
#                                           for its whole life; a 2nd agent (e.g.
#                                           the hello-substrate SandboxAgent) then
#                                           needs a free worker to resume its
#                                           golden actor. With only 1 worker the
#                                           2nd stalls at ResumeGoldenActor with
#                                           "no free workers available" — the
#                                           density rule from the kagent docs.
#   substrateWorkerPool.ateomImage        — the gVisor ateom sandbox image
#
# A ModelConfig (default-model-config) is generated from the Anthropic key in
# the repo's .env (OpenClaw needs an LLM). providers.default=anthropic makes
# that the default the AgentHarness references.
###############################################################################
header "Step 6: Install kagent OSS + UI (Substrate integration)"

# Source the main repo's .env for the Anthropic key (gitignored; same file the
# main setup.sh uses). OpenClaw is a coding agent — it needs a real model.
if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a; . "${SCRIPT_DIR}/.env"; set +a
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  warn "ANTHROPIC_API_KEY not set (no .env?). The OpenClaw harness needs a model."
  warn "Set it in .env, or the default-model-config will be created without a key."
fi

KAGENT_OSS_VERSION="${KAGENT_OSS_VERSION:-0.9.9}"
ATEOM_VERSION="${ATEOM_VERSION:-v0.0.6}"

info "Installing kagent-crds ${KAGENT_OSS_VERSION}..."
helm --kube-context "kind-${KIND_CLUSTER_NAME}" upgrade --install kagent-crds \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds --version "${KAGENT_OSS_VERSION}" \
  --namespace kagent --create-namespace 2>&1 | tail -3 | sed 's/^/    /'

info "Installing kagent controller + UI with Substrate enabled (pulls images, 2-5 min)..."
helm --kube-context "kind-${KIND_CLUSTER_NAME}" upgrade --install kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent --version "${KAGENT_OSS_VERSION}" \
  --namespace kagent \
  --set providers.default=anthropic \
  --set-string providers.anthropic.apiKey="${ANTHROPIC_API_KEY:-}" \
  --set controller.substrate.enabled=true \
  --set controller.substrate.ateApiEndpoint=dns:///api.ate-system.svc:443 \
  --set controller.substrate.ateApiInsecure=true \
  --set substrateWorkerPool.create=true \
  --set substrateWorkerPool.replicas=2 \
  --set substrateWorkerPool.ateomImage="ghcr.io/kagent-dev/substrate/ateom-gvisor:${ATEOM_VERSION}" \
  --set ui.enabled=true \
  --wait --timeout 8m 2>&1 | tail -6 | sed 's/^/    /'

kubectl --context "kind-${KIND_CLUSTER_NAME}" rollout status deploy/kagent-controller -n kagent --timeout=240s >/dev/null 2>&1 || true
kubectl --context "kind-${KIND_CLUSTER_NAME}" rollout status deploy/kagent-ui -n kagent --timeout=180s >/dev/null 2>&1 || true
MC=$(kubectl --context "kind-${KIND_CLUSTER_NAME}" get modelconfig default-model-config -n kagent -o jsonpath='{.spec.model}' 2>/dev/null || echo "?")
ok "kagent OSS + UI running; WorkerPool 'kagent-default' + default-model-config (${MC}) created"

###############################################################################
# Done
###############################################################################
header "Substrate sidetrack ready"
echo -e "${BOLD}Cluster:${NC}    kind-${KIND_CLUSTER_NAME}    (separate from your main k3d 'ai-demo')"
echo -e "${BOLD}Switch:${NC}     kubectl config use-context kind-${KIND_CLUSTER_NAME}"
echo -e "${BOLD}Demo:${NC}       ./substrate-demo.sh"
echo -e "${BOLD}Teardown:${NC}   ./teardown-substrate.sh"
echo ""
echo -e "${BOLD}kagent UI (to see + deploy agents on Substrate):${NC}"
echo "  kubectl --context kind-${KIND_CLUSTER_NAME} port-forward -n kagent svc/kagent-ui 8001:8080"
echo "  open http://localhost:8001"
echo ""
echo -e "${BOLD}Main demo unchanged:${NC}"
echo "  kubectl config use-context k3d-ai-demo"
echo "  ./demo.sh                  # Acts 1-7"
