#!/usr/bin/env bash
#
# Solo Agentic Demo — Full Environment Setup
#
# Creates:
#   - k3d cluster "ai-demo"
#   - Solo Ambient Mesh (Gloo Operator)
#   - Enterprise AgentGateway with STS/elicitations
#   - LLM providers: Anthropic + OpenAI
#   - MCP servers: Website Fetcher, GitHub (remote), Weather + GitHub Profile (composable)
#   - GitHub OAuth elicitation flow via Keycloak
#   - kagent Enterprise (K8s-native agent runtime)
#   - AgentRegistry Enterprise (agent/MCP catalog + deployment orchestration)
#   - Demo agents wired through AgentGateway (LLM + MCP + OBO/elicitation)
#
# Prerequisites:
#   - k3d, kubectl, helm
#   - go (1.24+) — ONLY to generate licenses from the solo-io/licensing repo
#     (Solo employees). Not needed if you provide license strings (see below).
#   - Solo licenses — one of:
#       * SOLO_LICENSE_KEY (a single trial license covering all products), or
#       * AGENTGATEWAY_LICENSE_KEY / SOLO_ISTIO_LICENSE_KEY / KAGENT_LICENSE_KEY, or
#       * the solo-io/licensing repo at ~/licensing (auto-generated), or
#       * paste them when prompted.
#   - Environment variables (or will be prompted):
#       ANTHROPIC_API_KEY, OPENAI_API_KEY
#       GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET  (from a GitHub OAuth App)
#
# Usage:
#   ./setup.sh
#

set -euo pipefail

###############################################################################
# Config
###############################################################################
# All declarative YAML lives in manifests/ — applied via kubectl, not inline heredocs.
# Secrets (API keys, OAuth creds, OBO key) are the ONLY thing created imperatively
# below, since they hold credentials and must not be checked into files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${SCRIPT_DIR}/manifests"

# Load secrets + optional overrides from .env if present (gitignored). Lets you
# set ANTHROPIC_API_KEY / OPENAI_API_KEY / GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET
# (and any var below) once, instead of typing them each run. See .env.example.
if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a; . "${SCRIPT_DIR}/.env"; set +a
fi

# Everything below uses ${VAR:-default} so .env can override any of them.
CLUSTER_NAME="${CLUSTER_NAME:-ai-demo}"
# v2026.8.2 is the newest published AgentGateway Enterprise chart. Checked before
# pinning: 8.2 ships the IDENTICAL CRD set as 8.0 (EnterpriseAgentgatewayBudget
# included), keeps the budgetDimensions defaults, and every field this demo's
# manifests use still validates against its schemas — so the cost-management
# story (Act 8) is intact.
#
# Heads-up for whoever bumps this next: docs.solo.io/agentgateway "latest" has
# been lagging the published charts, so the docs may describe an older release
# than the one you are installing. v2026.8.0 is the previous pin and v2026.7.1
# the last one whose docs matched — either is a clean fallback.
AGW_VERSION="${AGW_VERSION:-v2026.8.2}"
GLOO_OPERATOR_VERSION="${GLOO_OPERATOR_VERSION:-0.5.2}"
ISTIO_VERSION="${ISTIO_VERSION:-1.30.0}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.0}"
KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.0}"
LICENSING_REPO="${LICENSING_REPO:-${HOME}/licensing}"
AGW_NS="${AGW_NS:-agentgateway-system}"
MESH_NS="${MESH_NS:-gloo-mesh}"
ISTIO_NS="${ISTIO_NS:-istio-system}"
KC_NS="${KC_NS:-keycloak}"
KAGENT_ENT_VERSION="${KAGENT_ENT_VERSION:-0.5.5}"
AR_VERSION="${AR_VERSION:-2026.8.0}"
KAGENT_NS="${KAGENT_NS:-kagent}"
AR_NS="${AR_NS:-agentregistry-system}"
KEYCLOAK_ISSUER_INTERNAL="${KEYCLOAK_ISSUER_INTERNAL:-http://keycloak.keycloak.svc.cluster.local:8080/realms/agentgateway}"
# Static OIDC client secrets (set in Keycloak realm import, no need to rotate for a demo)
KAGENT_BACKEND_SECRET="${KAGENT_BACKEND_SECRET:-kagent-backend-secret}"
AR_BACKEND_SECRET="${AR_BACKEND_SECRET:-ar-backend-secret}"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
header(){ echo -e "\n${BOLD}═══════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}═══════════════════════════════════════════════════${NC}\n"; }

wait_for_pods() {
  local ns=$1 timeout=${2:-180}
  info "Waiting for pods in ${ns} to be ready (timeout ${timeout}s)..."
  kubectl wait --for=condition=Ready pods --all -n "$ns" --timeout="${timeout}s" 2>/dev/null || {
    warn "Some pods in ${ns} not ready after ${timeout}s — showing status:"
    kubectl get pods -n "$ns"
  }
}

wait_for_deployment() {
  local ns=$1 name=$2 timeout=${3:-180}
  info "Waiting for deployment ${name} in ${ns}..."
  kubectl rollout status deployment/"$name" -n "$ns" --timeout="${timeout}s" 2>/dev/null || {
    warn "Deployment ${name} not ready after ${timeout}s"
    kubectl get deployment "$name" -n "$ns"
  }
}

###############################################################################
# Preflight checks
###############################################################################
header "Preflight Checks"

for cmd in k3d kubectl helm; do
  command -v "$cmd" >/dev/null 2>&1 || { err "$cmd is required but not found"; exit 1; }
  ok "$cmd found"
done
# go is required ONLY to generate licenses from the solo-io/licensing repo
# (Solo employees). Anyone else provides license strings via .env or the prompt
# in Step 1, and doesn't need go — so it's checked there, not here.

