# Design, alternatives, and limitations

## Decision summary

This repository contains an audit-first Azure VM backup-policy remediator. Version 1.0 was live-validated on empty canary policies; version 1.1 adds the orchestration guards that an adversarial review found missing. Orchestration hardening (targeting, eligibility, isolation, operation tracking, verification) is required **regardless of which setter is used** — switching to the supported Azure PowerShell cmdlet would not replace any of it. The REST setter remains because it is the implementation that was validated live and needs no Az modules.

Smart Tiering is configured on each child backup policy:

```text
Microsoft.RecoveryServices/vaults/backupPolicies
```

It is not a vault-wide, resource-group-wide, or subscription-wide switch. Those broader scopes are discovery scopes only.

## Why the current implementation uses REST

The validated runbook uses the Azure Automation managed-identity endpoint and calls Azure Resource Manager directly. This keeps the runtime module-light and provides explicit control over:

- resource-group and subscription discovery;
- exact vault and policy filters;
- fresh point reads before mutation;
- bounded retries;
- audit-only versus apply behavior;
- preservation of `TierAfter`;
- post-write tiering, schedule, and retention verification;
- idempotent zero-write repeats.

Azure Backup exposes backup-policy modification as an asynchronous full-resource `PUT`, not a leaf-property `PATCH`. The script therefore reads the current policy, changes the `ArchivedRP` mode in memory, writes the policy, and verifies the result.

## Recommended production setter

For the most supportable production implementation, retain the Automation orchestration but use Microsoft's supported cmdlet for the write:

```powershell
Set-AzRecoveryServicesBackupProtectionPolicy `
    -VaultId $vault.Id `
    -Policy $policy `
    -MoveToArchiveTier $true `
    -TieringMode TierRecommended
```

Pin compatible `Az.Accounts` and `Az.RecoveryServices` versions in the PowerShell 7.4 Runtime Environment. Keep authoritative before/after reads and compare all non-tiering policy properties. A cmdlet-based revision requires a separate canary test before replacing the live-validated REST implementation.

## Alternative matrix

| Method | Best fit | Limitation |
|---|---|---|
| Azure portal | One or a few policies | Manual and not fleet-repeatable |
| Azure PowerShell | One policy or the setter inside Automation | Requires Az modules and a complete policy object |
| Azure CLI | Operator-driven JSON workflow | `az backup policy set` requires complete policy JSON; no dedicated existing-policy Smart Tier switch |
| ARM/Bicep | New policies whose full desired state is managed as code | Not a safe merge mechanism for heterogeneous existing policies |
| Azure Policy | Governance if a modifiable leaf alias exists | No current Smart Tiering built-in or modifiable `ArchivedRP.tieringMode` alias |
| Azure Automation + REST | Controlled fleet discovery and remediation | Custom serialization, long-running-operation, and API-version logic must be maintained |

## Current implementation limitations (1.1)

Closed in 1.1 (see CHANGELOG.md): eligibility gate, per-policy isolation, fail-closed targeting,
`MaxChanges`/`ExpectedMatches`/protected-item guards, asynchronous-operation tracking with
separate submitted/verified/unknown counters, tag preservation, structural full-property
verification, request timeouts, null-safe diagnostics, token refresh on `401`, `Retry-After`.

Still open:

