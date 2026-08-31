# Replicate this in Azure — step by step

This runbook builds a new empty Azure Backup Smart Tiering canary, proves the audit and bounded
write paths, removes temporary writer access, and leaves the read-only showcase alive. It contains
no tenant-specific identifiers. For the full Azure Policy + Azure Automation showcase, start with
the [canonical combined guide](https://github.com/kevo099/azure-enterprise-policy-baseline/blob/main/docs/REPLICATE-POLICY-AUTOMATION.md).

The fixture contains no protected items. It proves the control-plane path; it does not move a
recovery point into archive storage. Read [gotchas.md](gotchas.md) before the first `Apply=true`.

## 0. Prerequisites and source pin

- Bash 4 or newer, `curl`, `jq`, GNU coreutils (`sha256sum` and `sort -V`), Azure CLI 2.75.0 or
  newer with Bicep and the experimental `automation` extension version `1.0.0b2`, and PowerShell
  7.4 for the offline harness.
- A commercial Azure subscription where you can create a new isolated resource group.
- Contributor for the fixture and runbook. Owner or User Access Administrator is needed only at
  the canary resource group while creating the two custom roles and their assignments.
- Permission to register Azure resource providers at subscription scope, or a platform owner who
  registers them before the canary deployment.
- A region with Automation Account quota. If a fresh deployment fails on quota, inspect and remove
  that incomplete resource group before starting again in another region; do not update it in place.

Clone an immutable reviewed revision, record it with the change, and run the local gates before any
Azure write:

```bash
set -euo pipefail
umask 077

git clone https://github.com/kevo099/azure-backup-smart-tiering-automation.git
cd azure-backup-smart-tiering-automation
AUTOMATION_DIR="$(pwd)"
AUTOMATION_COMMIT="d6b31076fbfd01c7010a15ded377b3f21ab9bb96"
git checkout "$AUTOMATION_COMMIT"
git rev-parse HEAD

pwsh -NonInteractive -NoProfile -File tests/StaticValidation.ps1
pwsh -NonInteractive -NoProfile -File tests/BehaviorHarness.ps1
for file in scripts/*.sh; do bash -n "$file"; done
jq empty infra/rbac/*.json
az bicep build --file infra/test-environment.bicep --stdout > /dev/null
```

Sign in and define local-only values. Use a unique suffix; vault and Automation Account names must
not collide with existing resources.

```bash
az login
AZ_CLI_VERSION="$(az version --query '"azure-cli"' -o tsv)"
test "$(printf '%s\n' 2.75.0 "$AZ_CLI_VERSION" | sort -V | head -1)" = "2.75.0"
az extension add --name automation --version 1.0.0b2 --upgrade --yes
test "$(az extension show --name automation --query version -o tsv)" = "1.0.0b2"

SUB="$(az account show --query id -o tsv)"
REGION="centralus"
SUFFIX="<unique-short-suffix>"
RG="rg-smart-tiering-$SUFFIX"
AA="aa-smart-tiering-$SUFFIX"
RG_VAULT="rsv-smarttier-rg-$SUFFIX"
SUB_VAULT="rsv-smarttier-sub-$SUFFIX"
POLICY="smart-tiering-remediation-canary"
ARM="https://management.azure.com"
RG_SCOPE="/subscriptions/$SUB/resourceGroups/$RG"
EVIDENCE_DIR="$(mktemp -d)"
```

Run every command block in one Bash session. The evidence directory is outside the repository and
has private permissions because of `umask 077`. Do not commit raw job output, resource IDs,
principal IDs, or rendered role definitions.

## 1. Deploy the fresh fixture once

Create a new resource group, prove it is empty, then deploy the safe compliant fixture. Set
`retainForInspection=true` so its tags describe the intended leave-alive lifecycle.

```bash
for provider in Microsoft.Authorization Microsoft.Automation Microsoft.RecoveryServices; do
  az provider register --subscription "$SUB" --namespace "$provider" --wait --only-show-errors
done

test "$(az group exists --subscription "$SUB" --name "$RG")" = "false"

az group create \
  --subscription "$SUB" \
  --name "$RG" \
  --location "$REGION" \
  --tags Purpose=SmartTieringLiveDemo Lifecycle=RetainForInspection

test "$(az group show --subscription "$SUB" --name "$RG" --query id -o tsv | tr '[:upper:]' '[:lower:]')" = \
  "$(printf '%s' "$RG_SCOPE" | tr '[:upper:]' '[:lower:]')"
test "$(az group show --subscription "$SUB" --name "$RG" --query 'tags.Purpose' -o tsv)" = \
  "SmartTieringLiveDemo"
test "$(az resource list --subscription "$SUB" --resource-group "$RG" --query 'length(@)' -o tsv)" = "0"

az deployment group create \
  --subscription "$SUB" \
  --resource-group "$RG" \
  --template-file infra/test-environment.bicep \
  --parameters \
    resourceGroupScopeVaultName="$RG_VAULT" \
    subscriptionScopeVaultName="$SUB_VAULT" \
    automationAccountName="$AA" \
    backupPolicyName="$POLICY" \
    testPolicyTieringMode=TierRecommended \
    retainForInspection=true

PRINCIPAL="$(az automation account show \
  --subscription "$SUB" \
  --resource-group "$RG" \
  --name "$AA" \
  --query identity.principalId -o tsv)"
test -n "$PRINCIPAL"
```

The Bicep file creates the Automation Account, PowerShell 7.4 runtime, two empty vaults, and one
canary policy in each vault. It does not publish the runbook or create RBAC. Do not use the full
template later as a policy-update mechanism: Azure-added defaults can make an incremental redeploy
change unrelated properties. Step 5 seeds only the exact empty canary policy.

## 2. Publish and prove the runbook bytes

```bash
EXPECTED_RUNBOOK_SHA="$(sha256sum src/Enable-SmartTiering.ps1 | cut -d' ' -f1)"
SUBSCRIPTION_ID="$SUB" \
RESOURCE_GROUP="$RG" \
AUTOMATION_ACCOUNT="$AA" \
scripts/publish-runbook.sh
```

The script discovers the Automation Account location unless `LOCATION` is explicitly supplied. It
must print `remote state/runtime: Published PowerShell74` and `OK: published bytes equal the local
file`. Record the printed SHA-256 with the source commit.

## 3. Job helpers

The experimental CLI can start and inspect jobs but does not expose their output. These helpers use
the Automation REST API for terminal status, output, and all streams:

```bash
AA_BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Automation/automationAccounts/$AA"

start_job() {
  local apply="$1"
  shift
  az automation runbook start \
    --subscription "$SUB" \
    --resource-group "$RG" \
    --automation-account-name "$AA" \
    --name Enable-SmartTiering \
    --parameters \
      SubscriptionId="$SUB" \
      ScopeType=ResourceGroup \
      ResourceGroupName="$RG" \
      VaultName="$RG_VAULT" \
      PolicyName="$POLICY" \
      Apply="$apply" \
      "$@" \
    --query name -o tsv
}

wait_job() {
  local job="$1" status
  for _ in $(seq 1 240); do
    status="$(az rest --method get \
      --url "$AA_BASE/jobs/$job?api-version=2024-10-23" \
      --query properties.status -o tsv)"
    case "$status" in
      Completed|Failed|Stopped|Suspended) printf '%s\n' "$status"; return 0 ;;
    esac
    sleep 5
  done
  printf '%s\n' TimedOut
  return 1
}

WRITER_GRANTED=false
revoke_writer_on_exit() {
  local original_status=$?
  if [ "$WRITER_GRANTED" = true ]; then
    if ! "$AUTOMATION_DIR/scripts/ring-role.sh" revoke "$SUB" "$RG" "$PRINCIPAL"; then
      printf 'Automatic writer-role revocation failed; revoke it manually now\n' >&2
      return 1
    fi
  fi
  return "$original_status"
}
trap revoke_writer_on_exit EXIT

job_output() {
  az rest --method get \
    --url "$AA_BASE/jobs/$1/output?api-version=2024-10-23" -o tsv
}

job_streams() {
  az rest --method get \
    --url "$AA_BASE/jobs/$1/streams?api-version=2024-10-23" \
    --query 'value[].{time:properties.time,type:properties.streamType,text:properties.summary}' -o table
}
```

## 4. Optional no-reader negative proof

Before assigning RBAC, an audit must fail before reaching a policy PUT. Depending on managed
identity readiness, the failure can occur during token/context initialization or the first vault
read:

```bash
NO_READER_JOB="$(start_job false)"
test "$(wait_job "$NO_READER_JOB")" = "Failed"
job_streams "$NO_READER_JOB"
```

This class of failure occurs before the result and summary section, so the job has no `SUMMARY`
line. Its failed status and Error stream are the evidence. A missing summary by itself is not
evidence that the job completed safely. The sanitized live qualification happened to reach the
vault-list call and receive HTTP 403; do not require that exact stage in every new tenant.

## 5. Grant RG-only reader access and seed only the exact policy

The RG helper creates a read-only custom role whose assignable scope is this resource group, then
assigns it to the Automation identity:

```bash
scripts/discovery-role.sh grant "$SUB" "$RG" "$PRINCIPAL"
```

Allow for RBAC propagation. Then fetch the exact policy, require zero protected items, construct a
write payload without read-only members, and change only the archive-tier block to `DoNotTier`.
This direct seed is an operator action on the empty canary; it does not use the Automation writer.

```bash
POLICY_ID="$RG_SCOPE/providers/Microsoft.RecoveryServices/vaults/$RG_VAULT/backupPolicies/$POLICY"
POLICY_URL="$ARM$POLICY_ID?api-version=2025-08-01"

az rest --method get --url "$POLICY_URL" > "$EVIDENCE_DIR/pre.json"
jq -e '
  .properties.protectedItemsCount == 0 and
  .properties.tieringPolicy.ArchivedRP.tieringMode == "TierRecommended"
' "$EVIDENCE_DIR/pre.json" > /dev/null

jq '
  del(.id, .name, .type, .systemData, .eTag)
  | .properties |= del(.protectedItemsCount, .resourceGuardOperationRequests)
  | .properties.tieringPolicy.ArchivedRP |= (
      del(.tieringMode, .duration, .durationType)
      + {tieringMode: "DoNotTier"}
    )
' "$EVIDENCE_DIR/pre.json" > "$EVIDENCE_DIR/seed.json"

ETAG="$(jq -r '.eTag // empty' "$EVIDENCE_DIR/pre.json")"
SEED_TOKEN="$(az account get-access-token --resource "$ARM/" \
  --query accessToken -o tsv)"
SEED_CURL=(
  --silent --show-error
  --proto '=https'
  --request PUT
  --url "$POLICY_URL"
  --header "Content-Type: application/json"
  --data-binary "@$EVIDENCE_DIR/seed.json"
  --dump-header "$EVIDENCE_DIR/seed-headers.txt"
  --output "$EVIDENCE_DIR/seed-response.json"
  --write-out '%{http_code}'
)
if [ -n "$ETAG" ]; then
  SEED_CURL+=(--header "If-Match: $ETAG")
fi
SEED_HTTP_STATUS="$(
  printf 'header = "Authorization: Bearer %s"\n' "$SEED_TOKEN" \
    | curl --config - "${SEED_CURL[@]}"
)"

case "$SEED_HTTP_STATUS" in
  200)
    ;;
  202)
    SEED_OPERATION_URL="$(awk '
      tolower($1) == "azure-asyncoperation:" {
        sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit
      }
    ' "$EVIDENCE_DIR/seed-headers.txt")"
    SEED_LOCATION_URL="$(awk '
      tolower($1) == "location:" {
        sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit
      }
    ' "$EVIDENCE_DIR/seed-headers.txt")"
    test -n "$SEED_OPERATION_URL" || test -n "$SEED_LOCATION_URL"
    if [ -n "$SEED_OPERATION_URL" ]; then
      case "$SEED_OPERATION_URL" in
        "$ARM"/*) ;;
        *) printf 'Untrusted policy-operation URL\n' >&2; exit 1 ;;
      esac
    fi
    if [ -n "$SEED_LOCATION_URL" ]; then
      case "$SEED_LOCATION_URL" in
        "$ARM"/*) ;;
        *) printf 'Untrusted policy-result URL\n' >&2; exit 1 ;;
      esac
    fi
    SEED_RETRY_AFTER="$(awk '
      tolower($1) == "retry-after:" {gsub(/\r/, "", $2); print $2; exit}
    ' "$EVIDENCE_DIR/seed-headers.txt")"
    case "$SEED_RETRY_AFTER" in
      ''|*[!0-9]*) SEED_RETRY_AFTER=5 ;;
    esac
    if [ "$SEED_RETRY_AFTER" -gt 60 ]; then
      SEED_RETRY_AFTER=60
    fi
    SEED_DEADLINE="$(( $(date +%s) + 900 ))"
    if [ -n "$SEED_OPERATION_URL" ]; then
      SEED_OPERATION_STATUS=""
      while [ "$(date +%s)" -lt "$SEED_DEADLINE" ]; do
        sleep "$SEED_RETRY_AFTER"
        az rest --method get --url "$SEED_OPERATION_URL" \
          > "$EVIDENCE_DIR/seed-operation.json"
        SEED_OPERATION_STATUS="$(jq -r '.status // .properties.status // empty' \
          "$EVIDENCE_DIR/seed-operation.json")"
        case "${SEED_OPERATION_STATUS,,}" in
          succeeded) break ;;
          failed|canceled|cancelled)
            printf 'Exact policy seed operation failed\n' >&2
            exit 1
            ;;
        esac
      done
      test "${SEED_OPERATION_STATUS,,}" = "succeeded"
    else
      SEED_LOCATION_STATUS=""
      SEED_LOCATION_CURL=(
        --silent --show-error
        --proto '=https'
        --request GET
        --url "$SEED_LOCATION_URL"
        --output "$EVIDENCE_DIR/seed-location.json"
        --write-out '%{http_code}'
      )
      while [ "$(date +%s)" -lt "$SEED_DEADLINE" ]; do
        sleep "$SEED_RETRY_AFTER"
        SEED_LOCATION_STATUS="$(
          printf 'header = "Authorization: Bearer %s"\n' "$SEED_TOKEN" \
            | curl --config - "${SEED_LOCATION_CURL[@]}"
        )"
        case "$SEED_LOCATION_STATUS" in
          200|201|204) break ;;
          202) ;;
          *)
            printf 'Exact policy seed result poll returned HTTP %s\n' \
              "$SEED_LOCATION_STATUS" >&2
            exit 1
            ;;
        esac
      done
      case "$SEED_LOCATION_STATUS" in
        200|201|204) ;;
        *) exit 1 ;;
      esac
      unset SEED_LOCATION_CURL
    fi
    ;;
  *)
    printf 'Exact policy seed returned HTTP %s\n' "$SEED_HTTP_STATUS" >&2
    exit 1
    ;;
esac
unset SEED_TOKEN SEED_CURL

wait_for_seeded_policy() {
  for _ in $(seq 1 60); do
    az rest --method get --url "$POLICY_URL" > "$EVIDENCE_DIR/seeded.json"
    if jq -e '
      .properties.protectedItemsCount == 0 and
      .properties.tieringPolicy.ArchivedRP.tieringMode == "DoNotTier"
    ' "$EVIDENCE_DIR/seeded.json" > /dev/null; then
      return 0
    fi
    sleep 5
  done
  printf 'Timed out waiting for the exact policy seed\n' >&2
  return 1
}
wait_for_seeded_policy
```

## 6. Audit

```bash
AUDIT_JOB="$(start_job false)"
test "$(wait_job "$AUDIT_JOB")" = "Completed"
job_output "$AUDIT_JOB" | tee "$EVIDENCE_DIR/audit.output"

AUDIT_SUMMARY="$(sed -n 's/^SUMMARY //p' "$EVIDENCE_DIR/audit.output" | tail -1)"
printf '%s\n' "$AUDIT_SUMMARY" | jq -e '
  .candidates == 1 and
  .writesSubmitted == 0 and
  .policiesWritten == 0 and
  .errors == 0 and
  .abortReason == null
' > /dev/null
grep -q '"action":"WouldEnableTierRecommended"' "$EVIDENCE_DIR/audit.output"
```

## 7. Know the guard outputs

These failures are deliberately not identical:

| Test | Expected evidence |
|---|---|
| `Apply=true` with whitespace `VaultName` | Failed before any ARM call; no `SUMMARY` |
| `Apply=true` without both exact filters | Failed before any ARM call; no `SUMMARY` |
| `Apply=true PolicyName=<misspelled>` | Failed with `abortReason=NoPolicyMatched`; submitted/verified writes `0/0` |
| Exact `Apply=true` with reader only | PUT rejected with 403; policy unchanged; `writesSubmitted=1`, `writesFailed=1`, `errors=1` |

The reader-only negative proof is optional but safe on this empty exact-name canary:

```bash
READER_ONLY_JOB="$(start_job true ExpectedMatches=1 MaxChanges=1 MaxProtectedItemsPerPolicy=0)"
test "$(wait_job "$READER_ONLY_JOB")" = "Failed"
job_output "$READER_ONLY_JOB" | tee "$EVIDENCE_DIR/reader-only.output"
```

Do not describe `writesSubmitted` as a successful change: it counts the attempted PUT, while
`policiesWritten` counts only a post-write verified change.

## 8. Temporary writer, bounded apply, and idempotent repeat

```bash
WRITER_GRANTED=true
scripts/ring-role.sh grant "$SUB" "$RG" "$PRINCIPAL"
```

After RBAC propagates, run the exact-name apply. If Azure still returns 403, wait, re-run the audit
to re-establish `WouldEnableTierRecommended`, and only then retry the bounded apply.

```bash
APPLY_JOB="$(start_job true ExpectedMatches=1 MaxChanges=1 MaxProtectedItemsPerPolicy=0)"
test "$(wait_job "$APPLY_JOB")" = "Completed"
job_output "$APPLY_JOB" | tee "$EVIDENCE_DIR/apply.output"

APPLY_SUMMARY="$(sed -n 's/^SUMMARY //p' "$EVIDENCE_DIR/apply.output" | tail -1)"
printf '%s\n' "$APPLY_SUMMARY" | jq -e '
  .candidates == 1 and
  .writesSubmitted == 1 and
  .policiesWritten == 1 and
  .writesFailed == 0 and
  .writesUnknown == 0 and
  .errors == 0 and
  .abortReason == null
' > /dev/null
grep -q '"action":"EnabledAndVerified"' "$EVIDENCE_DIR/apply.output"

REPEAT_JOB="$(start_job true ExpectedMatches=1 MaxChanges=1 MaxProtectedItemsPerPolicy=0)"
test "$(wait_job "$REPEAT_JOB")" = "Completed"
job_output "$REPEAT_JOB" | tee "$EVIDENCE_DIR/repeat.output"

REPEAT_SUMMARY="$(sed -n 's/^SUMMARY //p' "$EVIDENCE_DIR/repeat.output" | tail -1)"
printf '%s\n' "$REPEAT_SUMMARY" | jq -e '
  .candidates == 0 and
  .writesSubmitted == 0 and
  .policiesWritten == 0 and
  .errors == 0 and
  .abortReason == null
' > /dev/null
grep -q '"action":"AlreadyCompliant"' "$EVIDENCE_DIR/repeat.output"
```

## 9. Verify invariants and remove the writer

```bash
az rest --method get --url "$POLICY_URL" > "$EVIDENCE_DIR/post.json"

jq -e '
  .properties.protectedItemsCount == 0 and
  .properties.tieringPolicy.ArchivedRP.tieringMode == "TierRecommended"
' "$EVIDENCE_DIR/post.json" > /dev/null

jq -S '.properties | del(.protectedItemsCount, .resourceGuardOperationRequests, .tieringPolicy.ArchivedRP)' \
  "$EVIDENCE_DIR/pre.json" > "$EVIDENCE_DIR/pre-nontiering.json"
jq -S '.properties | del(.protectedItemsCount, .resourceGuardOperationRequests, .tieringPolicy.ArchivedRP)' \
  "$EVIDENCE_DIR/post.json" > "$EVIDENCE_DIR/post-nontiering.json"
diff -u "$EVIDENCE_DIR/pre-nontiering.json" "$EVIDENCE_DIR/post-nontiering.json"

SUB_POLICY_URL="$ARM$RG_SCOPE/providers/Microsoft.RecoveryServices/vaults/$SUB_VAULT/backupPolicies/$POLICY?api-version=2025-08-01"
for policy_url in "$POLICY_URL" "$SUB_POLICY_URL"; do
  test "$(az rest --method get --url "$policy_url" \
    --query properties.tieringPolicy.ArchivedRP.tieringMode -o tsv)" = "TierRecommended"
done
for vault in "$RG_VAULT" "$SUB_VAULT"; do
  test "$(az backup item list \
    --subscription "$SUB" \
    --resource-group "$RG" \
    --vault-name "$vault" \
    --query 'length(@)' -o tsv)" = "0"
done

RUNBOOK_URL="$AA_BASE/runbooks/Enable-SmartTiering"
az rest --method get --url "$RUNBOOK_URL?api-version=2024-10-23" \
  --output json > "$EVIDENCE_DIR/runbook.json"
jq -e '
  .properties.state == "Published" and
  .properties.runtimeEnvironment == "PowerShell74"
' "$EVIDENCE_DIR/runbook.json" > /dev/null
az rest --method get \
  --url "$RUNBOOK_URL/content?api-version=2023-11-01" \
  --output-file "$EVIDENCE_DIR/runbook-content.ps1"
REMOTE_RUNBOOK_SHA="$(sha256sum "$EVIDENCE_DIR/runbook-content.ps1" | cut -d' ' -f1)"
test "$REMOTE_RUNBOOK_SHA" = "$EXPECTED_RUNBOOK_SHA"

test "$(az rest --method get \
  --url "$AA_BASE/schedules?api-version=2024-10-23" \
  --query 'length(value)' -o tsv)" = "0"
test "$(az rest --method get \
  --url "$AA_BASE/jobSchedules?api-version=2024-10-23" \
  --query 'length(value)' -o tsv)" = "0"

az rest --method get --url "$AA_BASE/jobs?api-version=2024-10-23" \
  --output json > "$EVIDENCE_DIR/jobs.json"
jq -e '
  [.value[] | select(
    .properties.status != "Completed" and
    .properties.status != "Failed" and
    .properties.status != "Stopped" and
    .properties.status != "Suspended"
  )] | length == 0
' "$EVIDENCE_DIR/jobs.json" > /dev/null

scripts/ring-role.sh revoke "$SUB" "$RG" "$PRINCIPAL"
WRITER_GRANTED=false

az role assignment list \
  --subscription "$SUB" \
  --assignee-object-id "$PRINCIPAL" \
  --scope "$RG_SCOPE" \
  --fill-principal-name false \
  --output json > "$EVIDENCE_DIR/final-roles.json"

jq -e --arg scope "$RG_SCOPE" '
  [.[] | select((.scope | ascii_downcase) == ($scope | ascii_downcase))] as $direct
  | ([$direct[] | select(.roleDefinitionName | startswith("Azure Backup Smart Tiering Discovery Reader - "))] | length) == 1
    and ([$direct[] | select(.roleDefinitionName | startswith("Azure Backup Smart Tiering Policy Remediator - "))] | length) == 0
    and ($direct | length) == 1
' "$EVIDENCE_DIR/final-roles.json" > /dev/null

az role definition list \
  --subscription "$SUB" \
  --custom-role-only true \
  --scope "$RG_SCOPE" \
  --output json > "$EVIDENCE_DIR/final-custom-roles.json"
jq -e '
  [.[] | select(.roleName | startswith("Azure Backup Smart Tiering Policy Remediator - "))]
  | length == 0
' "$EVIDENCE_DIR/final-custom-roles.json" > /dev/null

for resource in \
  "Microsoft.Automation/automationAccounts:$AA" \
  "Microsoft.RecoveryServices/vaults:$RG_VAULT" \
  "Microsoft.RecoveryServices/vaults:$SUB_VAULT"
do
  resource_type="${resource%%:*}"
  resource_name="${resource#*:}"
  test "$(az resource show \
    --subscription "$SUB" \
    --resource-group "$RG" \
    --resource-type "$resource_type" \
    --name "$resource_name" \
    --query 'tags.Lifecycle' -o tsv)" = "RetainForInspection"
done

find "$EVIDENCE_DIR" -type f -delete
rmdir "$EVIDENCE_DIR"
trap - EXIT
```

The `diff` must be empty. The writer assignment and its ring role are now gone; leave the RG-scoped
reader assignment so audits and the Portal inspection surface keep working.

## 10. Leave-alive inspection state

Keep these resources alive:

- Automation Account with a system-assigned identity;
- `PowerShell74` runtime and Published `Enable-SmartTiering` runbook;
- two empty Recovery Services vaults and their zero-item canary policies;
- RG-only discovery reader assignment;
- completed audit, apply, and idempotent job history.

Keep these absent:

- policy-remediator writer assignment;
- Automation schedules or job schedules;
- protected backup items, VMs, public IPs, credentials, and secrets.

Use [inspection-guide.md](inspection-guide.md) for the Portal walk-through. Do not publish raw Portal
links or output copied from this deployment; they contain subscription, resource, principal, and job
identifiers.

## 11. Optional teardown

Do not run this section while using the shared RG from the combined Policy + Automation showcase;
follow the canonical guide's coordinated cleanup order instead. For a dedicated Automation-only RG:

```bash
DELETE_RG_ID="$(az group show --subscription "$SUB" --name "$RG" --query id -o tsv)"
DELETE_RG_PURPOSE="$(az group show --subscription "$SUB" --name "$RG" --query 'tags.Purpose' -o tsv)"
test "$(printf '%s' "$DELETE_RG_ID" | tr '[:upper:]' '[:lower:]')" = \
  "$(printf '%s' "$RG_SCOPE" | tr '[:upper:]' '[:lower:]')"
test "$DELETE_RG_PURPOSE" = "SmartTieringLiveDemo"

scripts/ring-role.sh revoke "$SUB" "$RG" "$PRINCIPAL"
scripts/discovery-role.sh revoke "$SUB" "$RG" "$PRINCIPAL"

az group delete --subscription "$SUB" --name "$RG" --yes --no-wait
```

The fixture has zero protected items, but deletion is still an explicit operator choice.