# Prompt for required env vars
prompt_var() {
  local var_name=$1 prompt_text=$2 is_secret=${3:-false}
  if [ -z "${!var_name:-}" ]; then
    if [ "$is_secret" = "true" ]; then
      echo -en "${YELLOW}[INPUT]${NC} ${prompt_text}: "
      read -rs "$var_name"
      echo
    else
      echo -en "${YELLOW}[INPUT]${NC} ${prompt_text}: "
      read -r "$var_name"
    fi
    export "${var_name}"
  fi
  ok "${var_name} is set"
}

prompt_var ANTHROPIC_API_KEY   "Enter your Anthropic API key" true
prompt_var OPENAI_API_KEY      "Enter your OpenAI API key" true
prompt_var GITHUB_CLIENT_ID    "Enter your GitHub OAuth App Client ID"
prompt_var GITHUB_CLIENT_SECRET "Enter your GitHub OAuth App Client Secret" true

###############################################################################
# Step 1 — Solo license keys
#
# Three licenses are needed (AgentGateway, Istio/Mesh, kagent/AgentRegistry).
# Each is resolved from the first available source, in priority order:
#
#   1. PROVIDED   — the matching env var (set directly or in .env):
#                     AGENTGATEWAY_LICENSE_KEY, SOLO_ISTIO_LICENSE_KEY, KAGENT_LICENSE_KEY
#                   ...or SOLO_LICENSE_KEY as a single value that backfills any unset
#                   one (a trial license commonly covers all products).
#   2. GENERATED  — from the solo-io/licensing repo at ${LICENSING_REPO} (Solo
#                   employees only). Requires `go`.
#   3. PROMPTED   — paste the JWT when asked. The fallback for anyone without
#                   the repo (e.g. a customer/prospect emailed trial licenses).
#
# So a non-Solo user just sets the keys in .env (or pastes them) and never needs
# the licensing repo or go.
###############################################################################
header "Step 1: Solo License Keys"

HAVE_LICENSING_REPO=false
[ -d "${LICENSING_REPO}/tools" ] && HAVE_LICENSING_REPO=true

# Single license that covers all products; backfills any per-product var left unset.
SOLO_LICENSE_KEY="${SOLO_LICENSE_KEY:-}"

# genlicense prints a label line ("Encrypted license string:") followed by the
# JWT on the next line, then decoded metadata. Extract just the JWT token (it
# always starts with "eyJ") rather than relying on line position.
gen_license() {  # usage: gen_license <product>  (only called when the repo is present)
  local product=$1 key
  key=$(cd "${LICENSING_REPO}/tools" \
        && go run cmd/genlicense/main.go --enterprise --product "${product}" --days 90 2>/dev/null \
        | grep -oE 'eyJ[A-Za-z0-9._-]+' | head -1)
  if [ -z "${key}" ]; then
    err "Failed to generate a ${product} license (empty result). Try manually:"
    err "  cd ${LICENSING_REPO}/tools && go run cmd/genlicense/main.go --enterprise --product ${product} --days 90"
    exit 1
  fi
  printf '%s' "${key}"
}

# resolve_license <product> <VAR_NAME> <label>
resolve_license() {
  local product=$1 var=$2 label=$3
  # 1a. explicit per-product value (env/.env)
  if [ -n "${!var:-}" ]; then export "${var}"; ok "${label} license: using provided ${var}"; return; fi
  # 1b. single SOLO_LICENSE_KEY backfill
  if [ -n "${SOLO_LICENSE_KEY}" ]; then printf -v "${var}" '%s' "${SOLO_LICENSE_KEY}"; export "${var}"; ok "${label} license: using SOLO_LICENSE_KEY"; return; fi
  # 2. generate from the licensing repo (Solo employees)
  if [ "${HAVE_LICENSING_REPO}" = true ]; then
    command -v go >/dev/null 2>&1 || { err "go is required to generate licenses from ${LICENSING_REPO}. Install go, or set ${var} / SOLO_LICENSE_KEY in .env."; exit 1; }
    local key; key=$(gen_license "${product}"); printf -v "${var}" '%s' "${key}"; export "${var}"
    ok "${label} license generated (90 days)"
    return
  fi
  # 3. prompt (paste the JWT)
  echo ""
  echo -en "${YELLOW}[INPUT]${NC} Paste your ${label} license JWT (starts with eyJ): "
  read -r "${var}"; export "${var}"
  [ -n "${!var:-}" ] || { err "${label} license is required — set ${var} or SOLO_LICENSE_KEY in .env, or paste it when prompted."; exit 1; }
  ok "${label} license set"
}

if [ "${HAVE_LICENSING_REPO}" = false ] \
   && [ -z "${SOLO_LICENSE_KEY}" ] \
   && [ -z "${AGENTGATEWAY_LICENSE_KEY:-}${SOLO_ISTIO_LICENSE_KEY:-}${KAGENT_LICENSE_KEY:-}" ]; then
  warn "No licensing repo at ${LICENSING_REPO} and no license env vars set."
  info "Not a Solo employee? Set SOLO_LICENSE_KEY (or the three per-product keys)"
  info "in .env, or paste each license when prompted below. Trial licenses from"
  info "Solo typically cover all three products."
fi

resolve_license agentgateway AGENTGATEWAY_LICENSE_KEY "AgentGateway"
resolve_license gloo-mesh    SOLO_ISTIO_LICENSE_KEY   "Istio/Mesh"
resolve_license gloo-trial   KAGENT_LICENSE_KEY       "kagent/AgentRegistry"

###############################################################################
# Step 2 — Create k3d cluster
###############################################################################
header "Step 2: Create k3d Cluster '${CLUSTER_NAME}'"

if k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — deleting and recreating"
  k3d cluster delete "${CLUSTER_NAME}"
fi

k3d cluster create "${CLUSTER_NAME}" \
  --servers 1 \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --port "8090:8090@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0" \
  --wait

kubectl cluster-info
ok "Cluster '${CLUSTER_NAME}' is running"

