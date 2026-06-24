#!/usr/bin/env bash
#
# Solo Agentic Demo — Substrate Sidetrack Teardown
#
# Deletes the substrate-demo kind cluster + its local registry. Idempotent.
# Does NOT touch the main k3d "ai-demo" cluster.

set -euo pipefail

CLUSTER_NAME="${SUBSTRATE_CLUSTER_NAME:-substrate-demo}"
REGISTRY_NAME="${SUBSTRATE_REGISTRY_NAME:-kind-registry}"

YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

echo -e "${YELLOW}Tearing down substrate sidetrack cluster '${CLUSTER_NAME}'...${NC}"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  kind delete cluster --name "${CLUSTER_NAME}"
else
  echo "  (kind cluster '${CLUSTER_NAME}' not present)"
fi

# The local registry is shared between kind clusters — only stop it if no other
# kind cluster is using it. Easiest check: if any kind clusters remain, leave it.
if [ "$(kind get clusters 2>/dev/null | wc -l | xargs)" = "0" ]; then
  if docker inspect "${REGISTRY_NAME}" >/dev/null 2>&1; then
    echo "  Removing local registry '${REGISTRY_NAME}' (no other kind clusters use it)..."
    docker rm -f "${REGISTRY_NAME}" >/dev/null
  fi
else
  echo "  (leaving local registry '${REGISTRY_NAME}' — other kind clusters present)"
fi

echo -e "${GREEN}Substrate sidetrack torn down. Main k3d cluster untouched.${NC}"
