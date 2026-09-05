# Replicate this in Azure — step by step

This runbook builds a new empty Azure Backup Smart Tiering canary, proves the audit and bounded
write paths, removes temporary writer access, and leaves the read-only showcase alive. It contains
no tenant-specific identifiers. For the full Azure Policy + Azure Automation showcase, start with
the [canonical combined guide](https://github.com/kevo099/azure-enterprise-policy-baseline/blob/main/docs/REPLICATE-POLICY-AUTOMATION.md).

The fixture contains no protected items. It proves the control-plane path; it does not move a
recovery point into archive storage. Read [gotchas.md](gotchas.md) before the first `Apply=true`.

## Before you start

Use this page for **Backup Smart Tiering alone**. The combined guide linked above owns the
shared Policy + Automation resource group; do not run both creation procedures against that group.
Allow time for deployment, job startup, and RBAC propagation. A reader-readiness window and a
writer-apply window each allow up to 15 minutes. Resources remain in Azure at the end; this guide
creates no spending cap or automatic teardown.

| Stage | What you do | Checkpoint before continuing |
|---|---|---|
| 0 | Prepare Linux tools, pin source, choose subscription | Offline checks pass; account and names are correct |
| 1–3 | Create empty fixture, publish runbook, define helpers | Published content hash matches; recovery values saved |
| 4 | Optional audit without reader | Failed job, with its cause in the Error stream |
| 5–6 | Prove reader readiness; seed exact empty policy; audit | One candidate, zero submitted/verified writes |
| 7 | Optional apply with reader only | Failed write with 403; policy remains unchanged |
| 8–9 | Grant temporary writer, apply, repeat, remove writer | One verified change; repeat writes zero; writer absent |
| 10–11 | Inspect retained resources or explicitly tear down | Reader-only inspection state or confirmed RG deletion |

Run numbered steps in order, one complete fenced block at a time. Stop at the first failed check;
a silent `test` or `jq -e` success means its condition passed. Do not paste this whole document into
a shell: it contains optional negative tests and a destructive teardown. If a terminal closes,
use [Recovery and troubleshooting](#recovery-and-troubleshooting) before repeating anything.

## 0. Prerequisites and source pin

- A **Linux Bash session**, including Ubuntu under WSL on Windows. Native macOS Bash and Windows
  PowerShell are not sufficient: the role helpers read `/proc/sys/kernel/random/uuid` and use GNU
  tools. PowerShell below runs only the local harness; the command blocks themselves are Bash.
- Git, Bash 4 or newer, `curl`, `jq`, GNU coreutils (`sha256sum` and `sort -V`), Azure CLI 2.75.0 or
  newer, Bicep, and the experimental `automation` extension version `1.0.0b2`.
- PowerShell **7.4** locally for the offline harness. This is separate from the Azure Automation
  `PowerShell74` runtime, which the fixture creates for you. No local Az modules are required.
- A commercial Azure subscription with permission to create the new resource group at subscription
  scope, for example Contributor at that scope. Contributor only on an existing group cannot create
  this new group. Resource deployment and runbook publication need Contributor on the canary group.
- Owner or User Access Administrator on the canary group for **both custom-role definitions and
  assignments**, including revocation. Arrange this before Step 5 and retain it through Step 9.
  Contributor cannot write RBAC. Role Based Access Control Administrator alone can manage assignments
  but does not include `roleDefinitions/write`. See Microsoft's
  [custom-role permissions](https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles#who-can-create-delete-update-or-view-a-custom-role)
  and [built-in role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/privileged).
- Permission to register Azure resource providers at subscription scope, or a platform owner who
  registers them before the canary deployment.
- A region with Automation Account quota. If a fresh deployment fails on quota, inspect and remove
  that incomplete resource group before starting again in another region; do not update it in place.

If tools are missing, first follow Microsoft's [Azure CLI installation](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux)
and [PowerShell installation](https://learn.microsoft.com/en-us/powershell/scripting/install/install-ubuntu)
instructions for your Linux distribution; select PowerShell 7.4. On Ubuntu/WSL, the other packages
are `git`, `curl`, `jq`, and `coreutils` (`sudo apt-get install git curl jq coreutils`).

Start a dedicated Bash shell so a failing check exits this walkthrough session. Keep your existing
terminal open; do not enable shell tracing (`set -x`) while running authenticated commands.

```bash
bash --noprofile --norc
```

In that new shell, check the tools and install the local CLI components. These setup commands do
not deploy Azure resources. `az bicep install` is documented in the
[Bicep setup guide](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install).

```bash
set -euo pipefail
umask 077

test "${BASH_VERSINFO[0]}" -ge 4
test -r /proc/sys/kernel/random/uuid
for tool in git curl jq sha256sum sort az pwsh; do command -v "$tool"; done
AZ_CLI_VERSION="$(az version --query '"azure-cli"' -o tsv)"
test "$(printf '%s\n' 2.75.0 "$AZ_CLI_VERSION" | sort -V | head -1)" = "2.75.0"
pwsh -NonInteractive -NoProfile -Command 'if ($PSVersionTable.PSVersion.Major -ne 7 -or $PSVersionTable.PSVersion.Minor -ne 4) { throw "Use PowerShell 7.4 for this harness" }; $PSVersionTable.PSVersion.ToString()'
az bicep install
az bicep version
az extension add --name automation --version 1.0.0b2 --upgrade --yes
test "$(az extension show --name automation --query version -o tsv)" = "1.0.0b2"

EVIDENCE_ROOT="$HOME/.local/state/azure-backup-replication"
mkdir -p "$EVIDENCE_ROOT"
EVIDENCE_DIR="$(mktemp -d "$EVIDENCE_ROOT/run.XXXXXXXX")"
printf 'Private evidence directory: %s\n' "$EVIDENCE_DIR"

git clone https://github.com/kevo099/azure-backup-smart-tiering-automation.git
cd azure-backup-smart-tiering-automation
AUTOMATION_DIR="$(pwd)"
cp docs/replicate-in-azure.md "$EVIDENCE_DIR/guide-used.md"
git rev-parse HEAD > "$EVIDENCE_DIR/guide-revision.txt"
AUTOMATION_COMMIT="1abbdcc066d58d9fb765d78fff3763ee34acf97a"
git checkout --detach "$AUTOMATION_COMMIT"
test "$(git rev-parse HEAD)" = "$AUTOMATION_COMMIT"
printf '%s\n' "$AUTOMATION_COMMIT" > "$EVIDENCE_DIR/source-revision.txt"

pwsh -NonInteractive -NoProfile -File tests/StaticValidation.ps1
pwsh -NonInteractive -NoProfile -File tests/BehaviorHarness.ps1
for file in scripts/*.sh; do bash -n "$file"; done
bash tests/ReplicationGuideTrapTest.sh
jq empty infra/rbac/*.json
az bicep build --file infra/test-environment.bicep --stdout > /dev/null
```

**Checkpoint:** the static check and all 45 behavioral scenarios pass; the trap regression passes;
Bicep and JSON validation exit successfully. A detached-HEAD notice is expected. Keep following this
page or `$EVIDENCE_DIR/guide-used.md`: checkout pins the deployment code and also replaces on-disk
docs with their older versions. Do not switch to an older guide and follow its earlier source pin.
An existing clone directory causes `git clone` to fail; choose a fresh parent directory and restart
Step 0 instead of repurposing a working checkout.

Sign in, explicitly select the intended tenant and subscription, then define local-only names.
Replace the three angle-bracket values. Use 4–12 lowercase letters/digits for the suffix; keep it
unique to this run. `centralus` is an example, subject to your subscription's quota and policy.
If the login cannot open a browser, use `az login --tenant "$TENANT_ID" --use-device-code` instead.

```bash
TENANT_ID="<tenant-id>"
SUB="<subscription-id>"
SUFFIX="<unique-short-suffix>"
[[ "$TENANT_ID" != *'<'* && "$SUB" != *'<'* ]]
[[ "$SUFFIX" =~ ^[a-z0-9]{4,12}$ ]]
az login --tenant "$TENANT_ID"
az account list --query '[].{name:name,id:id,tenantId:tenantId}' -o table
az account set --subscription "$SUB"
test "$(az cloud show --query name -o tsv)" = "AzureCloud"
test "$(az account show --query id -o tsv)" = "$SUB"
test "$(az account show --query tenantId -o tsv)" = "$TENANT_ID"
az account show --query '{name:name,id:id,tenantId:tenantId}' -o table

REGION="centralus"
RG="rg-smart-tiering-$SUFFIX"
AA="aa-smart-tiering-$SUFFIX"
RG_VAULT="rsv-smarttier-rg-$SUFFIX"
SUB_VAULT="rsv-smarttier-sub-$SUFFIX"
POLICY="smart-tiering-remediation-canary"
ARM="https://management.azure.com"
RG_SCOPE="/subscriptions/$SUB/resourceGroups/$RG"

# Bash-escaped values only: no credentials, access tokens, or shell history.
for variable in TENANT_ID SUB REGION RG AA RG_VAULT SUB_VAULT POLICY ARM RG_SCOPE \
  AUTOMATION_DIR AUTOMATION_COMMIT EVIDENCE_DIR; do
  printf '%s=%q\n' "$variable" "${!variable}"
done > "$EVIDENCE_DIR/session-values.sh"
printf 'Chosen region=%s resource-group=%s account=%s\n' "$REGION" "$RG" "$AA"
```

**Checkpoint:** inspect the displayed subscription, tenant, and resource names before continuing.
Run every subsequent command block in this same Bash session from `$AUTOMATION_DIR`. Private
records stay outside the repository. Keep the printed evidence path for recovery; do not commit
raw job output, resource IDs, principal IDs, or rendered role definitions.

## 1. Deploy the fresh fixture once

Create a new resource group, prove it is empty, then deploy the safe compliant fixture. Set
`retainForInspection=true` so its tags describe the intended leave-alive lifecycle.

```bash
for provider in Microsoft.Authorization Microsoft.Automation Microsoft.RecoveryServices; do
  if [ "$(az provider show --subscription "$SUB" --namespace "$provider" \
    --query registrationState -o tsv)" != "Registered" ]; then
    az provider register --subscription "$SUB" --namespace "$provider" --wait --only-show-errors
  fi
  test "$(az provider show --subscription "$SUB" --namespace "$provider" \
    --query registrationState -o tsv)" = "Registered"
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
printf 'PRINCIPAL=%q\n' "$PRINCIPAL" >> "$EVIDENCE_DIR/session-values.sh"
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
scripts/publish-runbook.sh | tee "$EVIDENCE_DIR/publication.txt"
printf 'EXPECTED_RUNBOOK_SHA=%q\n' "$EXPECTED_RUNBOOK_SHA" >> "$EVIDENCE_DIR/session-values.sh"
```

The script discovers the Automation Account location unless `LOCATION` is explicitly supplied. It
must print `remote state/runtime: Published PowerShell74` and `OK: published bytes equal the local
file`. Record the printed SHA-256 with the source commit.

## 3. Job helpers

The experimental CLI can start and inspect jobs but does not expose their output. Paste this entire
block once; it defines functions and installs the writer-cleanup trap without starting a job.
The helpers use the Automation REST API for terminal status, output, and stream summaries:

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
  local deadline="${2:-$(( $(date +%s) + 1200 ))}"
  while [ "$(date +%s)" -lt "$deadline" ]; do
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
  trap - EXIT
  if [ "$WRITER_GRANTED" = true ]; then
    if ! "$AUTOMATION_DIR/scripts/ring-role.sh" revoke "$SUB" "$RG" "$PRINCIPAL"; then
      printf 'Automatic writer-role revocation failed; revoke it manually now\n' >&2
      exit 1
    fi
  fi
  exit "$original_status"
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

single_summary() {
  local output_file="$1" count
  count="$(grep -c '^SUMMARY ' "$output_file" || true)"
  if [ "$count" != "1" ]; then
    printf 'Expected exactly one SUMMARY line in %s; found %s\n' "$output_file" "$count" >&2
    return 1
  fi
  sed -n 's/^SUMMARY //p' "$output_file"
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

Role-assignment visibility is not proof that the managed identity can use the role. Before any
seed, prove the exact canary is still empty and `TierRecommended`, then run read-only exact-name
audits until one completes with the precise already-compliant result. Failed readiness jobs are
safe to retry because `Apply=false` cannot submit a PUT; a timed-out job or an unexpected completed
result stops the procedure. The single deadline bounds the entire readiness window.

```bash
POLICY_ID="$RG_SCOPE/providers/Microsoft.RecoveryServices/vaults/$RG_VAULT/backupPolicies/$POLICY"
POLICY_URL="$ARM$POLICY_ID?api-version=2025-08-01"

az rest --method get --url "$POLICY_URL" > "$EVIDENCE_DIR/reader-initial.json"
jq -e '
  .properties.protectedItemsCount == 0 and
  .properties.tieringPolicy.ArchivedRP.tieringMode == "TierRecommended"
' "$EVIDENCE_DIR/reader-initial.json" > /dev/null

READER_READY=false
READER_ATTEMPT=0
READER_DEADLINE="$(( $(date +%s) + 900 ))"
while [ "$(date +%s)" -lt "$READER_DEADLINE" ]; do
  READER_ATTEMPT="$((READER_ATTEMPT + 1))"
  READER_JOB="$(start_job false)"
  if ! READER_STATUS="$(wait_job "$READER_JOB" "$READER_DEADLINE")"; then
    printf 'Reader readiness job did not reach a terminal state before the deadline\n' >&2
    exit 1
  fi
  READER_OUTPUT="$EVIDENCE_DIR/reader-ready-$READER_ATTEMPT.output"
  job_output "$READER_JOB" > "$READER_OUTPUT"
  case "$READER_STATUS" in
    Completed)
      READER_SUMMARY="$(single_summary "$READER_OUTPUT")"
      printf '%s\n' "$READER_SUMMARY" | jq -e '
        .policiesMatched == 1 and
        .candidates == 0 and
        .writesSubmitted == 0 and
        .policiesWritten == 0 and
        .writesFailed == 0 and
        .writesUnknown == 0 and
        .errors == 0 and
        .abortReason == null
      ' > /dev/null
      test "$(grep -c '"action":"AlreadyCompliant"' "$READER_OUTPUT" || true)" = "1"
      READER_READY=true
      break
      ;;
    Failed)
      sleep 15
      ;;
    *)
      printf 'Unexpected reader readiness state: %s\n' "$READER_STATUS" >&2
      exit 1
      ;;
  esac
done
test "$READER_READY" = true
```

Only after that managed-identity read succeeds, fetch the exact policy again, require zero protected
items, construct a write payload without read-only members, and change only the archive-tier block
to `DoNotTier`. This direct seed is an operator action on the empty canary; it does not use the
Automation writer.

```bash
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

AUDIT_SUMMARY="$(single_summary "$EVIDENCE_DIR/audit.output")"
printf '%s\n' "$AUDIT_SUMMARY" | jq -e '
  .policiesMatched == 1 and
  .candidates == 1 and
  .writesSubmitted == 0 and
  .policiesWritten == 0 and
  .writesFailed == 0 and
  .writesUnknown == 0 and
  .errors == 0 and
  .abortReason == null
' > /dev/null
test "$(grep -c '"action":"WouldEnableTierRecommended"' "$EVIDENCE_DIR/audit.output" || true)" = "1"
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

Complete Steps 8 and 9 in one sitting. Keep your own RG-level RBAC administration authority active
until writer revocation finishes. If interrupted, follow the recovery section; an EXIT trap cannot
run after a machine crash or a forcibly killed shell.

The grant helper rolls back only artifacts it created if propagation prevents a
complete grant. Activate the outer EXIT cleanup immediately after it succeeds:

```bash
scripts/ring-role.sh grant "$SUB" "$RG" "$PRINCIPAL"
WRITER_GRANTED=true
```

Assignment visibility does not prove write authorization has propagated. Run the exact-name apply
under one 15-minute deadline. A retry is allowed only when the failed job has exactly one valid
summary, its counters prove one definitive rejected write and no unknown write, its sole error row
is a write-stage HTTP 403/Forbidden/AuthorizationFailed response, and a direct policy read plus a
fresh audit prove the policy is still `DoNotTier` and still the one intended candidate. Any other
terminal state or output shape stops immediately.

```bash
APPLY_SUCCEEDED=false
APPLY_ATTEMPT=0
WRITER_DEADLINE="$(( $(date +%s) + 900 ))"
while [ "$(date +%s)" -lt "$WRITER_DEADLINE" ]; do
  APPLY_ATTEMPT="$((APPLY_ATTEMPT + 1))"
  APPLY_JOB="$(start_job true ExpectedMatches=1 MaxChanges=1 MaxProtectedItemsPerPolicy=0)"
  if ! APPLY_STATUS="$(wait_job "$APPLY_JOB" "$WRITER_DEADLINE")"; then
    printf 'Apply job did not reach a terminal state before the writer deadline\n' >&2
    exit 1
  fi
  APPLY_OUTPUT="$EVIDENCE_DIR/apply-$APPLY_ATTEMPT.output"
  job_output "$APPLY_JOB" | tee "$APPLY_OUTPUT"
  APPLY_SUMMARY="$(single_summary "$APPLY_OUTPUT")"

  case "$APPLY_STATUS" in
    Completed)
      if ! printf '%s\n' "$APPLY_SUMMARY" | jq -e '
        .policiesMatched == 1 and
        .candidates == 1 and
        .writesSubmitted == 1 and
        .policiesWritten == 1 and
        .writesFailed == 0 and
        .writesUnknown == 0 and
        .writesSkipped == 0 and
        .errors == 0 and
        .abortReason == null
      ' > /dev/null; then
        printf 'Completed apply had an unexpected summary; refusing to continue\n' >&2
        exit 1
      fi
      test "$(grep -c '"action":"EnabledAndVerified"' "$APPLY_OUTPUT" || true)" = "1"
      APPLY_SUCCEEDED=true
      break
      ;;
    Failed)
      if ! printf '%s\n' "$APPLY_SUMMARY" | jq -e '
        .policiesMatched == 1 and
        .candidates == 1 and
        .writesSubmitted == 1 and
        .policiesWritten == 0 and
        .writesFailed == 1 and
        .writesUnknown == 0 and
        .writesSkipped == 0 and
        .errors == 1 and
        .abortReason == null
      ' > /dev/null; then
        printf 'Failed apply was not the qualified authorization-only shape\n' >&2
        exit 1
      fi
      if ! jq -s -e '
        [.[] | select(.action == "Error")] as $errors
        | ($errors | length) == 1 and
          $errors[0].stage == "Write" and
          (($errors[0].message // "") | test("HTTP 403|Forbidden|AuthorizationFailed"; "i"))
      ' < <(sed -n '/^{/p' "$APPLY_OUTPUT") > /dev/null; then
        printf 'Failed apply did not contain exactly one writer-authorization error\n' >&2
        exit 1
      fi

      az rest --method get --url "$POLICY_URL" > "$EVIDENCE_DIR/pre-retry-$APPLY_ATTEMPT.json"
      jq -e '
        .properties.protectedItemsCount == 0 and
        .properties.tieringPolicy.ArchivedRP.tieringMode == "DoNotTier"
      ' "$EVIDENCE_DIR/pre-retry-$APPLY_ATTEMPT.json" > /dev/null

      RETRY_AUDIT_JOB="$(start_job false)"
      if ! RETRY_AUDIT_STATUS="$(wait_job "$RETRY_AUDIT_JOB" "$WRITER_DEADLINE")"; then
        printf 'Pre-retry audit did not reach a terminal state before the writer deadline\n' >&2
        exit 1
      fi
      test "$RETRY_AUDIT_STATUS" = "Completed"
      RETRY_AUDIT_OUTPUT="$EVIDENCE_DIR/pre-retry-audit-$APPLY_ATTEMPT.output"
      job_output "$RETRY_AUDIT_JOB" > "$RETRY_AUDIT_OUTPUT"
      RETRY_AUDIT_SUMMARY="$(single_summary "$RETRY_AUDIT_OUTPUT")"
      printf '%s\n' "$RETRY_AUDIT_SUMMARY" | jq -e '
        .policiesMatched == 1 and
        .candidates == 1 and
        .writesSubmitted == 0 and
        .policiesWritten == 0 and
        .writesFailed == 0 and
        .writesUnknown == 0 and
        .errors == 0 and
        .abortReason == null
      ' > /dev/null
      test "$(grep -c '"action":"WouldEnableTierRecommended"' "$RETRY_AUDIT_OUTPUT" || true)" = "1"
      sleep 15
      ;;
    *)
      printf 'Unexpected apply terminal state: %s\n' "$APPLY_STATUS" >&2
      exit 1
      ;;
  esac
done
test "$APPLY_SUCCEEDED" = true

REPEAT_JOB="$(start_job true ExpectedMatches=1 MaxChanges=1 MaxProtectedItemsPerPolicy=0)"
test "$(wait_job "$REPEAT_JOB")" = "Completed"
job_output "$REPEAT_JOB" | tee "$EVIDENCE_DIR/repeat.output"

REPEAT_SUMMARY="$(single_summary "$EVIDENCE_DIR/repeat.output")"
printf '%s\n' "$REPEAT_SUMMARY" | jq -e '
  .policiesMatched == 1 and
  .candidates == 0 and
  .writesSubmitted == 0 and
  .policiesWritten == 0 and
  .writesFailed == 0 and
  .writesUnknown == 0 and
  .errors == 0 and
  .abortReason == null
' > /dev/null
test "$(grep -c '"action":"AlreadyCompliant"' "$EVIDENCE_DIR/repeat.output" || true)" = "1"
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

DISCOVERY_ROLE_SUFFIX="$(printf '%s' "$RG_SCOPE" | sha256sum | cut -c1-12)"
DISCOVERY_ROLE_NAME="Azure Backup Smart Tiering Discovery Reader - $DISCOVERY_ROLE_SUFFIX"
sed \
  -e "s#<subscription-id>#$SUB#" \
  -e "s#<ring-resource-group>#$RG#" \
  -e "s#<role-suffix>#$DISCOVERY_ROLE_SUFFIX#" \
  infra/rbac/discovery-reader-rg-role.template.json \
  > "$EVIDENCE_DIR/final-discovery-role-expected.json"

az role assignment list \
  --subscription "$SUB" \
  --assignee-object-id "$PRINCIPAL" \
  --scope "$RG_SCOPE" \
  --fill-principal-name false \
  --output json > "$EVIDENCE_DIR/final-roles.json"

jq -e --arg scope "$RG_SCOPE" --arg reader "$DISCOVERY_ROLE_NAME" '
  [.[] | select((.scope | ascii_downcase) == ($scope | ascii_downcase))] as $direct
  | ([$direct[] | select(.roleDefinitionName == $reader)] | length) == 1
    and ([$direct[] | select(.roleDefinitionName | startswith("Azure Backup Smart Tiering Policy Remediator - "))] | length) == 0
    and ($direct | length) == 1
' "$EVIDENCE_DIR/final-roles.json" > /dev/null

az role definition list \
  --subscription "$SUB" \
  --custom-role-only true \
  --scope "$RG_SCOPE" \
  --output json > "$EVIDENCE_DIR/final-custom-roles.json"
jq -e \
  --arg reader "$DISCOVERY_ROLE_NAME" \
  --arg scope "$RG_SCOPE" \
  --slurpfile expected "$EVIDENCE_DIR/final-discovery-role-expected.json" '
  $expected[0] as $e
  | [.[] | select(.roleName == $reader)] as $reader_roles
  | ([$reader_roles[] | select(
      (.description == $e.Description) and
      ((.assignableScopes // [] | map(ascii_downcase) | sort) == [($scope | ascii_downcase)]) and
      ((.permissions // []) | length == 1) and
      ((.permissions[0].actions // [] | map(ascii_downcase) | sort) == ($e.Actions | map(ascii_downcase) | sort)) and
      ((.permissions[0].notActions // [] | map(ascii_downcase) | sort) == ($e.NotActions | map(ascii_downcase) | sort)) and
      ((.permissions[0].dataActions // [] | map(ascii_downcase) | sort) == ($e.DataActions | map(ascii_downcase) | sort)) and
      ((.permissions[0].notDataActions // [] | map(ascii_downcase) | sort) == ($e.NotDataActions | map(ascii_downcase) | sort))
    )] | length) == 1 and
    ($reader_roles | length) == 1 and
    ([.[] | select(.roleName | startswith("Azure Backup Smart Tiering Policy Remediator - "))] | length) == 0
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

trap - EXIT
printf 'PASS: verified apply, idempotent repeat, and writer removal. Evidence retained at %s\n' "$EVIDENCE_DIR"
```

The `diff` must be empty. The writer assignment and its ring role are now gone; leave the RG-scoped
reader assignment so audits and the Portal inspection surface keep working. Keep the private
source/guide revisions, published hash, pre/post policy documents, and job output for your change
record. Delete that local evidence only after your own retention needs are met; it is not required
for the retained Azure resources to operate.

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

az resource list --subscription "$SUB" --resource-group "$RG" \
  --query '[].{name:name,type:type}' -o table
for vault in "$RG_VAULT" "$SUB_VAULT"; do
  test "$(az backup item list --subscription "$SUB" --resource-group "$RG" \
    --vault-name "$vault" --query 'length(@)' -o tsv)" = "0"
done
```

**Checkpoint:** the inventory must contain only this walkthrough's Automation account and two
vaults, plus their child resources. If anything has been added, stop and identify its owner before
proceeding. Both item-count assertions must pass. For a failed deployment where a resource never
existed, inspect the partial inventory first; do not treat a failed lookup as an empty vault.

```bash
scripts/ring-role.sh revoke "$SUB" "$RG" "$PRINCIPAL"
scripts/discovery-role.sh revoke "$SUB" "$RG" "$PRINCIPAL"

az group delete --subscription "$SUB" --name "$RG" --yes --no-wait
```

`--no-wait` accepts the deletion request; it does not prove that deletion finished. Complete this
check before calling the teardown done:

```bash
az group wait --subscription "$SUB" --name "$RG" --deleted --interval 15 --timeout 1800
test "$(az group exists --subscription "$SUB" --name "$RG")" = "false"
```

The fixture has zero protected items, but deletion is still an explicit operator choice. If deletion
fails, inspect the group's Activity log and any locks or protected/soft-deleted backup items. Do not
force-remove protections from a vault that someone has since started using.

## Recovery and troubleshooting

On a failed assertion, read the command immediately above the failure and keep the evidence.
The EXIT trap attempts writer revocation only when the grant step completed in this session;
it does not stop an Azure job or cancel a submitted policy update. A timed-out or interrupted apply
therefore needs direct policy inspection before any retry.

If the shell has closed, open a fresh Linux Bash session. Replace the evidence directory below with
the path printed in Step 0. Source only the `session-values.sh` that this walkthrough generated and
that you own; it is executable shell text. This block restores identifiers, inspects the exact
resource group, and removes the temporary writer. It does not resume deployment or apply.

```bash
set -euo pipefail
umask 077
EVIDENCE_DIR="<absolute-path-to-your-private-run-directory>"
test -r "$EVIDENCE_DIR/session-values.sh"
source "$EVIDENCE_DIR/session-values.sh"
cd "$AUTOMATION_DIR"
test "$(git rev-parse HEAD)" = "$AUTOMATION_COMMIT"
az login --tenant "$TENANT_ID"
az account set --subscription "$SUB"
test "$(az account show --query tenantId -o tsv)" = "$TENANT_ID"
az group show --subscription "$SUB" --name "$RG" \
  --query '{name:name,id:id,tags:tags}' -o json

PRINCIPAL="$(az automation account show --subscription "$SUB" --resource-group "$RG" \
  --name "$AA" --query identity.principalId -o tsv)"
test -n "$PRINCIPAL"
scripts/ring-role.sh revoke "$SUB" "$RG" "$PRINCIPAL"
```

If failure occurred before the account existed, the principal lookup fails and no writer could have
been granted by these steps. Inspect the incomplete deployment before choosing a new resource group.
If revocation fails, the account's writer might remain: have the RG Owner/User Access Administrator
run the exact `revoke` command with the saved values and verify its success before continuing.

Re-paste Step 3 to restore the read-only job helpers. Inspect **Automation Account → Jobs** for the
last attempt; for a recorded job name, `job_streams "$APPLY_JOB"` and `job_output "$APPLY_JOB"` expose
its cause (set `APPLY_JOB` from the Portal if the session lost it). Do not restart a nonterminal job.
If you deliberately stop it through the Portal, wait for a terminal state and inspect the exact
policy afterward: stopping the job does not undo an accepted ARM write.

| Symptom | Next step |
|---|---|
| `command not found`, wrong PowerShell, missing `/proc` | Finish Step 0 on Linux/WSL before any Azure work. |
| Subscription/tenant check fails | Correct the two values and sign in to that tenant; do not remove the assertions. |
| Deployment quota/region failure | Inspect **Resource group → Deployments → failed deployment → Operation details**. Remove only this incomplete empty fixture through the guarded teardown, then restart with fresh names. If the Automation Account never existed, skip the two role-revoke commands after confirming no grant step ran. |
| `AuthorizationFailed` on role definition or assignment | Check the operation named by the error and the operator's active RG permissions. Contributor and assignment-only RBAC authority cannot create custom roles. Keep the grant helper's rollback output. |
| Publish exits without the expected hash message | Inspect the runbook draft/state and the local publication log. The pinned publisher suppresses some CLI errors; rerun the failing individual CLI command from `scripts/publish-runbook.sh` without its stderr redirection to see the cause. Do not start jobs until hash verification succeeds. |
| Failed job has no `SUMMARY` | Read its Error stream; initialization/validation can fail before summaries. Step 4 deliberately expects failure, and Step 5 permits failed read-only readiness jobs within its deadline. Elsewhere, investigate before continuing. |
| Reader/apply deadline expires, `writesUnknown > 0`, or seed polling fails | Revoke writer access, wait for the job/ARM operation to settle, and GET the exact policy. Compare non-tiering properties with `pre.json`. Do not rerun the full fixture or blindly repeat the seed/apply. |
| An unexpected `test`/`jq` failure | Keep the relevant JSON/output file and inspect it locally with `jq .`. Its difference from the required condition is the reason to stop. |

For an interrupted canary, restore the exact `POLICY_ID`/`POLICY_URL` assignments at the start of
Step 5 and GET that URL into a new private evidence file. Compare it with the saved `pre.json` using
Step 9's non-tiering comparison. `TierRecommended` with unchanged non-tiering properties can proceed
to read-only inspection after the job is terminal; it does not by itself prove that the interrupted
apply passed. `DoNotTier` with those properties unchanged can restart at Step 6 after restoring
Step 3's helpers. A changed protected-item count, an unknown tiering mode, missing evidence, or
non-tiering drift needs operator investigation. This guide has no generic policy rollback: the safe end state is the initial
`TierRecommended` on the same empty policy, proven by the saved pre/post comparison.
