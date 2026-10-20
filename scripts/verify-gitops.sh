#!/usr/bin/env bash
# Assert the eight GitOps properties from the README. Exits 1 on any failure.
set -uo pipefail

ENV="${1:-dev}"
RG="rg-gito-${ENV}-platform"
[[ "$ENV" == "prod" ]] && RG="rg-gitp-prod-platform"
FAIL=0

pass() { printf '\033[32m[ok]\033[0m   %s\n' "$1"; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "==> GitOps posture: $ENV"
echo

# 1. AKS local accounts disabled
if az aks show -g "$RG" -n "aks-gito-${ENV}" --query 'disableLocalAccounts' -o tsv 2>/dev/null | grep -qi true \
   || az aks show -g "$RG" -n "aks-gitp-prod" --query 'disableLocalAccounts' -o tsv 2>/dev/null | grep -qi true; then
  pass "AKS local accounts are disabled (no static kubeconfig)"
else
  fail "local accounts are enabled — a leaked kubeconfig never expires"
fi

# 2. ArgoCD admin account disabled
ADMIN=$(kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.admin\.password}' 2>/dev/null || echo "missing")
if [ -z "$ADMIN" ] || [ "$ADMIN" = "" ]; then
  pass "ArgoCD admin account is disabled"
else
  fail "ArgoCD admin password is set — use OIDC only"
fi

# 3. Every Application Synced and Healthy
NOT_SYNCED=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' \
  | awk '$2!="Synced" || ($3!="Healthy" && $3!="")' || true)
if [ -z "$NOT_SYNCED" ]; then
  pass "every Application is Synced and Healthy"
else
  fail "applications not converged:"; echo "$NOT_SYNCED" | sed 's/^/       /'
fi

# 4. Auto-sync with selfHeal enabled everywhere
NO_SELFHEAL=$(kubectl -n argocd get applications -o json \
  | jq -r '.items[] | select(.spec.syncPolicy.automated.selfHeal != true) | .metadata.name' 2>/dev/null || true)
if [ -z "$NO_SELFHEAL" ]; then
  pass "every Application has automated selfHeal"
else
  fail "applications without selfHeal:"; echo "$NO_SELFHEAL" | sed 's/^/       /'
fi

# 5. Kyverno in Enforce mode with the expected policies
POLICIES=$(kubectl get clusterpolicies.kyverno.io -o json 2>/dev/null \
  | jq '[.items[] | select(.spec.validationFailureAction=="Enforce")] | length' 2>/dev/null || echo 0)
if [ "${POLICIES:-0}" -ge 4 ]; then
  pass "kyverno has $POLICIES cluster policies in Enforce mode"
else
  fail "only ${POLICIES:-0} enforcing kyverno policies (expected >= 4)"
fi

# 6. No Secret objects in workload namespaces
SECRETS=$(kubectl get secrets -n api -n worker -o json 2>/dev/null \
  | jq -r '.items[] | select(.type != "kubernetes.io/service-account-token") | .metadata.name' 2>/dev/null || true)
SECRETS=$(echo "$SECRETS" | grep -v -E 'app-secrets|helm|sh.helm' || true)
if [ -z "$SECRETS" ]; then
  pass "no unexpected Secret objects in workload namespaces (external-secrets only)"
else
  echo "$SECRETS" | sed 's/^/       /'
  fail "Secret objects found in workload namespaces"
fi

# 7. Every pod has an owner label and a memory limit
BAD_PODS=$(kubectl get pods -A -o json 2>/dev/null | jq -r '
  .items[]
  | select(.metadata.namespace=="api" or .metadata.namespace=="worker")
  | select((.metadata.labels.owner // "") == "")
  | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || true)
if [ -z "$BAD_PODS" ]; then
  pass "every workload pod carries an owner label"
else
  fail "pods without an owner label:"; echo "$BAD_PODS" | sed 's/^/       /'
fi

# 8. No Application follows anything but main
BAD_REV=$(kubectl -n argocd get applications -o json 2>/dev/null \
  | jq -r '.items[] | select(.spec.source.targetRevision != "main") | "\(.metadata.name): \(.spec.source.targetRevision)"' || true)
if [ -z "$BAD_REV" ]; then
  pass "every Application follows main"
else
  fail "applications following another revision:"; echo "$BAD_REV" | sed 's/^/       /'
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m==> GitOps posture OK\033[0m\n'
  exit 0
fi
printf '\033[31m==> %d check(s) failed\033[0m\n' "$FAIL"
exit 1
