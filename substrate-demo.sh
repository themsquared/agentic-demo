#!/usr/bin/env bash
#
# Agent Substrate Sidetrack Demo
#
# Standalone walkthrough of Agent Substrate (github.com/agent-substrate/substrate)
# on a SEPARATE kind cluster. Does not touch the main k3d cluster.
#
# Prerequisite: ./setup-substrate.sh has been run.
#
# What gets shown (all proven live before this was committed):
#   Act 1 — The mental model: Actors, Workers, WorkerPool, ActorTemplate
#   Act 2 — Create an actor → STATUS_SUSPENDED → request → STATUS_RUNNING → state
#   Act 3 — Density: 20 actors share the 5-pod WorkerPool (the "agent juggling" story)
#   Act 4 — Pause/resume: state preserved across hibernation
#
# Usage:
#   ./substrate-demo.sh           # full walkthrough
#   ./substrate-demo.sh --reset   # delete demo actors but keep the pool
#   ./substrate-demo.sh --act N   # reset, then fast-forward acts 1..N-1 silently
#                                 # and play act N live (mirrors demo.sh semantics)

set -euo pipefail

CLUSTER_NAME="${SUBSTRATE_CLUSTER_NAME:-substrate-demo}"
KCTX="kind-${CLUSTER_NAME}"
ATE_NS="ate-system"
DEMO_NS="ate-demo-counter"
ROUTER_LOCAL_PORT="${SUBSTRATE_ROUTER_PORT:-8000}"
ACTOR_HOST_SUFFIX=".actors.resources.substrate.ate.dev"

# Put $HOME/go/bin on PATH so kubectl-ate is found whether or not the user added it.
export PATH="$HOME/go/bin:$PATH"

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RED='\033[0;31m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'
NC='\033[0m'; BG_BLUE='\033[44m'

STEP_NUM=0
SILENT=false
PF_PID=""

pause() {
  [ "$SILENT" = "true" ] && return 0
  echo ""; echo -en "  ${DIM}[ Press Enter to continue ]${NC}"; read -r; echo ""
}
act() {
  local num=$1; shift; STEP_NUM=0
  if [ "$SILENT" = "true" ]; then
    echo -e "${DIM}▶ fast-forwarding Act ${num} — ${*}...${NC}"; return 0
  fi
  clear 2>/dev/null || true; echo ""
  echo -e "${BG_BLUE}${WHITE}                                                                    ${NC}"
  echo -e "${BG_BLUE}${WHITE}   ACT ${num}: $*                                                   ${NC}"
  echo -e "${BG_BLUE}${WHITE}                                                                    ${NC}"
  echo ""; pause
}
scene() {
  STEP_NUM=$((STEP_NUM+1)); [ "$SILENT" = "true" ] && return 0
  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}  ${STEP_NUM}. $*${NC}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo ""
}
narrate()  { [ "$SILENT" = "true" ] && return 0; echo -e "  ${DIM}$*${NC}"; }
callout()  { [ "$SILENT" = "true" ] && return 0; echo -e "  ${YELLOW}▸ $*${NC}"; }
check_ok() { echo -e "  ${GREEN}✓ $*${NC}"; }
check_fail() { echo -e "  ${RED}✗ $*${NC}"; }
run_cmd()  { echo -e "  ${YELLOW}\$ $*${NC}"; eval "$@" 2>&1 | sed 's/^/    /'; }

# Curl an actor through the router port-forward, return just the response body.
hit_actor() {
  local id=$1
  curl -s --max-time 8 -X POST -H "Host: ${id}${ACTOR_HOST_SUFFIX}" "http://localhost:${ROUTER_LOCAL_PORT}/"
}

start_pf() {
  # Kill any stale forwards on our port
  lsof -ti :"${ROUTER_LOCAL_PORT}" 2>/dev/null | xargs -r kill 2>/dev/null || true
  kubectl --context "${KCTX}" port-forward -n "${ATE_NS}" svc/atenet-router \
    "${ROUTER_LOCAL_PORT}:80" >/tmp/substrate-pf.log 2>&1 &
  PF_PID=$!
  # Wait until the port answers
  for _ in $(seq 1 20); do
    if curl -s --max-time 1 -o /dev/null "http://localhost:${ROUTER_LOCAL_PORT}/" 2>/dev/null; then return 0; fi
    sleep 0.5
  done
  return 1
}
stop_pf() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap stop_pf EXIT

