#!/usr/bin/env bash
# Publish (or update) the runbook in an Azure Automation account, link it to a PowerShell 7.4 runtime
# environment, and prove that the published bytes equal the local file (fetch-back SHA-256).
# Usage: SUBSCRIPTION_ID=… RESOURCE_GROUP=… AUTOMATION_ACCOUNT=… [RUNBOOK_NAME=Enable-SmartTiering] [RUNTIME_ENVIRONMENT=PowerShell74] \
#        [RUNBOOK_FILE=src/Enable-SmartTiering.ps1] [LOCATION=eastus2] scripts/publish-runbook.sh
# Needs: az CLI logged in with Contributor on the Automation Account's resource group. Exits non-zero on
# any mismatch, so it is safe to use in a release pipeline.
set -euo pipefail
: "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID}" "${RESOURCE_GROUP:?set RESOURCE_GROUP}" "${AUTOMATION_ACCOUNT:?set AUTOMATION_ACCOUNT}"
RUNBOOK_NAME=${RUNBOOK_NAME:-Enable-SmartTiering}; RUNTIME_ENVIRONMENT=${RUNTIME_ENVIRONMENT:-PowerShell74}; RUNBOOK_FILE=${RUNBOOK_FILE:-src/Enable-SmartTiering.ps1}; LOCATION=${LOCATION:-eastus2}
ARM=https://management.azure.com; BASE="$ARM/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Automation/automationAccounts/$AUTOMATION_ACCOUNT"
[ -f "$RUNBOOK_FILE" ] || { echo "runbook file not found: $RUNBOOK_FILE" >&2; exit 2; }
LOCAL_SHA=$(sha256sum "$RUNBOOK_FILE" | cut -c1-64)
echo "local  $RUNBOOK_FILE  sha256=$LOCAL_SHA"
# 1 create the runbook if it does not exist (the CLI 'automation' group is marked experimental; warnings are harmless)
if ! az rest --method get --url "$BASE/runbooks/$RUNBOOK_NAME?api-version=2024-10-23" -o none 2>/dev/null; then
  az automation runbook create --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --automation-account-name "$AUTOMATION_ACCOUNT" \
    --name "$RUNBOOK_NAME" --type PowerShell --location "$LOCATION" -o none 2>/dev/null && echo "created $RUNBOOK_NAME"
fi
# 2 replace the draft content
az automation runbook replace-content --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --automation-account-name "$AUTOMATION_ACCOUNT" \
  --name "$RUNBOOK_NAME" --content @"$RUNBOOK_FILE" -o none 2>/dev/null && echo "draft content replaced"
# 3 link the runtime environment (not possible through the CLI; ARM PATCH)
az rest --method patch --url "$BASE/runbooks/$RUNBOOK_NAME?api-version=2024-10-23" --body "{\"properties\":{\"runtimeEnvironment\":\"$RUNTIME_ENVIRONMENT\"}}" -o none && echo "linked to runtime environment $RUNTIME_ENVIRONMENT"
# 4 publish
az automation runbook publish --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --automation-account-name "$AUTOMATION_ACCOUNT" --name "$RUNBOOK_NAME" -o none 2>/dev/null && echo "published"
# 5 fetch back and compare
REMOTE_SHA=$(az rest --method get --url "$BASE/runbooks/$RUNBOOK_NAME/content?api-version=2023-11-01" -o tsv | tr -d '\r' | sha256sum | cut -c1-64)
STATE=$(az rest --method get --url "$BASE/runbooks/$RUNBOOK_NAME?api-version=2024-10-23" --query '[properties.state, properties.runtimeEnvironment]' -o tsv | tr '\n' ' ')
echo "remote state/runtime: $STATE"; echo "remote sha256=$REMOTE_SHA"
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] && echo "OK: published bytes equal the local file" || { echo "MISMATCH: published bytes differ from the local file" >&2; exit 1; }
