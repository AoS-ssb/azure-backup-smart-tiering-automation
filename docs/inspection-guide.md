# Inspecting a deployed Automation Account

This repository contains no tenant-specific Azure Portal links or resource IDs. For the full Azure
Policy + Azure Automation inspection path, use the
[canonical combined guide](https://github.com/kevo099/azure-enterprise-policy-baseline/blob/main/docs/REPLICATE-POLICY-AUTOMATION.md).

From an authenticated workstation:

1. Open the Azure Portal and select the subscription containing the deployment.
2. Open the retained canary resource group.
3. Select the Automation Account, then **Runbooks** → **Enable-SmartTiering**.
4. Confirm the runbook is **Published** and its runtime environment is **PowerShell74**.
5. Open **Jobs** and inspect the completed audit, apply, and repeat jobs.
6. In jobs that reached the result section, confirm the last output line is `SUMMARY {...}`:
   - audit: candidates/submitted/verified = `1/0/0`;
   - apply: `1/1/1`, with zero failed or unknown writes;
   - repeat: `0/0/0` and an `AlreadyCompliant` row.
7. Open **Identity** and confirm a system-assigned managed identity exists.
8. Open **Access control (IAM)** and confirm the RG-scoped discovery reader remains while the
   policy-remediator writer assignment is absent.
9. Open **Schedules** and confirm there are zero schedules and zero linked job schedules.
10. Open each Recovery Services vault → **Backup policies** → the canary policy. Confirm
    `TierRecommended` and zero protected items.

Compare the published content SHA-256 with `sha256sum src/Enable-SmartTiering.ps1` from the exact
commit deployed. `scripts/publish-runbook.sh` performs a fetch-back byte comparison during
publication; retain its success output locally with the source commit.

Not every failed job has a `SUMMARY`. Parameter validation, managed-identity initialization, and a
top-level vault-list failure occur before the result section. In particular, the optional no-reader
test is expected to be Failed before any policy PUT, with its cause in the Error stream and no
summary. It may stop during token/context initialization or at the vault read. A reader-only apply
reaches the handled write path and does have a summary:
`writesSubmitted=1`, `writesFailed=1`, `policiesWritten=0`.

The reference validation leaves zero protected items. It proves discovery, authorization,
full-policy update, verification, and idempotence; it does not prove actual recovery-point movement
into archive storage. Do not publish copied Portal URLs or raw job streams because they contain
subscription, resource, principal, and job identifiers.
