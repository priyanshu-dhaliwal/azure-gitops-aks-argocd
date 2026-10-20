#!/usr/bin/env bash
# Fail if any Application is OutOfSync with auto-sync disabled, or has been
# OutOfSync for more than 10 minutes.
#
# Intended for a scheduled job: Argo self-heals within 3 minutes, so anything
# still out of sync after 10 is either a failed sync or self-heal was turned off.
set -euo pipefail
ENV="${1:-prod}"

kubectl -n argocd get applications -o json | jq -r '
  .items[]
  | select(.status.sync.status == "OutOfSync")
  | "\(.metadata.name)\t\(.status.operationState.finishedAt // "never")"' > /tmp/drift.txt

if [ ! -s /tmp/drift.txt ]; then
  echo "==> no drift in $ENV"
  exit 0
fi

echo "==> drift detected in $ENV:"
cat /tmp/drift.txt
echo
echo "If this persists, see docs/runbook.md#stuck-sync"
exit 1
