# Azure Backup Smart Tiering automation

An audit-first Azure Automation runbook that finds Azure VM backup policies where Vault Archive
Smart Tiering is missing or disabled and enables `TierRecommended` without changing schedule,
retention or tags. Version 1.1 adds the guards that an adversarial review of 1.0 found missing:
an archive-eligibility gate, per-policy error isolation, a fail-closed apply contract, terminal
tracking of the asynchronous update, and full post-write verification.

> **Status:** 1.1 is live-qualified on the same empty-canary fixture as 1.0 (2026-08-25: unfiltered
> audit, `DoNotTier` → `TierRecommended` apply, idempotent repeat, and every fail-closed guard) and is
> validated offline by a 45-scenario behavioural harness that executes the real runbook against a
> mocked ARM transport. See [CHANGELOG.md](CHANGELOG.md) and [docs/validation.md](docs/validation.md) for exactly
> what has and has not been proven live.

## What it changes

Smart Tiering is configured on each Recovery Services vault child backup policy — not on the vault:

```text
Microsoft.RecoveryServices/vaults/backupPolicies
```

For Azure VM policies the intended change is:

```json
{
  "tieringPolicy": {
    "ArchivedRP": {
      "tieringMode": "TierRecommended"
    }
  }
}
```

| Policy state | Audit result | Apply behaviour |
|---|---|---|
| Not an Azure VM policy (SQL, SAP HANA, files) | `SkippedUnsupportedWorkload` | No write |
| Vault is zone-redundant | `SkippedZoneRedundantVault` | No write (archive tier is unsupported on ZRS) |
| `TierRecommended` | `AlreadyCompliant` | No write |
| `TierAfter` | `AlreadyEnabledAlternateMode` | Preserved; no write |
| Unknown / `Invalid` mode | `SkippedUnknownMode` | No write |
| No monthly/yearly retention of at least `MinimumRetentionMonths` (9) | `SkippedNoArchiveEligibility` | No write — nothing in the policy can ever reach the archive tier |
| Protected-item count missing from the API response | `SkippedProtectedItemsUnknown` | No write — fail closed |
| Protects more items than `MaxProtectedItemsPerPolicy` (0) | `SkippedProtectedItemsExceedLimit` | No write until the limit is raised deliberately |
| Protects items and the API returned no ETag | `SkippedNoConcurrencyToken` | No write unless `AllowWriteWithoutETag=true` |
| Missing or `DoNotTier`, eligible | `WouldEnableTierRecommended` | Set `TierRecommended`, follow the operation, verify → `EnabledAndVerified` |

Writes are only attempted with `Apply=true`, and only after the whole scope has been classified
and the preflight guards (below) pass. A vault whose storage redundancy cannot be read is reported
as an error and its policies are not evaluated; any discovery error aborts an apply run before the
first write.

## Why this exists

Azure provides a Portal control and the `Set-AzRecoveryServicesBackupProtectionPolicy` cmdlet, but
no field-level Smart Tiering `PATCH`, vault-wide switch, built-in Azure Policy remediation, or
dedicated CLI flag for existing policies. REST and CLI updates operate on a complete backup policy,
and modifying a policy that protects items re-applies it to every one of those items.

This runbook adds the orchestration needed to do that safely for one policy at a time, or for a
bounded, reviewed set:

- system-assigned managed-identity authentication (no Az modules, no secrets);
- audit-only by default;
- exact vault and policy filters that fail closed (a blank or misspelled filter never widens scope);
- eligibility, protected-item and change-count guards evaluated before the first write;
- fresh reads before mutation and a structural pre-write comparison;
- the asynchronous update followed to a terminal state;
- tags preserved and every non-tiering property verified after the write;
- per-policy error isolation and honest write accounting (submitted / verified / failed / unknown);
- idempotent repeat execution.

## Repository contents

```text
src/Enable-SmartTiering.ps1              Azure Automation runbook (1.1)
infra/test-environment.bicep              Empty two-vault canary fixture
infra/rbac/*.template.json                Portable custom-role definitions
tests/StaticValidation.ps1                Parser and safety-marker checks
tests/BehaviorHarness.ps1                 Behavioural harness: real runbook + mocked ARM (45 scenarios)
scripts/publish-runbook.sh                Publish + link runtime + fetch-back hash check (release pipeline safe)
scripts/ring-role.sh                      Grant / revoke the ring-scoped policy remediator role
docs/replicate-in-azure.md                Step-by-step replication with the checkpoint expected at each step
docs/gotchas.md                           Everything that bit us — read before the first Apply=true
docs/design-and-limitations.md            Method comparison, limitations, hardening status
docs/validation.md                        Sanitised live-test evidence (1.0) and 1.1 verification
docs/inspection-guide.md                  Azure Portal inspection path
CHANGELOG.md                              What changed in 1.1 and why
.github/workflows/validate.yml            Static checks, harness, PSScriptAnalyzer, RBAC and Bicep CI
```

