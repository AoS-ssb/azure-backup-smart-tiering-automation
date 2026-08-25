# Design, alternatives, and limitations

## Decision summary

This repository contains a live-validated, audit-first Azure VM backup-policy remediator. Its current REST implementation is suitable for controlled canaries. Before production fleet use, implement the hardening items below or migrate the setter to Microsoft's supported Azure PowerShell cmdlet.

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

## Current implementation limitations

- Only `AzureIaasVM` policies are handled. SQL Server and SAP HANA use a different policy shape and `TierAfter`/`TierAllEligible` duration semantics.
- ZRS vaults are skipped because Vault Archive is unsupported.
- Only an empty V1 daily Azure VM policy was write-tested. V2/hourly policies and policies protecting real workloads were not modified during validation.
- The script verifies schedule and retention, not every non-tiering property. Tiering is the only intended mutation, but complete equivalence is not currently proven.
- Root policy tags are not copied into the REST payload or verified. A tagged policy requires additional testing and preservation logic.
- The update API can return `202 Accepted`. The script polls the policy for up to about 60 seconds instead of explicitly following the `Azure-AsyncOperation` or `Location` header.
- The tested API did not return an ETag. The second point-read narrows the concurrency window but does not provide atomic optimistic concurrency.
- One policy error stops the remaining policies in that vault; error isolation is currently at vault level.
- The managed-identity token is acquired once. Very long jobs should refresh before expiry or after `401`.
- Retry logic does not honor `Retry-After` and has no jitter.
- A subscription-scope `PolicyName` filter matches that name in every discovered vault; it is not a vault/policy-pair allowlist.
- A misspelled vault or policy filter results in a successful zero-match summary.
- There is no `MaxChanges`, mandatory allowlist, exclusion set, or change-ticket guard.
- The script does not validate whether a policy has monthly/yearly recovery points that can become archive-eligible.
- Resource Guard/MUA may block unattended updates. The script does not bypass it.
- There is no automatic rollback after a successful policy write.

## Production hardening order

1. Require explicit policy resource-ID allowlists for apply mode.
2. Add exclusions, `MaxChanges`, and fail-closed zero-match behavior for canaries.
3. Isolate errors per policy.
4. Compare the complete policy before/after, excluding only documented read-only fields and the intended tiering change.
5. Preserve and verify resource tags.
6. Track the asynchronous update operation to its terminal state.
7. Refresh tokens and honor `Retry-After` with jitter.
8. Add V1, V2/hourly, tagged, protected-item, and Resource Guard test cases.
9. Canary-test a cmdlet-based setter using pinned Az modules.
10. Use Azure Resource Graph only for large-scale discovery, followed by authoritative point reads before any write.

## Official references

- [Enable Azure Backup Smart Tiering](https://learn.microsoft.com/en-us/azure/backup/use-archive-tier-support)
- [Set-AzRecoveryServicesBackupProtectionPolicy](https://learn.microsoft.com/en-us/powershell/module/az.recoveryservices/set-azrecoveryservicesbackupprotectionpolicy)
- [Backup policy Create or Update REST operation](https://learn.microsoft.com/en-us/rest/api/backup/protection-policies/create-or-update?view=rest-backup-2026-07-01)
- [Backup-policy ARM/Bicep resource schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.recoveryservices/vaults/backuppolicies)
- [Azure CLI backup policy commands](https://learn.microsoft.com/en-us/cli/azure/backup/policy)
- [Azure Policy modify requirements](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-modify)
- [Azure Backup archive support matrix](https://learn.microsoft.com/en-us/azure/backup/archive-tier-support)