# --- k3d CNI fix for Istio ambient -------------------------------------------
# k3s puts CNI on non-default paths, and the Gloo Operator's ServiceMeshController
# exposes no CNI-dir override. istio-cni assumes the upstream defaults
# (/etc/cni/net.d for config, /opt/cni/bin for the plugin binary), so on k3d TWO
# things must be reconciled on each node — or istio-cni either never activates,
# or (worse) activates without an invocable binary and breaks ALL pod creation:
#
#   1. CONFIG: bind-mount k3s's conf dir (…/k3s/agent/etc/cni/net.d) onto
#      /etc/cni/net.d, so istio-cni finds the base config to chain onto AND writes
#      its chained config where k3s/containerd actually reads it.
#   2. BINARY: symlink the istio-cni plugin into k3s's CNI bin dir
#      (/var/lib/rancher/k3s/data/cni), where containerd looks for plugins. The
#      symlink is created up-front (dangling until istio-cni-node copies the binary
#      to /opt/cni/bin during mesh install) and does NOT shadow k3s's own plugins.
#
# Node-level changes, so the operator can't revert them. (Ephemeral: re-run this
# block if a node container restarts.)
info "Applying k3d CNI fix for Istio ambient (config bind-mount + plugin symlink)..."
for node in $(docker ps --format '{{.Names}}' | grep -E "^k3d-${CLUSTER_NAME}-(server|agent)-[0-9]+$"); do
  docker exec "$node" sh -c '
    set -e   # fail the whole block on ANY error — do not let a later step mask a mount failure
    src=/var/lib/rancher/k3s/agent/etc/cni/net.d
    # wait for k3s/flannel to write its CNI config (races right after create)
    for i in $(seq 1 30); do [ -n "$(ls -A "$src" 2>/dev/null)" ] && break; sleep 2; done
    [ -n "$(ls -A "$src" 2>/dev/null)" ]
    # On a FRESH node /etc/cni/net.d does not exist yet (istio-cni s hostPath
    # creates it later) — mount --bind needs the mountpoint to exist first.
    mkdir -p /etc/cni/net.d
    mountpoint -q /etc/cni/net.d || mount --bind "$src" /etc/cni/net.d
    # make the istio-cni plugin resolvable from k3s/containerd s CNI bin dir
    mkdir -p /var/lib/rancher/k3s/data/cni
    ln -sf /opt/cni/bin/istio-cni /var/lib/rancher/k3s/data/cni/istio-cni
  ' && ok "  CNI config+binary wired on ${node}" || { err "  CNI fix FAILED on ${node} — ambient readiness will break"; exit 1; }
done

###############################################################################
# Step 3 — Install Gateway API CRDs
###############################################################################
header "Step 3: Install Gateway API CRDs"

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
kubectl delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io 2>/dev/null || true
kubectl delete validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io 2>/dev/null || true
ok "Gateway API CRDs installed"

###############################################################################
# Step 4 — Install Solo Ambient Mesh
###############################################################################
header "Step 4: Install Solo Ambient Mesh"

info "Installing Gloo Operator..."
helm upgrade -i gloo-operator \
  oci://us-docker.pkg.dev/solo-public/gloo-operator-helm/gloo-operator \
  --version "${GLOO_OPERATOR_VERSION}" \
  -n "${MESH_NS}" \
  --create-namespace \
  --set "manager.env.SOLO_ISTIO_LICENSE_KEY=${SOLO_ISTIO_LICENSE_KEY}" \
  --wait

ok "Gloo Operator installed"

info "Creating ServiceMeshController for ambient mode..."
kubectl apply -f "${MANIFESTS}/infrastructure/service-mesh-controller.yaml"

info "Waiting for Istio components to come up (this takes ~2-6 minutes)..."
# The ServiceMeshController creates the istio-system namespace and the istiod
# deployment ASYNCHRONOUSLY, so we must wait for the OBJECTS TO EXIST before
# waiting on their conditions. `kubectl wait` against a missing namespace or an
# unmatched label selector does NOT block — it fails immediately, which made the
# old `--timeout=300s ... || true` a no-op and let the script race ahead to the
# istiod-alias apply below, which then died on `namespaces "istio-system" not
# found`. Under `set -e` that aborted the whole install at Step 4.
wait_for_object() {
  local desc=$1 timeout=$2; shift 2
  local deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      warn "${desc} did not appear within ${timeout}s"
      return 1
    fi
    sleep 5
  done
  info "${desc} exists"
}

wait_for_object "namespace ${ISTIO_NS}" 300 kubectl get namespace "${ISTIO_NS}"
wait_for_object "istiod deployment" 300 \
  bash -c "kubectl get deployment -l app=istiod -n '${ISTIO_NS}' -o name | grep -q ."

# Now the conditions are meaningful. Image pulls on a cold k3d node are slow, so
# be generous — this is the long pole of the whole install.
kubectl wait --for=condition=Available deployment -l app=istiod -n "${ISTIO_NS}" --timeout=600s 2>/dev/null || \
  warn "istiod not Available yet — continuing (ambient may lag)"
wait_for_pods "${ISTIO_NS}" 300

# istiod alias — lets ambient WAYPOINTS fetch their mTLS cert. Solo's istiod is
# named 'istiod-gloo', but waypoints use the conventional CA address
# istiod.istio-system.svc:15012. Without this alias that name doesn't resolve,
# waypoints get no cert, and any waypoint-fronted workload is unreachable. Only
# BYO agents (AgentRegistry-promoted) get waypoints, so this is what makes the
# kagent-demo Act 3 promotion reachable in-mesh. See manifests for the full note.
#
# Guarded: this is a nice-to-have for waypoint-fronted BYO agents, NOT a
# prerequisite for the main demo. It used to be an unguarded apply, which meant a
# slow mesh rollout took the ENTIRE install down with it (set -e). Now a missing
# namespace warns and moves on, and the re-run command is printed.
if kubectl get namespace "${ISTIO_NS}" >/dev/null 2>&1; then
  kubectl apply -f "${MANIFESTS}/infrastructure/istiod-alias.yaml"
  ok "Solo Ambient Mesh is running (istiod alias applied)"