- Only `AzureIaasVM` policies are handled. SQL Server and SAP HANA use a different policy shape and `TierAfter`/`TierAllEligible` duration semantics.
- ZRS vaults are skipped because Vault Archive is unsupported.
- Only empty V1 daily Azure VM policies have been write-tested live. V2/hourly policies, tagged policies and policies protecting real workloads were not modified during validation; the defaults (`MaxProtectedItemsPerPolicy=0`) refuse protected policies until raised deliberately.
- The tested API did not return an ETag. The pre-write structural comparison narrows the concurrency window but is not atomic; run apply jobs for a vault one at a time. Fail closed for protected policies until an ETag-bearing API version is confirmed.
- Eligibility is computed from the policy's monthly/yearly retention horizon (≥ `MinimumRetentionMonths`, minimum 9; only `Months`/`Years` units count). It rules out policies that can never qualify; it does not inspect whether mature recovery points exist, whether the region supports the archive tier, or what Azure will recommend for a given VM.
- The API returned no ETag during validation, and Microsoft documents `eTag` on the policy resource but no `If-Match` compare-and-swap contract; `If-Match` is sent when available as best effort only.
- Recovery points moved to the archive tier carry a 180-day early-deletion charge; enabling `TierRecommended` does not guarantee immediate movement.
- Resource Guard/MUA may block unattended updates. The runbook reports the denial for that policy and continues; it does not bypass MUA.
- There is no automatic rollback after a successful write (deliberately: another full PUT could overwrite newer state and cannot reverse an archive move). Recovery is operator-controlled: set `DoNotTier` on the policy through the Portal or the cmdlet.
- Commercial Azure endpoints only (`management.azure.com`, public identity audience).
- Discovery is a serial ARM enumeration. No estate-scale run has been measured; sharding, checkpoints or Azure Resource Graph are not implemented and should only be considered after a measured audit of a real estate.

## Production hardening status

| # | Item (1.0 plan) | 1.1 status |
|---|---|---|
| 1 | Explicit policy allowlists for apply mode | Partial: exact-name fence, `ExpectedMatches`, `MaxChanges=1`, `AllowUnfilteredApply` opt-in. Resource-ID manifests deliberately deferred until a real fleet exists |
| 2 | Exclusions, `MaxChanges`, fail-closed zero-match | Done (`MaxChanges`, `NoPolicyMatched` abort); exclusions deferred |
| 3 | Isolate errors per policy | Done |
| 4 | Compare the complete policy before/after | Done (structural, member-order-insensitive, case-sensitive; excludes only `tieringPolicy`, `protectedItemsCount`, `resourceGuardOperationRequests`) |
| 5 | Preserve and verify resource tags | Done |
| 6 | Track the asynchronous operation to terminal state | Done (`Azure-AsyncOperation`, then `Location`, then resource polling; unknown outcomes reported, never retried) |
| 7 | Refresh tokens, honour `Retry-After`, jitter, timeouts | Done |
| 8 | V1, V2/hourly, tagged, protected-item, Resource Guard test cases | Offline: covered by the harness. Live: still required before those shapes are used |
| 9 | Canary-test a cmdlet-based setter | Deferred; not a substitute for items 1–7 |
| 10 | Azure Resource Graph for large-scale discovery | Deferred pending a measured need |
| new | Eligibility gate (monthly/yearly retention horizon) | Done — the 1.0 runbook selected the service-created daily-only default policies (confirmed live 2026-08-25) |
| new | Behavioural CI on PowerShell 7.4, pinned actions, PSScriptAnalyzer, exact RBAC assertions | Done |

## Official references

- [Enable Azure Backup Smart Tiering](https://learn.microsoft.com/en-us/azure/backup/use-archive-tier-support)
- [Set-AzRecoveryServicesBackupProtectionPolicy](https://learn.microsoft.com/en-us/powershell/module/az.recoveryservices/set-azrecoveryservicesbackupprotectionpolicy)
- [Backup policy Create or Update REST operation](https://learn.microsoft.com/en-us/rest/api/backup/protection-policies/create-or-update?view=rest-backup-2026-07-01)
- [Backup-policy ARM/Bicep resource schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.recoveryservices/vaults/backuppolicies)
- [Azure CLI backup policy commands](https://learn.microsoft.com/en-us/cli/azure/backup/policy)
- [Azure Policy modify requirements](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-modify)
- [Azure Backup archive support matrix](https://learn.microsoft.com/en-us/azure/backup/archive-tier-support)