Raw subscription IDs, principal IDs, role-assignment IDs, job IDs and live Portal links are
intentionally excluded.

> **Replicating this?** Follow [docs/replicate-in-azure.md](docs/replicate-in-azure.md) end to end and read
> [docs/gotchas.md](docs/gotchas.md) first. The sections below are the reference behind those two pages.

## Prerequisites

- An Azure subscription (commercial Azure — the runbook uses `management.azure.com` and the
  public identity audience; sovereign clouds are not supported) where you can create the
  isolated test resources.
- Permission to create an Automation Account, Recovery Services vaults, custom roles and role
  assignments.
- Azure CLI with the `automation` extension.
- A PowerShell 7.4 Runtime Environment in Azure Automation (no packages required).
- A deliberate RBAC and change-approval decision before applying beyond a canary resource group.

```bash
az login
az extension add --name automation --upgrade
```

## Deploy the empty test fixture

Create a **new, empty** resource group, then deploy the Bicep fixture. The deployment is
incremental: if a vault or policy with the same name already exists it will be **overwritten**,
so use names that do not exist anywhere in the subscription.

```bash
az group create \
  --subscription <subscription-id> \
  --name <test-resource-group> \
  --location <azure-region>

# Fails if the group already contains resources.
test "$(az resource list --resource-group <test-resource-group> --query 'length(@)' -o tsv)" = "0"

az deployment group create \
  --subscription <subscription-id> \
  --resource-group <test-resource-group> \
  --template-file infra/test-environment.bicep \
  --parameters \
    resourceGroupScopeVaultName=<rg-canary-vault> \
    subscriptionScopeVaultName=<subscription-canary-vault> \
    automationAccountName=<automation-account> \
    backupPolicyName=smart-tiering-remediation-canary \
    testPolicyTieringMode=TierRecommended \
    retainForInspection=false
```

`testPolicyTieringMode=TierRecommended` is the safe redeploy default: the canary policies start
compliant and an apply run is a no-op. Use the **mutation track** below to seed a real write.

The Bicep file creates the Automation Account, the PowerShell 7.4 runtime environment, two empty
vaults and one canary policy in each vault. It does **not** import the runbook or create RBAC
definitions/assignments. Each new vault also receives service-created default policies
(`DefaultPolicy`, `EnhancedPolicy`, `HourlyLogBackup`); 1.1 classifies the first two as
`SkippedNoArchiveEligibility` because they have no monthly/yearly retention.

## Publish the runbook

```bash
az automation runbook create \
  --subscription <subscription-id> \
  --resource-group <test-resource-group> \
  --automation-account-name <automation-account> \
  --name Enable-SmartTiering \
  --type PowerShell \
  --location <azure-region>

az automation runbook replace-content \
  --subscription <subscription-id> \
  --resource-group <test-resource-group> \
  --automation-account-name <automation-account> \
  --name Enable-SmartTiering \
  --content @src/Enable-SmartTiering.ps1

az automation runbook publish \
  --subscription <subscription-id> \
  --resource-group <test-resource-group> \
  --automation-account-name <automation-account> \
  --name Enable-SmartTiering
```

Link the runbook to the `PowerShell74` runtime environment (the Portal, or the Automation ARM API
`PATCH .../runbooks/Enable-SmartTiering?api-version=2024-10-23` with
`{"properties":{"runtimeEnvironment":"PowerShell74"}}`), and record the SHA-256 of the file you
published so the job evidence can be tied to a commit. `scripts/publish-runbook.sh` does all of this in one
go and exits non-zero unless the fetch-back SHA-256 equals your local file:

```bash
SUBSCRIPTION_ID=<sub> RESOURCE_GROUP=<rg> AUTOMATION_ACCOUNT=<account> scripts/publish-runbook.sh
```

## RBAC model

Render the reader template by replacing `REPLACE_WITH_SUBSCRIPTION_ID`, and the remediator template by
replacing `<subscription-id>` and `<ring-resource-group>` (its only assignable scope is that resource
group), then create them with `az role definition create --role-definition @<file>` —
`scripts/ring-role.sh grant|revoke` does the remediator half.

Assign:

- **Azure Backup Smart Tiering Discovery Reader** — at resource-group scope for
  `ScopeType=ResourceGroup` runs; at subscription scope only when you need
  `ScopeType=Subscription` discovery.
- **Azure Backup Smart Tiering Policy Remediator** — only at the resource group that contains the
  policies you intend to change.