else
  warn "${ISTIO_NS} namespace absent — skipped istiod-alias.yaml."
  warn "Ambient waypoints (kagent-demo Act 3) need it. Re-apply once the mesh is up:"
  warn "  kubectl apply -f manifests/infrastructure/istiod-alias.yaml"
fi

###############################################################################
# Step 5 — Deploy Keycloak (OIDC Provider)
#
# Keycloak MUST come before AgentGateway: the AGW token-exchange (STS) 'remote'
# validators need their JWKS URL at boot, or the control plane panics on a nil
# remoteConfig. We deploy Keycloak first so that URL is known, then hand it to
# the single AGW install below.
###############################################################################
header "Step 5: Deploy Keycloak"

kubectl create namespace "${KC_NS}" 2>/dev/null || true

# Realm ConfigMap first, then the Deployment that mounts it (so --import-realm
# sees the realm on first boot — no restart needed).
kubectl apply -f "${MANIFESTS}/infrastructure/keycloak-realm.yaml"
kubectl apply -f "${MANIFESTS}/infrastructure/keycloak.yaml"
wait_for_deployment "${KC_NS}" keycloak 180
ok "Keycloak is running (admin/admin, demo realm: agentgateway)"

###############################################################################
# Step 6 — Install Enterprise AgentGateway
###############################################################################
header "Step 6: Install Enterprise AgentGateway"

KEYCLOAK_JWKS_URI="http://keycloak.${KC_NS}.svc.cluster.local:8080/realms/agentgateway/protocol/openid-connect/certs"

info "Installing AgentGateway CRDs..."
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace \
  --namespace "${AGW_NS}" \
  --version "${AGW_VERSION}"

# DEPRECATION (v2026.7.x, not yet a break): the singular
# tokenExchange.{subjectValidator,actorValidator,apiValidator} keys below are
# deprecated in favour of list-valued {subjectValidators,actorValidators,apiValidators}.
# Per the chart's own values.yaml: "a token is accepted if any validator in its
# list accepts it, and a set singular key is tried first" — so the flags here
# still work on v2026.7.1. They're kept because this is the path that's actually
# been validated end-to-end for the elicitation/OBO showpiece (Act 3 + DEMO.md §5),
# and the plural form routes through different machinery (a mounted ConfigMap
# instead of the inline env JSON). Migrate deliberately, then re-verify OBO:
#   --set "tokenExchange.subjectValidators[0].validatorType=remote" \
#   --set "tokenExchange.subjectValidators[0].remoteConfig.url=${KEYCLOAK_JWKS_URI}" \
#   --set "tokenExchange.actorValidators[0].validatorType=k8s" \
#   --set "tokenExchange.apiValidators[0].validatorType=remote" \
#   --set "tokenExchange.apiValidators[0].remoteConfig.url=${KEYCLOAK_JWKS_URI}" \
# (tokenExchange.issuer / .tokenExpiration are unaffected — they still reach the
# binary through the inline KGW_AGENTGATEWAY_TOKEN_EXCHANGE_CONFIG env JSON.)
info "Installing AgentGateway control plane (token-exchange wired to Keycloak)..."
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "${AGW_NS}" \
  --version "${AGW_VERSION}" \
  --set-string "licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY}" \
  --set "tokenExchange.enabled=true" \
  --set "tokenExchange.issuer=enterprise-agentgateway.${AGW_NS}.svc.cluster.local:7777" \
  --set "tokenExchange.tokenExpiration=24h" \
  --set "tokenExchange.subjectValidator.validatorType=remote" \
  --set "tokenExchange.subjectValidator.remoteConfig.url=${KEYCLOAK_JWKS_URI}" \
  --set "tokenExchange.actorValidator.validatorType=k8s" \
  --set "tokenExchange.apiValidator.validatorType=remote" \
  --set "tokenExchange.apiValidator.remoteConfig.url=${KEYCLOAK_JWKS_URI}" \
  --set "controller.extraEnv.CALLBACK_URL=http://localhost:9090/age/elicitations" \
  --wait

wait_for_pods "${AGW_NS}" 120
ok "AgentGateway control plane is running"

###############################################################################
# Step 7 — Create Gateway + AgentGateway Parameters
###############################################################################
header "Step 7: Create Gateway Resource"

# Model cost catalog FIRST: agentgateway-parameters.yaml references this ConfigMap
# via spec.modelCatalog.sources, so the proxy picks up per-token prices on its
# first reconcile instead of a later one. Without it the gateway counts tokens but
# reports $0 spend everywhere (demo.sh Act 8 / Cost Management UI).
kubectl apply -f "${MANIFESTS}/cost-management/01-model-costs.yaml"
kubectl apply -f "${MANIFESTS}/infrastructure/agentgateway-parameters.yaml"
kubectl apply -f "${MANIFESTS}/infrastructure/agentgateway-gateway.yaml"

info "Waiting for gateway proxy deployment..."
sleep 10
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n "${AGW_NS}" --timeout=120s 2>/dev/null || true
wait_for_pods "${AGW_NS}" 120
ok "Gateway is programmed and proxy is running"

###############################################################################
# Step 8 — LLM Providers: Anthropic + OpenAI
###############################################################################
header "Step 8: Configure LLM Providers"

# --- Anthropic --- (secret created imperatively; backend+route from manifest)
kubectl create secret generic anthropic-secret -n "${AGW_NS}" \
  --from-literal=Authorization="${ANTHROPIC_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${MANIFESTS}/llm-providers/anthropic.yaml"
ok "Anthropic provider configured (Claude Sonnet 4)"

# --- OpenAI ---
kubectl create secret generic openai-secret -n "${AGW_NS}" \
  --from-literal=Authorization="${OPENAI_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${MANIFESTS}/llm-providers/openai.yaml"
ok "OpenAI provider configured (gpt-4o)"