###############################################################################
# Pre-flight + reset
###############################################################################
preflight() {
  if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    check_fail "kind cluster '${CLUSTER_NAME}' not found — run ./setup-substrate.sh first"; exit 1
  fi
  if ! kubectl --context "${KCTX}" get crd workerpools.ate.dev >/dev/null 2>&1; then
    check_fail "Substrate CRDs not installed — re-run ./setup-substrate.sh"; exit 1
  fi
  if ! kubectl --context "${KCTX}" get workerpool counter -n "${DEMO_NS}" >/dev/null 2>&1; then
    check_fail "Counter demo not installed — re-run ./setup-substrate.sh"; exit 1
  fi
  if ! command -v kubectl-ate >/dev/null 2>&1; then
    check_fail "kubectl-ate not on PATH — \$HOME/go/bin needs to be there. Re-run ./setup-substrate.sh"; exit 1
  fi
  check_ok "Substrate cluster + counter demo + kubectl-ate present"
}

# Delete all demo actors (NOT the WorkerPool or ActorTemplate — those are infra).
# Notes on kubectl-ate:
#   - `kubectl ate get actors` lists all actors across namespaces by default.
#     There is NO --all-namespaces or -n flag (the namespace lives in the
#     output's first column, derived from the actor's template ref).
#   - Actor ID is column 3 of the table.
#   - `kubectl ate delete actor <id>` is namespace-agnostic — pass the ID alone.
reset_actors() {
  echo -e "${YELLOW}Clearing previously-created actors...${NC}"
  kubectl config use-context "${KCTX}" >/dev/null
  # Substrate requires actors to be in STATUS_SUSPENDED before deletion.
  # Pause is a lighter-weight state (STATUS_PAUSED) that does NOT satisfy
  # delete's precondition. Use `kubectl ate suspend actor <id>` to hibernate
  # the actor with a full state snapshot, then delete.
  local IDS n=0
  IDS=$(kubectl ate get actors 2>/dev/null | awk 'NR>1 && NF>=3 {print $3}')
  if [ -z "$IDS" ]; then
    echo "  (no existing actors)"; return
  fi
  n=$(echo "$IDS" | wc -l | xargs)
  echo "  found $n actor(s); pause+delete loop (up to 30s)..."
  # State machine (verified empirically): can only delete from SUSPENDED.
  #   RUNNING --suspend--> SUSPENDED --delete--> gone
  #   PAUSED  --resume--> RUNNING ...  (can't suspend directly from PAUSED)
  for _ in $(seq 1 15); do
    # 1. PAUSED actors → resume them (puts them into RUNNING so we can suspend).
    kubectl ate get actors 2>/dev/null | awk 'NR>1 && $4 ~ /PAUSED/ {print $3}' | while IFS= read -r id; do
      [ -n "$id" ] && kubectl ate resume actor "$id" >/dev/null 2>&1 || true
    done
    # 2. RUNNING actors → suspend them.
    kubectl ate get actors 2>/dev/null | awk 'NR>1 && $4 ~ /RUNNING/ {print $3}' | while IFS= read -r id; do
      [ -n "$id" ] && kubectl ate suspend actor "$id" >/dev/null 2>&1 || true
    done
    # 3. SUSPENDED actors → delete.
    kubectl ate get actors 2>/dev/null | awk 'NR>1 && $4 ~ /SUSPENDED/ {print $3}' | while IFS= read -r id; do
      [ -n "$id" ] && kubectl ate delete actor "$id" >/dev/null 2>&1 || true
    done
    sleep 2
    REMAIN=$(kubectl ate get actors 2>/dev/null | awk 'NR>1' | wc -l | xargs)
    [ "$REMAIN" = "0" ] && { echo "  ✓ all actors removed"; return; }
  done
  REMAIN=$(kubectl ate get actors 2>/dev/null | awk 'NR>1' | wc -l | xargs)
  echo "  (warning: ${REMAIN} actor(s) still present — demo will pause+delete on create)"
}

# Pause + delete + create. Substrate requires the predecessor (if any) to be
# SUSPENDED before delete. Then create runs cleanly.
create_actor_fresh() {
  local id=$1 template=$2
  if kubectl ate get actor "$id" >/dev/null 2>&1; then
    # Walk the state machine: PAUSED→RUNNING→SUSPENDED→deleted
    for _ in $(seq 1 6); do
      STATUS=$(kubectl ate get actor "$id" 2>/dev/null | awk 'NR>1 {print $4}')
      case "$STATUS" in
        STATUS_PAUSED)    kubectl ate resume  actor "$id" >/dev/null 2>&1 || true ;;
        STATUS_RUNNING)   kubectl ate suspend actor "$id" >/dev/null 2>&1 || true ;;
        STATUS_SUSPENDED) kubectl ate delete  actor "$id" >/dev/null 2>&1 && break ;;
        "")               break ;;  # gone
      esac
      sleep 1
    done
  fi
  kubectl ate create actor "$id" --template "${template}"
}