Be explicit about what the writer role is: `Microsoft.RecoveryServices/Vaults/backupPolicies/write`
is **full policy-update authority**. Anyone who can publish or start this runbook — or any other
runbook in the same account — can change schedules and retention with the managed identity, which
changes how long recovery points live. The role grants no direct delete action, and `NotActions`
cannot restrict permissions granted by another role. Keep the account dedicated, keep the
assignment narrow, and treat "start runbook" permission as writer-equivalent.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `SubscriptionId` | required | Subscription to scan |
| `ScopeType` | required | `ResourceGroup` or `Subscription` |
| `ResourceGroupName` | | Required for `ResourceGroup`; **rejected** for `Subscription` (1.0 silently ignored it) |
| `VaultName` | | Exact vault name. A whitespace-only value is rejected, never treated as "no filter" |
| `PolicyName` | | Exact policy name, same rules |
| `Apply` | `false` | Audit only unless `true` |
| `AllowUnfilteredApply` | `false` | `Apply=true` without both filters is refused unless this is `true` |
| `AllowWriteWithoutETag` | `false` | A candidate that protects items but has no ETag is skipped (`SkippedNoConcurrencyToken`) unless this is `true` — set it only inside an exclusive change window |
| `MaxChanges` | `1` | Apply aborts before any write if more policies would change |
| `ExpectedMatches` | `0` | If >0, apply aborts unless exactly this many Azure VM policies matched the filters |
| `MaxProtectedItemsPerPolicy` | `0` | Candidates protecting more items are skipped; raise deliberately |
| `MinimumRetentionMonths` | `9` | Eligibility threshold (minimum 9): monthly/yearly retention needed before any recovery point can become archive-eligible (≥3 months age + ≥6 months left). Only `Months`/`Years` units count |
| `OperationTimeoutSeconds` | `600` | Budget for following the asynchronous update (max 1800) |
| `JobTimeBudgetSeconds` | `8400` | No new write starts after this much job time; the job then fails closed with `SkippedJobBudgetExhausted` rows (Azure Automation stops cloud jobs at three hours) |
| `RequestTimeoutSeconds` | `100` | Per-request timeout |
| `ApiVersion` | `2025-08-01` | Recovery Services API version |

Every output row is one JSON object with `timestamp`, `vaultId`, `policyId`, `policyType`,
`protectedItemsCount`, `retentionHorizonMonths`, `previousMode`, `currentMode`, `action`,
`stage`, `operationStatus` and `message`. The last line is `SUMMARY {...}` with `policiesMatched`,
`candidates`, `policiesWritten` (verified), `writesSubmitted`, `writesUnknown`, `writesFailed`,
`writesSkipped`, `errors` and `abortReason`. Null values are emitted as JSON `null`. The job fails when
apply was aborted, when any error occurred, when any write has an unknown outcome, or when the job
time budget stopped it — never silently.

## Run audit first

```bash
az automation runbook start \
  --subscription <subscription-id> \
  --resource-group <test-resource-group> \
  --automation-account-name <automation-account> \
  --name Enable-SmartTiering \
  --parameters \
    SubscriptionId=<subscription-id> \
    ScopeType=ResourceGroup \
    ResourceGroupName=<test-resource-group> \
    VaultName=<rg-canary-vault> \
    PolicyName=smart-tiering-remediation-canary \
    Apply=false
```

Review the job output. Expect exactly one `WouldEnableTierRecommended` row (or `AlreadyCompliant`
after the safe redeploy). Then run the same command with `Apply=true`. With the defaults
(`MaxChanges=1`, `MaxProtectedItemsPerPolicy=0`) the runbook will write at most one empty policy
and fail closed on anything unexpected. Run it a third time and require `policiesWritten=0` and
`AlreadyCompliant`.

For subscription discovery, set `ScopeType=Subscription` and omit `ResourceGroupName`. Audit
freely; applying at subscription scope requires `AllowUnfilteredApply=true` or exact filters and
is still bounded by `MaxChanges`.

No recurring schedule is created by this repository.

## Mutation canary track (`DoNotTier` → `TierRecommended`)

The safe redeploy leaves the canary policies compliant, so an apply run cannot demonstrate a
write. To exercise a real write on an empty policy:

```bash
az deployment group create \
  --subscription <subscription-id> \
  --resource-group <test-resource-group> \
  --template-file infra/test-environment.bicep \
  --parameters \
    resourceGroupScopeVaultName=<rg-canary-vault> \
    subscriptionScopeVaultName=<subscription-canary-vault> \
    automationAccountName=<automation-account> \
    backupPolicyName=smart-tiering-remediation-canary \
    testPolicyTieringMode=DoNotTier
```

Then run audit → apply → apply again as above and expect `WouldEnableTierRecommended` →
`EnabledAndVerified` (`writesSubmitted=1`, `policiesWritten=1`) → `AlreadyCompliant`
(`policiesWritten=0`).