# Retry transient provider errors (Anthropic 529 Overloaded, 429/5xx) at the
# gateway — nothing else in the chain retries, so without this a single
# capacity blip surfaces straight to the user/agent.
info "Applying LLM retry policies..."
kubectl apply -f "${MANIFESTS}/observability/llm-retry-policy.yaml"
ok "LLM retry policies applied (3 attempts, 1s backoff, 429/5xx/529)"

# Cost management: virtual keys (attribution) + budgets (enforcement) on the
# /metered-llm route. The model cost catalog went in at Step 7 — these need
# the Anthropic backend above, so they land here. demo.sh Act 8 re-applies the
# same files live; the Cost Management UI tab reads all of it.
info "Applying cost management (virtual keys + budgets)..."
kubectl apply -f "${MANIFESTS}/cost-management/02-virtual-keys.yaml"
kubectl apply -f "${MANIFESTS}/cost-management/03-budgets.yaml"
ok "Virtual keys (alice/bob) + budgets applied — /metered-llm is metered"

###############################################################################
# Step 9 — MCP Server 1: Website Fetcher (local K8s)
###############################################################################
header "Step 9: Deploy MCP Servers"

info "Deploying Website Fetcher MCP server (local K8s deployment)..."
kubectl apply -f "${MANIFESTS}/mcp-servers/website-fetcher.yaml"
ok "Website Fetcher MCP deployed"

info "Configuring GitHub Remote MCP..."
kubectl apply -f "${MANIFESTS}/mcp-servers/github-remote.yaml"
ok "GitHub Remote MCP configured"

info "Creating Weather composable MCP (Open-Meteo API)..."
kubectl apply -f "${MANIFESTS}/mcp-servers/weather-composable.yaml"
ok "Weather composable MCP deployed (Open-Meteo)"

info "Creating GitHub Profile composable MCP..."
kubectl apply -f "${MANIFESTS}/mcp-servers/github-profile-composable.yaml"
ok "GitHub Profile composable MCP deployed"

info "Creating MCP HTTPRoutes..."
kubectl apply -f "${MANIFESTS}/mcp-servers/routes.yaml"
ok "MCP HTTPRoutes created"

info "Deploying federated 'Virtual MCP' endpoint (server-everything + website-fetcher)..."
kubectl apply -f "${MANIFESTS}/mcp-servers/everything-server.yaml"
kubectl apply -f "${MANIFESTS}/mcp-servers/virtual-mcp.yaml"
ok "Federated MCP available at /mcp/federated"

###############################################################################
# Step 14 — GitHub Elicitation (OAuth flow)
###############################################################################
header "Step 10: Configure GitHub Elicitation"

info "Creating GitHub OAuth secret for elicitations..."
kubectl create secret generic elicitation-oidc -n "${AGW_NS}" \
  --from-literal=type=oauth \
  --from-literal=title="GitHub" \
  --from-literal=instructions="## Authorize GitHub Access\n\nThis demo needs access to your GitHub account to use the GitHub MCP server. Click **Authorize** to grant read-only access." \
  --from-literal=client_id="${GITHUB_CLIENT_ID}" \
  --from-literal=client_secret="${GITHUB_CLIENT_SECRET}" \
  --from-literal=app_id=github \
  --from-literal=authorize_url=https://github.com/login/oauth/authorize \
  --from-literal=access_token_url=https://github.com/login/oauth/access_token \
  --from-literal=scopes="read:user,repo" \
  --from-literal=redirect_uri=http://localhost:9090/age/elicitations \
  --dry-run=client -o yaml | kubectl apply -f -

info "Attaching elicitation policy to GitHub Remote MCP backend..."
kubectl apply -f "${MANIFESTS}/security/github-elicitation-policy.yaml"
# Supplemental RBAC for the STS token store (see the manifest's comment — guards
# against a silent token-persist failure observed with the chart's default RBAC).
kubectl apply -f "${MANIFESTS}/security/agw-sts-token-rbac.yaml"
ok "GitHub elicitation configured"

###############################################################################
# Step 15 — Enroll AGW namespace in ambient mesh
###############################################################################
header "Step 11: Enroll AgentGateway in Ambient Mesh"

kubectl label namespace "${AGW_NS}" istio.io/dataplane-mode=ambient --overwrite
ok "Namespace ${AGW_NS} enrolled in ambient mesh"

###############################################################################
# Step 11.5 — Build the packaged ("promotable") agent image
#
# The kagent demo (kagent-demo.sh, Act 3) promotes a BYO-image agent from
# AgentRegistry onto the kagent runtime. That needs a runnable image present in
# the cluster. We build it once here and load it straight into k3d's containerd
# with `k3d image import` — no registry required. The catalog Agent references
# it as solo-demo/weatherwise:latest with an IfNotPresent pull.
#
# Non-fatal: if docker is unavailable, the main demo and kagent-demo Acts 1-2
# still work; only the Act 3 promotion needs this image.
###############################################################################
header "Step 11.5: Build Packaged Agent Image (for AgentRegistry → kagent promotion)"

WEATHERWISE_IMAGE="solo-demo/weatherwise:latest"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  info "Building ${WEATHERWISE_IMAGE} from agents-src/weatherwise ..."
  if docker build -t "${WEATHERWISE_IMAGE}" "${SCRIPT_DIR}/agents-src/weatherwise" >/tmp/weatherwise-build.log 2>&1; then
    info "Importing ${WEATHERWISE_IMAGE} into k3d cluster '${CLUSTER_NAME}' ..."
    if k3d image import "${WEATHERWISE_IMAGE}" -c "${CLUSTER_NAME}" >/dev/null 2>&1; then
      ok "Packaged agent image built and imported (kagent-demo Act 3 ready)"
    else
      warn "k3d image import failed — kagent-demo Act 3 (promotion) will not run until the image is in-cluster"
    fi
  else
    warn "docker build failed (see /tmp/weatherwise-build.log) — skipping; kagent-demo Acts 1-2 still work"
  fi