###############################################################################
# Args
###############################################################################
START_ACT=1
END_ACT=4
for arg in "$@"; do
  case "$arg" in
    --reset) reset_actors; exit 0 ;;
    --act)   shift; START_ACT=${1:-1}; END_ACT=$START_ACT ;;
    [1-4])   START_ACT=$arg; END_ACT=$arg ;;
  esac
done
silent_for() {
  if [ "$1" -lt "$START_ACT" ]; then SILENT=true; else SILENT=false; fi
}

###############################################################################
# Run
###############################################################################
clear 2>/dev/null || true
kubectl config use-context "${KCTX}" >/dev/null
echo -e "${BG_BLUE}${WHITE}                                                                ${NC}"
echo -e "${BG_BLUE}${WHITE}   Agent Substrate — Sidetrack Demo                             ${NC}"
echo -e "${BG_BLUE}${WHITE}   (separate kind cluster — does not touch the main demo)       ${NC}"
echo -e "${BG_BLUE}${WHITE}                                                                ${NC}"
echo ""
preflight
echo ""
narrate "Substrate is an experimental ('VERY early development' per upstream) layer"
narrate "that multiplexes a large set of 'actors' (agent-like workloads) onto a"
narrate "small pool of 'workers' (k8s pods). The pitch: 250 actors on 8 pods."
pause

reset_actors
start_pf || { check_fail "couldn't start port-forward to atenet-router"; exit 1; }
check_ok "router port-forward live on http://localhost:${ROUTER_LOCAL_PORT}"

# ── ACT 1 ─────────────────────────────────────────────────────────────────────
if [ "$END_ACT" -ge 1 ]; then
silent_for 1
act 1 "The Mental Model — Actors, Workers, and the Pool"
scene "WorkerPool: a fixed-size pool of warm pods"
narrate "The pool is sized once; pods stay running. Actors get scheduled ONTO them."
run_cmd "kubectl --context ${KCTX} get workerpool counter -n ${DEMO_NS}"
run_cmd "kubectl --context ${KCTX} get pods -n ${DEMO_NS} -l ate.dev/worker-pool=counter"
callout "5 pods. They are the workers. Nothing is 'agent-specific' about them yet."
pause

scene "ActorTemplate: the spec an actor instantiates from"
narrate "Like a Deployment template, but for actors. CLASS shows the sandbox:"
narrate "  gvisor = each actor is sandboxed in its own gVisor instance,"
narrate "  so even sharing a pod the actors are isolated from each other."
run_cmd "kubectl --context ${KCTX} get actortemplate counter -n ${DEMO_NS}"
callout "ONE template, MANY actors — the multiplexing is template→pool."
pause
fi # end Act 1

# ── ACT 2 ─────────────────────────────────────────────────────────────────────
if [ "$END_ACT" -ge 2 ]; then
silent_for 2
act 2 "Create an Actor — SUSPENDED → first request → RUNNING → state"
scene "Create the actor — no pod assigned, zero cost"
narrate "Substrate creates the actor record but does NOT schedule it. STATUS_SUSPENDED."
echo -e "  ${YELLOW}\$ kubectl ate create actor my-counter-1 --template ${DEMO_NS}/counter${NC}"
create_actor_fresh my-counter-1 "${DEMO_NS}/counter" 2>&1 | sed 's/^/    /'
pause

scene "First request resumes it onto a worker (sub-second)"
narrate "Hit the router with Host header naming the actor. Substrate's network"
narrate "controller resumes the actor onto one of the warm pods and routes the call."
echo ""
echo -e "  ${YELLOW}\$ curl -X POST -H 'Host: my-counter-1${ACTOR_HOST_SUFFIX}' \\${NC}"
echo -e "  ${YELLOW}      http://localhost:${ROUTER_LOCAL_PORT}/${NC}"
pause
hit_actor my-counter-1 | sed 's/^/    /'
echo ""
narrate "Status now:"
run_cmd "kubectl ate get actor my-counter-1"
callout "STATUS_RUNNING + an ATEOM POD assignment. Latency for the cold start: ~50ms."
pause

scene "State persists across requests (counter increments)"
narrate "The counter actor keeps its memory across requests. Fire 3 more:"
for i in 1 2 3; do
  echo -e "  ${YELLOW}\$ curl ... Host: my-counter-1...${NC}"
  hit_actor my-counter-1 | sed 's/^/    /'
