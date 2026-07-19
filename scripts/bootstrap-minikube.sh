#!/usr/bin/env bash
set -euo pipefail

ARGOCD_NS="argocd"
ARGOCD_CHART_VERSION="7.8.0"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
for cmd in minikube helm kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found on PATH. Please install it first." >&2
    exit 1
  fi
done

# ── 1. Ensure minikube is running ─────────────────────────────────────────────
info "Checking minikube status..."
if ! minikube status --format='{{.Host}}' 2>/dev/null | grep -q "Running"; then
  info "Starting minikube..."
  minikube start
else
  success "minikube is already running"
fi

# ── 2. Install / upgrade ArgoCD via Helm ─────────────────────────────────────
info "Adding argo Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo

info "Installing ArgoCD ${ARGOCD_CHART_VERSION} into namespace '${ARGOCD_NS}'..."
helm upgrade --install argocd argo/argo-cd \
  --version "${ARGOCD_CHART_VERSION}" \
  --namespace "${ARGOCD_NS}" \
  --create-namespace \
  --wait \
  --timeout 5m \
  --set configs.params."server\.insecure"=true

success "ArgoCD installed"

# ── 3. Wait for ArgoCD server to be ready ────────────────────────────────────
info "Waiting for argocd-server to be ready..."
kubectl rollout status deployment/argocd-server \
  -n "${ARGOCD_NS}" \
  --timeout=3m
success "argocd-server is ready"

# ── 4. Seed the root Application (the one-time bootstrap object) ──────────────
info "Applying root Application..."
kubectl apply \
  -f "${REPO_ROOT}/bootstrap/root-app.yaml" \
  -n "${ARGOCD_NS}"
success "Root Application seeded — ArgoCD now manages everything else from git"

# ── 5. Print access instructions ─────────────────────────────────────────────
ADMIN_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n "${ARGOCD_NS}" \
  -o jsonpath='{.data.password}' | base64 -d)

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Bootstrap complete!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "  Open the UI:    make ui          (port-forwards to http://localhost:8080)"
echo "  Username:       admin"
echo "  Password:       ${ADMIN_PASSWORD}"
echo ""
echo "  Check app status any time with:  make status"
echo ""
warn "ArgoCD may take a minute to finish syncing all Applications."
warn "The root app will sync bootstrap/, which will create the AppSets and Projects."
