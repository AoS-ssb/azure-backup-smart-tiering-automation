# Sanitized validation summary

Validated against isolated live Azure resources on 2026-08-24. Environment identifiers and job IDs are intentionally omitted.

## Control-plane result

| Scope | Phase | Observed result |
|---|---|---|
| Resource group | Audit | One exact-name policy reported `WouldEnableTierRecommended`; writes `0`; errors `0` |
| Resource group | Apply | `DoNotTier` changed to `TierRecommended`; writes `1`; errors `0` |
| Resource group | Idempotence | `AlreadyCompliant`; writes `0`; errors `0` |
| Subscription | Audit | Two exact-name policies found: one compliant and one would enable; writes `0`; errors `0` |
| Subscription | Apply | One remained compliant and one changed to `TierRecommended`; writes `1`; errors `0` |
| Subscription | Idempotence | Both `AlreadyCompliant`; writes `0`; errors `0` |

Azure Activity Log attributed both backup-policy writes to the Automation Account's system-assigned managed identity.

## Test fixture

- Two GeoRedundant Recovery Services vaults in one isolated resource group.
- One custom Azure VM V1/daily policy per vault.
- Both policies began at `DoNotTier` and had zero protected items.
- The managed identity had subscription discovery reads and backup-policy writer access only at the isolated resource group.
- No subscription-wide backup-policy writer assignment was used.
- No recurring Automation schedule was created.

The final policy state was `TierRecommended` in both vaults. The runbook's schedule and retention comparisons passed after each write.

## Default policies observed

Each new vault also contained service-created policies resembling:

| Policy type | Shape | Initial tiering state |
|---|---|---|
| Default Azure VM policy | V1 daily | No tiering object returned |
| Enhanced Azure VM policy | V2 hourly | No tiering object returned |
| Hourly log backup policy | Azure Workload / SQL | No tiering object returned |

The validation jobs used an exact custom policy-name filter, so none of the service-created default policies was changed. Names of default policies should not be treated as a stable API contract.

## What was not proven

- Movement of a mature recovery point into Vault Archive.
- V2/hourly policy mutation.
- A policy protecting real workloads.
- SQL Server or SAP HANA `TierAfter` remediation.
- Resource Guard/MUA flows.
- Cross-tenant execution.

This evidence supports controlled canary use; it is not blanket certification for every Recovery Services backup-policy shape.