else
  warn "docker not available — skipping packaged-agent image build; kagent-demo Act 3 (promotion) will be unavailable"
fi

###############################################################################
# Step 16 — Generate OBO RSA key pair for kagent
###############################################################################
header "Step 12: Generate OBO RSA Key Pair"

info "Generating RSA key pair for kagent On-Behalf-Of token signing..."
openssl genrsa -out /tmp/kagent-obo-key.pem 2048 2>/dev/null
kubectl create namespace "${KAGENT_NS}" 2>/dev/null || true
kubectl create secret generic jwt \
  -n "${KAGENT_NS}" \
  --from-file=jwt=/tmp/kagent-obo-key.pem \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/kagent-obo-key.pem
ok "OBO RSA key stored as secret 'jwt' in ${KAGENT_NS}"

###############################################################################
# Step 17 — Install kagent Enterprise
###############################################################################
header "Step 13: Install kagent Enterprise"

# `products` in the management chart is only {agentgateway, kagent, mesh} — there
# is no products.agentregistry toggle (there never was; the old --set here was a
# silent no-op). The AgentRegistry UI comes from the separate
# agentregistry-enterprise chart installed in Step 14.
#
# products.agentgateway.features.cost-management turns on the Cost Management
# section of the UI (spend dashboard, model cost catalog, budgets, dimensions,
# virtual API keys). It ships OFF by default because the ClickHouse reads behind
# the spend charts aren't optimized yet — fine at demo scale, opt-in for prod.
# cost-management-writes=true lets the UI create budgets/dimensions/virtual keys;
# set it false for a read-only FinOps view.
info "Installing kagent management plane..."
helm upgrade -i kagent-mgmt \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
  -n "${KAGENT_NS}" --create-namespace \
  --version "${KAGENT_ENT_VERSION}" \
  --set cluster=mgmt-cluster \
  --set products.kagent.enabled=true \
  --set products.agentgateway.enabled=true \
  --set "products.agentgateway.namespace=${AGW_NS}" \
  --set 'products.agentgateway.features.cost-management=true' \
  --set 'products.agentgateway.features.cost-management-writes=true' \
  --set-string "licensing.licenseKey=${KAGENT_LICENSE_KEY}" \
  --set-string "oidc.issuer=${KEYCLOAK_ISSUER_INTERNAL}" \
  --set-string "ui.backend.oidc.clientId=kagent-backend" \
  --set-string "ui.backend.oidc.secret=${KAGENT_BACKEND_SECRET}" \
  --set-string "ui.frontend.oidc.clientId=kagent-ui"

info "Installing kagent CRDs..."
helm upgrade --install kagent-crds \
  oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds \
  -n "${KAGENT_NS}" \
  --version "${KAGENT_ENT_VERSION}"

# Chart rename in kagent Enterprise 0.5.x: the built-in agents moved from
# `agents.<name>.enabled` to top-level subchart conditions `<name>.enabled`
# (Chart.yaml: `condition: k8s-agent.enabled`). The old key is not an error —
# helm accepts unknown --set values silently, so the symptom was just a missing
# k8s-agent. Verified against kagent-enterprise 0.5.4's Chart.yaml.
info "Installing kagent controller..."
helm upgrade -i kagent \
  oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise \
  -n "${KAGENT_NS}" \
  --version "${KAGENT_ENT_VERSION}" \
  --set-string "licensing.licenseKey=${KAGENT_LICENSE_KEY}" \
  --set k8s-agent.enabled=true \
  --set kagent-tools.enabled=true \
  --set kmcp.licensing.createSecret=false \
  --set-string "oidc.issuer=${KEYCLOAK_ISSUER_INTERNAL}" \
  --set oidc.clientId=kagent-backend \
  --set-string "oidc.secret=${KAGENT_BACKEND_SECRET}" \
  --set otel.tracing.enabled=true \
  --set "otel.tracing.exporter.otlp.endpoint=solo-enterprise-telemetry-collector.${KAGENT_NS}.svc.cluster.local:4317" \
  --set otel.tracing.exporter.otlp.insecure=true

# The built-in k8s-agent uses kagent's 'default-model-config' (OpenAI), which
# references a secret named 'kagent-openai' with key OPENAI_API_KEY. Create it so
# that agent starts instead of stalling on CreateContainerConfigError.
kubectl create secret generic kagent-openai -n "${KAGENT_NS}" \
  --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

# OBO is an AgentGateway concern, NOT kagent's. By default the kagent controller
# mints its OWN OBO JWT (issuer "kagent.<ns>"), which AGW's STS subjectValidator
# (Keycloak) rejects → chat-as-the-user OBO fails. SKIP_OBO=true makes the
# controller pass the user's RAW Keycloak token straight through to the agent;
# the agent forwards it (KAGENT_PROPAGATE_TOKEN, set per-agent), and AGW's STS
# performs the real token exchange. This is what makes github-assistant work.
info "Setting kagent SKIP_OBO=true (defer OBO to AgentGateway STS)..."
kubectl patch cm kagent-enterprise-config -n "${KAGENT_NS}" --type merge \
  -p '{"data":{"SKIP_OBO":"true"}}'
kubectl rollout restart deploy/kagent-controller -n "${KAGENT_NS}" 2>/dev/null || true

wait_for_pods "${KAGENT_NS}" 300
ok "kagent Enterprise is running (OBO deferred to AgentGateway)"

# Enable AgentGateway tracing now that the telemetry collector (in the kagent ns)
# exists. Every LLM + MCP call through the gateway becomes a trace in the UI.
info "Enabling AgentGateway tracing → Solo Enterprise UI..."
kubectl apply -f "${MANIFESTS}/observability/agentgateway-tracing.yaml"
ok "AgentGateway tracing policy applied"

###############################################################################
# Step 18 — Install AgentRegistry Enterprise
###############################################################################
header "Step 14: Install AgentRegistry Enterprise"