## Teardown

The fixture holds no backup data, so deleting the resource group is safe. Remove the role
assignments and definitions you created if nothing else uses them:

```bash
az role assignment delete --assignee <automation-account-principal-id> --role "Azure Backup Smart Tiering Policy Remediator" --scope /subscriptions/<subscription-id>/resourceGroups/<test-resource-group>
az role assignment delete --assignee <automation-account-principal-id> --role "Azure Backup Smart Tiering Discovery Reader" --scope /subscriptions/<subscription-id>
az group delete --name <test-resource-group> --yes --no-wait
az role definition delete --name "Azure Backup Smart Tiering Policy Remediator"
az role definition delete --name "Azure Backup Smart Tiering Discovery Reader"
```

## What has been validated

- **1.0, live (2026-08-24):** resource-group and subscription audit / apply / idempotence cycles on
  two empty V1 policies; `DoNotTier` → `TierRecommended`; schedule and retention unchanged;
  repeated apply wrote nothing. See [docs/validation.md](docs/validation.md).
- **1.0, live audit (2026-08-25):** an unfiltered resource-group audit selected the
  service-created daily-only `DefaultPolicy` and `EnhancedPolicy` as write candidates — the
  defect that motivated the 1.1 eligibility gate.
- **1.1, offline:** `tests/BehaviorHarness.ps1` runs the real runbook through 45 scenarios
  (classification, filters, guards, pagination, throttling, token refresh, 202 + operation
  tracking, unknown outcomes, byte-stable date strings and tags, structural verification incl.
  sibling tiering members, fail-closed redundancy/protected-item facts, foreign-URL refusal,
  ambiguous-write reconciliation, error isolation).
- **1.1, live (2026-08-25):** unfiltered audit (daily-only defaults skipped as ineligible), `DoNotTier`
  → `TierRecommended` apply with post-write verification, idempotent repeat, and the whitespace /
  unfiltered / misspelled-name guards all failing closed before any write — as an additional runbook in
  the same Automation Account. Details in [docs/validation.md](docs/validation.md).

## Important limitations

- Only empty Azure VM V1/daily policies have been write-tested live. V2/hourly, tagged, and
  policies protecting real workloads need their own canaries before use; the defaults refuse
  protected policies until `MaxProtectedItemsPerPolicy` is raised.
- SQL Server and SAP HANA policies are skipped.
- The API returned no ETag during validation, so concurrency protection is the structural
  pre-write comparison plus an operator-enforced exclusive change window. Do not run two apply
  jobs against the same vault at once.
- The runbook issues no DELETE, but a policy update is re-applied to every item the policy
  protects, and a retention change can shorten recovery-point lifetime — which is why the write is
  verified to change nothing but `ArchivedRP`. Recovery points moved to the archive tier carry a
  180-day early-deletion charge. Enabling Smart Tiering does not
  guarantee immediate recovery-point movement; Azure's archive eligibility rules still apply.
- Resource Guard / MUA can block the update; the runbook reports the denial per policy and
  continues with the next policy.
- Commercial Azure only. Archive-tier region support and per-recovery-point dependency rules are
  Azure's; the eligibility gate only rules out policies that can never qualify.

See [docs/design-and-limitations.md](docs/design-and-limitations.md) for the full list and the
hardening status.

## Local validation

```bash
pwsh -NoProfile -File tests/StaticValidation.ps1
pwsh -NoProfile -File tests/BehaviorHarness.ps1          # exit code 1 on any failed oracle
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path src/Enable-SmartTiering.ps1 -Severity Error,Warning"
jq empty infra/rbac/*.json
az bicep build --file infra/test-environment.bicep --stdout > /dev/null
```

## Official references

- [Use Azure Backup Archive tier and enable Smart Tiering](https://learn.microsoft.com/en-us/azure/backup/use-archive-tier-support)
- [Azure Backup archive support matrix](https://learn.microsoft.com/en-us/azure/backup/archive-tier-support)
- [Backup policy Create or Update REST API (asynchronous)](https://learn.microsoft.com/en-us/rest/api/backup/protection-policies/create-or-update)
- [Track asynchronous Azure operations](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/async-operations)
- [Backup policy ARM/Bicep schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.recoveryservices/vaults/backuppolicies)
- [Set-AzRecoveryServicesBackupProtectionPolicy](https://learn.microsoft.com/en-us/powershell/module/az.recoveryservices/set-azrecoveryservicesbackupprotectionpolicy)
- [Azure Automation managed identity](https://learn.microsoft.com/en-us/azure/automation/enable-managed-identity-for-automation)
- [Azure Automation runtime environments](https://learn.microsoft.com/en-us/azure/automation/runtime-environment-overview)
