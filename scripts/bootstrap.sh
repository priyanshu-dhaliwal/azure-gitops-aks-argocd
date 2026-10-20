#!/usr/bin/env bash
# Bootstrap a cluster: Terraform builds it, ArgoCD takes over.
#
#   ./scripts/bootstrap.sh dev
#
# Idempotent: safe to re-run. The second run applies nothing if the cluster and
# the root Application already exist.
set -euo pipefail

ENV="${1:-dev}"
RG="rg-gito-${ENV}-platform"
[[ "$ENV" == "prod" ]] && RG="rg-gitp-prod-platform"

echo "==> 1/5 terraform init"
(cd infra && terraform init -backend-config="environments/${ENV}.backend.hcl")

echo "==> 2/5 terraform plan"
(cd infra && terraform plan -var-file="params/${ENV}.tfvars" -out=tfplan)

echo "==> 3/5 terraform apply"
(cd infra && terraform apply tfplan)

CLUSTER=$(cd infra && terraform output -raw cluster_name)
echo "==> cluster: $CLUSTER"

echo "==> 4/5 fetch credentials (Azure AD, no static admin)"
az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing

echo "==> 5/5 wait for ArgoCD and the root Application"
kubectl -n argocd wait --for=condition=available --timeout=300s \
  deployment/argocd-server

for i in $(seq 1 60); do
  if kubectl -n argocd get application root >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

echo "==> ArgoCD is up. Root application:"
kubectl -n argocd get applications -o wide

cat <<'MSG'

Next:
  argocd login --sso argocd.<env>.example.com
  ./scripts/verify-gitops.sh <env>

Remember: from here on, changes go through Git. There is no kubectl in the
normal workflow — see docs/runbook.md for the one documented exception.
MSG