info "Installing AgentRegistry..."
helm upgrade --install agentregistry \
  oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/helm/agentregistry-enterprise \
  --version "${AR_VERSION}" \
  --namespace "${AR_NS}" \
  --create-namespace \
  --set "oidc.issuer=${KEYCLOAK_ISSUER_INTERNAL}" \
  --set oidc.clientId=ar-backend \
  --set "oidc.clientSecret=${AR_BACKEND_SECRET}" \
  --set oidc.publicClientId=ar-ui \
  --set oidc.roleClaim=Groups \
  --set oidc.superuserRole=admins

wait_for_pods "${AR_NS}" 300
ok "AgentRegistry Enterprise is running"

###############################################################################
# Step 19 — Enroll kagent + AR namespaces in ambient mesh
###############################################################################
header "Step 15: Enroll kagent & AgentRegistry in Ambient Mesh"

kubectl label namespace "${KAGENT_NS}" istio.io/dataplane-mode=ambient --overwrite
kubectl label namespace "${AR_NS}" istio.io/dataplane-mode=ambient --overwrite
ok "Namespaces ${KAGENT_NS} and ${AR_NS} enrolled in ambient mesh"

###############################################################################
# Step 20 — ModelConfigs (kagent → AgentGateway → LLM providers)
###############################################################################
header "Step 16: Create ModelConfigs"

info "Creating LLM API key secrets in kagent namespace..."
kubectl create secret generic anthropic-api-key -n "${KAGENT_NS}" \
  --from-literal=key="${ANTHROPIC_API_KEY}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic openai-api-key -n "${KAGENT_NS}" \
  --from-literal=key="${OPENAI_API_KEY}" --dry-run=client -o yaml | kubectl apply -f -

info "Creating ModelConfigs (direct + via-AgentGateway)..."
kubectl apply -f "${MANIFESTS}/kagent/modelconfigs.yaml"
ok "ModelConfigs created (anthropic-via-agw, openai-via-agw, anthropic-direct, openai-direct)"

###############################################################################
# Step 21 — RemoteMCPServers (kagent → AgentGateway → MCP backends)
###############################################################################
header "Step 17: Create RemoteMCPServers (kagent → AGW)"

kubectl apply -f "${MANIFESTS}/kagent/remote-mcp-servers.yaml"
ok "RemoteMCPServers created (all routed through AgentGateway)"

###############################################################################
# Step 22 — Demo Agents
###############################################################################
header "Step 18: Deploy Demo Agents"

info "Creating demo agents in kagent namespace..."
kubectl apply -f "${MANIFESTS}/kagent/agents/"
ok "Demo agents created: weather-assistant, research-agent, github-assistant, orchestrator-agent"
info "(k8s-agent was enabled via the kagent helm chart)"

###############################################################################
# Step 19 — Register in AgentRegistry (in-cluster arctl helper)
###############################################################################
header "Step 19: Register in AgentRegistry"

# AgentRegistry catalog objects (Runtime, MCPServer, Agent, AccessPolicy under
# ar.dev/v1alpha1) are NOT Kubernetes CRDs — they're managed through the registry
# API via the 'arctl' CLI, which needs an OIDC token whose issuer matches the
# in-cluster Keycloak. We run arctl IN-CLUSTER via a helper pod (see
# manifests/agentregistry/arctl-helper.yaml) so the issuer resolves and matches.
# Non-fatal: the rest of the stack works even if this step has trouble.
# AR 2026.7.x requires config.auth.oidc on Kagent runtimes (see the long note in
# manifests/agentregistry/runtime.yaml). AR reads the client secret from a Secret
# in its OWN namespace, so create it before registering the catalog — otherwise
# Runtime/kagent is rejected and Act 5 has nowhere to deploy agents.
info "Creating AgentRegistry→kagent OIDC secret (runtime auth)..."
kubectl create secret generic kagent-oidc -n "${AR_NS}" \
  --from-literal=clientSecret="${AR_BACKEND_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Deploying in-cluster arctl helper..."
kubectl apply -f "${MANIFESTS}/agentregistry/arctl-helper.yaml"

if kubectl rollout status deploy/arctl-helper -n "${AR_NS}" --timeout=180s 2>/dev/null; then
  info "Registering catalog via arctl (runtime, MCP servers, agents, policies)..."
  ar_ok=true
  for f in runtime mcp-servers mcp-gateway agents access-policies; do
    if kubectl exec -i deploy/arctl-helper -n "${AR_NS}" -- arctl-apply \
         < "${MANIFESTS}/agentregistry/${f}.yaml" 2>&1 | sed 's/^/   /'; then :; else
      warn "  ${f}.yaml apply reported an error"; ar_ok=false
    fi
  done
  $ar_ok && ok "AgentRegistry catalog registered" \
         || warn "AgentRegistry catalog partially registered — check: kubectl logs deploy/arctl-helper -n ${AR_NS}"
else
  warn "arctl-helper not ready in time — AR catalog not populated."
  warn "Re-run later: kubectl exec -i deploy/arctl-helper -n ${AR_NS} -- arctl-apply < manifests/agentregistry/<file>.yaml"
fi

###############################################################################
# Final Status
###############################################################################
header "Setup Complete!"

