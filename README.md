# Azure Backup Smart Tiering automation

A live-validated, audit-first Azure Automation runbook for finding Azure VM backup policies where Vault Archive Smart Tiering is missing or disabled and enabling `TierRecommended` without intentionally changing schedule or retention.

> **Status:** validated reference implementation. The current REST implementation is appropriate for controlled, exact-name canaries. Review the documented hardening items before unfiltered production fleet use.

## What it changes

Smart Tiering is configured on each Recovery Services vault child backup policy—not on the vault itself:

```text
Microsoft.RecoveryServices/vaults/backupPolicies
```

For Azure VM policies, the intended change is:

```json
{
  "tieringPolicy": {
    "ArchivedRP": {
      "tieringMode": "TierRecommended"
    }
  }
}
```

| Existing mode | Audit result | Apply behavior |
|---|---|---|
| Missing | `WouldEnableTierRecommended` | Set `TierRecommended` |
| `DoNotTier` | `WouldEnableTierRecommended` | Set `TierRecommended` |
| `TierRecommended` | `AlreadyCompliant` | No write |
| `TierAfter` | `AlreadyEnabledAlternateMode` | Preserve; no write |
| Unknown | `SkippedUnknownMode` | No write |

The runbook handles only `AzureIaasVM` policies. It skips ZRS vaults and other workload-policy shapes.

## Why this exists

Azure provides a Portal control and an official PowerShell cmdlet, but no field-level Smart Tiering `PATCH`, vault-wide switch, built-in Azure Policy remediation, or dedicated existing-policy CLI flag. REST and CLI updates operate on a complete backup policy.

This runbook adds the orchestration needed for controlled resource-group and subscription remediation:

- system-assigned managed-identity authentication;
- audit-only default (`Apply=false`);
- exact vault and policy filters;
- fresh reads before mutation;
- preservation of `TierAfter`;
- transient retry handling;
- post-write verification;
- schedule and retention comparisons;
- compact job evidence;
- idempotent repeat execution.

Microsoft's supported `Set-AzRecoveryServicesBackupProtectionPolicy` cmdlet is the preferred production setter. The direct REST setter remains here because it is the implementation that was validated live and it avoids Az module dependencies. See [design and limitations](docs/design-and-limitations.md) before production use.

## Repository contents

```text
src/Enable-SmartTiering.ps1              Azure Automation runbook
infra/test-environment.bicep              Empty two-vault canary fixture
infra/rbac/*.template.json                Portable custom-role definitions
docs/design-and-limitations.md            Method comparison and hardening plan
docs/validation.md                        Sanitized live-test evidence
docs/inspection-guide.md                  Azure Portal inspection path
tests/StaticValidation.ps1                Parser and destructive-marker checks
.github/workflows/validate.yml            PowerShell, JSON, and Bicep CI
```

Raw subscription IDs, principal IDs, role-assignment IDs, job IDs, resource names, and live Portal links are intentionally excluded.

## Prerequisites

- An Azure subscription where you can create the isolated test resources.
- Permission to create an Automation Account, Recovery Services vaults, custom roles, and role assignments.
- Azure CLI with the `automation` extension.
- PowerShell 7.4 Runtime Environment in Azure Automation.
- A deliberate RBAC and change-approval decision before applying beyond a canary resource group.

```bash
az login
az extension add --name automation --upgrade
```

## Deploy the empty test fixture

Create a dedicated resource group, then deploy the Bicep fixture. Use globally available names for the Automation Account and vaults.

```bash
az group create \
  --subscription <subscription-id> \
  --name <test-resource-group> \
  --location <azure-region>

az deployment group create \
  --subscription <subscription-id> \
  --resource-group <test-resource-group> \
  --template-file infra/test-environment.bicep \
  --parameters \
    resourceGroupScopeVaultName=<rg-canary-vault> \
    subscriptionScopeVaultName=<subscription-canary-vault> \
    automationAccountName=<automation-account> \
    backupPolicyName=smart-tiering-remediation-canary \
    testPolicyTieringMode=TierRecommended
```

