#!/usr/bin/env bash
# Publish (or update) the runbook in an Azure Automation account, link it to a PowerShell 7.4 runtime
# environment, and prove that the published bytes equal the local file (fetch-back SHA-256).
# Usage: SUBSCRIPTION_ID=… RESOURCE_GROUP=… AUTOMATION_ACCOUNT=… [RUNBOOK_NAME=Enable-SmartTiering] [RUNTIME_ENVIRONMENT=PowerShell74] \
#        [RUNBOOK_FILE=src/Enable-SmartTiering.ps1] [LOCATION=<explicit override>] scripts/publish-runbook.sh
# Needs: az CLI logged in with Contributor on the Automation Account's resource group. Exits non-zero on
# any mismatch, so it is safe to use in a release pipeline.
set -euo pipefail
: "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID}" "${RESOURCE_GROUP:?set RESOURCE_GROUP}" "${AUTOMATION_ACCOUNT:?set AUTOMATION_ACCOUNT}"
RUNBOOK_NAME=${RUNBOOK_NAME:-Enable-SmartTiering}; RUNTIME_ENVIRONMENT=${RUNTIME_ENVIRONMENT:-PowerShell74}; RUNBOOK_FILE=${RUNBOOK_FILE:-src/Enable-SmartTiering.ps1}; LOCATION=${LOCATION:-}
ARM=https://management.azure.com; BASE="$ARM/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Automation/automationAccounts/$AUTOMATION_ACCOUNT"
[ -f "$RUNBOOK_FILE" ] || { echo "runbook file not found: $RUNBOOK_FILE" >&2; exit 2; }
if [ -z "$LOCATION" ]; then
  LOCATION=$(az rest --method get --url "$BASE?api-version=2024-10-23" --query location -o tsv)
fi
[ -n "$LOCATION" ] || { echo "could not determine the Automation Account location; set LOCATION explicitly" >&2; exit 2; }
LOCAL_SHA=$(sha256sum "$RUNBOOK_FILE" | cut -c1-64)
echo "local  $RUNBOOK_FILE  sha256=$LOCAL_SHA"
echo "target Automation Account location=$LOCATION"
# 1 create the runbook if it does not exist (the CLI 'automation' group is marked experimental; warnings are harmless)
if ! az rest --method get --url "$BASE/runbooks/$RUNBOOK_NAME?api-version=2024-10-23" -o none 2>/dev/null; then
  az automation runbook create --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --automation-account-name "$AUTOMATION_ACCOUNT" \
    --name "$RUNBOOK_NAME" --type PowerShell --location "$LOCATION" -o none 2>/dev/null
  echo "runbook created"
fi
# 2 replace the draft content
az automation runbook replace-content --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --automation-account-name "$AUTOMATION_ACCOUNT" \
  --name "$RUNBOOK_NAME" --content @"$RUNBOOK_FILE" -o none 2>/dev/null
echo "draft content replaced"
# 3 link the runtime environment (not possible through the CLI; ARM PATCH)
az rest --method patch --url "$BASE/runbooks/$RUNBOOK_NAME?api-version=2024-10-23" --body "{\"properties\":{\"runtimeEnvironment\":\"$RUNTIME_ENVIRONMENT\"}}" -o none
echo "runtime environment linked"
# 4 publish
az automation runbook publish --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --automation-account-name "$AUTOMATION_ACCOUNT" --name "$RUNBOOK_NAME" -o none 2>/dev/null
echo "publish request completed"
# 5 wait for publication to converge, then fetch back and compare
STATE=""; REMOTE_RUNTIME=""; REMOTE_SHA=""
for _ in $(seq 1 60); do
  STATE=$(az rest --method get --url "$BASE/runbooks/$RUNBOOK_NAME?api-version=2024-10-23" --query properties.state -o tsv)
  REMOTE_RUNTIME=$(az rest --method get --url "$BASE/runbooks/$RUNBOOK_NAME?api-version=2024-10-23" --query properties.runtimeEnvironment -o tsv)
  if REMOTE_SHA=$(az rest --method get --url "$BASE/runbooks/$RUNBOOK_NAME/content?api-version=2023-11-01" -o tsv 2>/dev/null | tr -d '\r' | sha256sum | cut -c1-64); then
    if [ "$STATE" = "Published" ] && [ "$REMOTE_RUNTIME" = "$RUNTIME_ENVIRONMENT" ] && [ "$REMOTE_SHA" = "$LOCAL_SHA" ]; then
      break
    fi
  fi
  sleep 5
done
echo "remote state/runtime: $STATE $REMOTE_RUNTIME"
echo "remote sha256=$REMOTE_SHA"
[ "$STATE" = "Published" ] || { echo "MISMATCH: runbook is not Published" >&2; exit 1; }
[ "$REMOTE_RUNTIME" = "$RUNTIME_ENVIRONMENT" ] || { echo "MISMATCH: runtime environment differs" >&2; exit 1; }
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] || { echo "MISMATCH: published bytes differ from the local file" >&2; exit 1; }
echo "OK: published bytes equal the local file"