echo -e "${GREEN}Cluster:${NC}         ${CLUSTER_NAME}"
echo -e "${GREEN}Ambient Mesh:${NC}    Istio ${ISTIO_VERSION} (ambient mode)"
echo -e "${GREEN}AgentGateway:${NC}    Enterprise ${AGW_VERSION}"
echo -e "${GREEN}kagent:${NC}          Enterprise ${KAGENT_ENT_VERSION}"
echo -e "${GREEN}AgentRegistry:${NC}   Enterprise ${AR_VERSION}"
echo -e "${GREEN}Keycloak:${NC}        http://localhost:8080 (admin/admin)"
echo ""
echo -e "${BOLD}LLM Providers (via AgentGateway):${NC}"
echo "  • Anthropic (Claude Sonnet 4) → /anthropic"
echo "  • OpenAI (gpt-4o)             → /openai"
echo "  • Metered (OpenAI)            → /metered-llm  (virtual key required)"
echo ""
echo -e "${BOLD}Cost Management:${NC}"
echo "  • Model cost catalog     — per-token USD rates on the Gateway"
echo "  • Virtual keys           — sk-alice-demo (platform-eng) / sk-bob-demo (data-science)"
echo "  • Budgets                — 100 tok/day per key (Block) + team/model USD caps (Audit)"
echo "  • UI                     — Cost Management tab at http://localhost:9090/age/"
echo ""
echo -e "${BOLD}MCP Servers (via AgentGateway):${NC}"
echo "  • Website Fetcher (local)          → /mcp/website"
echo "  • GitHub Remote (with elicitation)  → /mcp/github-remote"
echo "  • Weather (composable, Open-Meteo)  → /mcp/weather"
echo "  • GitHub Profile (composable)       → /mcp/github-profile"
echo ""
echo -e "${BOLD}kagent ModelConfigs:${NC}"
echo "  • anthropic-via-agw    — Claude Sonnet 4 routed through AgentGateway"
echo "  • openai-via-agw       — GPT-4o routed through AgentGateway"
echo "  • anthropic-direct     — Claude Sonnet 4 direct (bypass gateway)"
echo "  • openai-direct        — GPT-4o direct (bypass gateway)"
echo ""
echo -e "${BOLD}Demo Agents (kagent):${NC}"
echo "  • k8s-agent            — Kubernetes expert (built-in, k8s tools)"
echo "  • weather-assistant    — Weather lookups (Anthropic + weather MCP via AGW)"
echo "  • research-agent       — Web/GitHub research (Anthropic + 2 MCPs via AGW)"
echo "  • github-assistant     — Authenticated GitHub ops (OBO/elicitation demo)"
echo "  • orchestrator-agent   — Multi-model A2A orchestrator (OpenAI → specialist agents)"
echo ""
echo -e "${BOLD}Key Integration Points (for demo narrative):${NC}"
echo "  1. LLM Gateway:    kagent → AgentGateway → Anthropic/OpenAI"
echo "  2. MCP Gateway:    kagent → AgentGateway → MCP servers (composable, remote, local)"
echo "  3. OBO/Elicitation: github-assistant → AGW → STS token exchange → GitHub OAuth consent"
echo "  4. A2A Protocol:   orchestrator-agent delegates to specialist agents"
echo "  5. Agent Catalog:  AgentRegistry catalogs agents + MCP servers with RBAC"
echo "  6. Ambient Mesh:   All traffic is mTLS-encrypted (ztunnel)"
echo "  7. Cost Controls:  virtual key → attribution → priced spend → budget → 429"
echo ""
echo -e "${BOLD}All Pods:${NC}"
for ns in "${AGW_NS}" "${ISTIO_NS}" "${KAGENT_NS}" "${AR_NS}"; do
  echo -e "\n${CYAN}--- ${ns} ---${NC}"
  kubectl get pods -n "$ns" --no-headers 2>/dev/null || echo "  (no pods)"
done

###############################################################################
# Step 20 — Start port-forwards for all UIs
###############################################################################
header "Step 20: Expose UIs"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -x "${SCRIPT_DIR}/port-forward.sh" ]; then
  "${SCRIPT_DIR}/port-forward.sh"
else
  warn "port-forward.sh not found — run it manually to expose UIs"
fi

echo ""
echo -e "${GREEN}${BOLD}Full agentic stack is ready.${NC}"
echo ""
echo -e "  ${BOLD}Solo Enterprise UI${NC}   http://localhost:9090  (demo/demo)"
echo -e "  ${BOLD}Keycloak${NC}             http://localhost:8080  (admin/admin; OIDC issuer)"
echo -e "  ${BOLD}AgentGateway Proxy${NC}   http://localhost:8081"
echo -e "  ${BOLD}AgentRegistry API${NC}    http://localhost:12121"
echo ""
echo -e "${BOLD}${YELLOW}ONE-TIME host entry for browser SSO${NC} (so the in-cluster OIDC issuer resolves):"
echo -e "  ${YELLOW}echo \"127.0.0.1 keycloak.keycloak.svc.cluster.local\" | sudo tee -a /etc/hosts${NC}"
echo ""
echo -e "${BOLD}Quick smoke tests:${NC}"
echo ""
echo '  # Anthropic via AGW'
echo '  curl -s localhost:8081/anthropic/v1/messages \'
echo '    -H "content-type: application/json" \'
echo '    -H "anthropic-version: 2023-06-01" \'
echo "    -d '{\"model\":\"claude-sonnet-4-6\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"Say hello!\"}]}' | jq"
echo ""
echo '  # Metered LLM route — virtual key required, spend attributed to alice'
echo '  curl -s localhost:8081/metered-llm/v1/chat/completions \'
echo '    -H "content-type: application/json" \'
echo '    -H "Authorization: Bearer sk-alice-demo" \'
echo "    -d '{\"model\":\"gpt-4o\",\"max_tokens\":20,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' | jq"
echo ""
echo '  # Is pricing landing? (Missing/Unpriced/NoCatalog ⇒ spend undercounts)'
echo '  kubectl port-forward deploy/agentgateway-proxy -n agentgateway-system 15020:15020 &'
echo '  curl -s localhost:15020/metrics | grep agentgateway_cost_catalog_lookups_total'
echo ""
echo '  # Weather MCP via Inspector'
echo '  npx @modelcontextprotocol/inspector@0.21.2'
echo '  # → Transport: Streamable HTTP, URL: http://localhost:8081/mcp/weather'
echo ""
echo -e "  ${YELLOW}If port-forwards die: ./port-forward.sh${NC}"
echo -e "  ${YELLOW}To tear down:         ./teardown.sh${NC}"