`TierRecommended` is the safe redeploy default. Use `DoNotTier` only when deliberately seeding an isolated apply test with no protected items.

The Bicep file creates the Automation Account, PowerShell 7.4 runtime, two empty vaults, and one canary policy in each vault. It does **not** import the runbook or create RBAC definitions/assignments.

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

After publishing, associate the runbook with the `PowerShell74` Runtime Environment through the Azure Portal or the current Automation ARM API.

## RBAC model

Render the two role templates by replacing `REPLACE_WITH_SUBSCRIPTION_ID`, then create them with `az role definition create`.

Assign:

- `Azure Backup Smart Tiering Discovery Reader` at subscription scope for vault and policy reads;
- `Azure Backup Smart Tiering Policy Remediator` only at the canary resource group for backup-policy reads/writes.

The writer role does not include a delete action, but `backupPolicies/write` permits modifying the complete policy. `NotActions` is not an explicit deny and cannot restrict permissions granted by another role.

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

Review the job output. Change only `Apply=false` to `Apply=true` after approving the exact candidate and RBAC scope. Run the same apply a second time and require `policiesWritten=0`.

For subscription discovery, set `ScopeType=Subscription` and omit `ResourceGroupName`. Keep an exact policy filter during canaries. At subscription scope, `PolicyName` selects that same name in every discovered vault.

No recurring schedule is created by this repository.

## Validated result

The isolated test completed resource-group and subscription audit/apply/idempotence cycles:

- missing/disabled policy detected with zero audit writes;
- `DoNotTier` changed to `TierRecommended`;
- one write per intended policy and zero errors;
- schedule and retention comparisons passed;
- repeated apply produced zero writes;
- Azure Activity Log recorded the managed identity as policy-write caller.

See [the sanitized validation report](docs/validation.md).

## Important limitations

- Only an empty Azure VM V1/daily policy was write-tested.
- V2/hourly, tagged policies, and policies protecting real workloads need additional canaries.
- SQL Server and SAP HANA policies are skipped.
- The REST update is asynchronous; the current script GET-polls for about 60 seconds rather than following the operation URL.
- Verification covers schedule and retention, not every policy field.
- Policy-level tags are not currently preserved in the write payload.
- Apply mode has no mandatory allowlist, exclusion list, or `MaxChanges` guard.
- Error isolation is per vault, not per policy.
- A misspelled exact filter can return a successful zero-match summary.
- Enabling Smart Tiering does not guarantee immediate recovery-point movement. Azure archive eligibility rules still apply.
- Resource Guard/MUA can block the update.

See [the complete limitation and hardening list](docs/design-and-limitations.md).

## Local validation

```bash
pwsh -NoProfile -File tests/StaticValidation.ps1
jq empty infra/rbac/*.json
az bicep build --file infra/test-environment.bicep --stdout > /dev/null
```

## Official references

- [Use Azure Backup Archive tier and enable Smart Tiering](https://learn.microsoft.com/en-us/azure/backup/use-archive-tier-support)
- [Set-AzRecoveryServicesBackupProtectionPolicy](https://learn.microsoft.com/en-us/powershell/module/az.recoveryservices/set-azrecoveryservicesbackupprotectionpolicy)
- [Backup policy Create or Update REST API](https://learn.microsoft.com/en-us/rest/api/backup/protection-policies/create-or-update?view=rest-backup-2026-07-01)
- [Backup policy ARM/Bicep schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.recoveryservices/vaults/backuppolicies)
- [Azure CLI backup policy commands](https://learn.microsoft.com/en-us/cli/azure/backup/policy)
- [Azure Backup archive support matrix](https://learn.microsoft.com/en-us/azure/backup/archive-tier-support)
- [Azure Automation managed identity](https://learn.microsoft.com/en-us/azure/automation/enable-managed-identity-for-automation)