done
callout "Counter goes up. Same actor, same pod, persistent state."
pause
fi # end Act 2

# ── ACT 3 ─────────────────────────────────────────────────────────────────────
if [ "$END_ACT" -ge 3 ]; then
silent_for 3
act 3 "Density — 20 actors share the same 5-pod pool"
scene "Spin up 20 actors"
narrate "Normal Kubernetes: 20 agents = 20+ pods. Substrate: 20 actors × 5 pods."
for i in $(seq 2 21); do
  create_actor_fresh "counter-$i" "${DEMO_NS}/counter" >/dev/null 2>&1
done
check_ok "20 more actors created (counter-2 … counter-21)"
echo ""
narrate "Resume them all by sending one request to each:"
for i in $(seq 2 21); do hit_actor "counter-$i" >/dev/null 2>&1; done
sleep 3
echo ""
scene "Look at the worker→actor distribution"
narrate "Actors assigned per worker pod (out of 21 total actors):"
# ATEOM POD column = 5 in the table output (NAMESPACE TEMPLATE ID STATUS ATEOM_POD ATEOM_IP VERSION).
# Strip the leading namespace/ prefix so it's just the pod name. <none> rows = suspended actors.
kubectl ate get actors 2>/dev/null \
  | awk 'NR>1 {print $5}' \
  | sed 's|.*/||' \
  | sort | uniq -c | sort -rn | head -10 \
  | sed 's/^/    /'
echo ""
narrate "Pods in the pool (should still be 5 — pool size is fixed):"
run_cmd "kubectl --context ${KCTX} get pods -n ${DEMO_NS} -l ate.dev/worker-pool=counter --no-headers | wc -l"
callout "21 actors, 5 pods. That's 4x oversubscription on a toy demo."
callout "The upstream demo video shows 250 actors on 8 pods (30x)."
pause
fi # end Act 3

# ── ACT 4 ─────────────────────────────────────────────────────────────────────
if [ "$END_ACT" -ge 4 ]; then
silent_for 4
act 4 "Pause + Resume — Hibernate an Actor, Preserve State"
scene "Send a couple of requests to counter-2, note its count"
BEFORE=$(hit_actor counter-2; hit_actor counter-2)
echo "  $BEFORE" | tail -1 | sed 's/^/    last: /'
pause

scene "Suspend (hibernate) the actor"
narrate "ATEOM POD assignment goes away; the actor's RAM is hibernated to durable"
narrate "storage via a full-state snapshot. Worker pod stays available for the"
narrate "other 20 actors. (Note: 'suspend' is the heavyweight hibernation. 'pause'"
narrate "exists too for short-term holds without snapshotting.)"
run_cmd "kubectl ate suspend actor counter-2"
sleep 2
run_cmd "kubectl ate get actor counter-2"
callout "STATUS_SUSPENDED + ATEOM POD <none>. State snapshot is in durable storage."
pause

scene "Next request transparently resumes it — counter continues from where it was"
echo -e "  ${YELLOW}\$ curl ... Host: counter-2...${NC}"
hit_actor counter-2 | sed 's/^/    /'
hit_actor counter-2 | sed 's/^/    /'
callout "The count picked up from where pause hibernated it. State preserved across"
callout "a full suspend cycle — no DB, no cold-start, no app-level checkpoint."
pause
fi # end Act 4

###############################################################################
# Finale
###############################################################################
echo ""
echo -e "${BG_BLUE}${WHITE}                                                                ${NC}"
echo -e "${BG_BLUE}${WHITE}   Substrate sidetrack complete.                                ${NC}"
echo -e "${BG_BLUE}${WHITE}                                                                ${NC}"
echo ""
echo -e "${BOLD}What's running:${NC}"
echo "  kind cluster:           kind-${CLUSTER_NAME}"
echo "  Substrate control:      ate-system namespace"
echo "  Demo pool + template:   ${DEMO_NS} (workerpool 'counter', 5 pods)"
echo "  Actors created:         kubectl ate get actors --all-namespaces"
echo ""
echo -e "${BOLD}Where the YAML lives:${NC}"
echo "  Substrate manifests:    .substrate-src/manifests/ate-install/"
echo "  Counter demo:           .substrate-src/demos/counter/"
echo ""
echo -e "${BOLD}Reset / teardown:${NC}"
echo "  ./substrate-demo.sh --reset   # delete just the actors"
echo "  ./teardown-substrate.sh       # nuke the kind cluster"
echo ""
echo -e "${BOLD}Main demo:${NC}"
echo "  kubectl config use-context k3d-ai-demo"
echo "  ./demo.sh"
