# Inspecting a deployed Automation Account

This repository does not contain tenant-specific Azure Portal links or resource IDs. From any authenticated workstation, including a homelab host:

1. Open the Azure Portal and select the subscription containing the deployment.
2. Open the resource group used for the test environment.
3. Select the Automation Account.
4. Open **Runbooks** → **Enable-SmartTiering**.
5. Open **Jobs** to review audit, apply, and idempotence output.
6. Open **Identity** to confirm the system-assigned managed identity.
7. Open **Schedules** to confirm whether a recurring job exists. The reference deployment creates none.
8. Open **Access control (IAM)** to inspect the discovery-reader and policy-writer assignment scopes.
9. Open each Recovery Services vault → **Backup policies** → the canary policy to inspect `TierRecommended`.

The reference validation leaves policies with zero protected items. It proves the control-plane path, not actual recovery-point movement into archive storage.

Version 1.1 additions: compare the SHA-256 of the published runbook content (Runbooks → **Enable-SmartTiering** → **Edit** → copy) with `sha256sum src/Enable-SmartTiering.ps1` for the commit you deployed, and read the `SUMMARY` line of each job for `runbookVersion`, `candidates`, `policiesWritten`, `writesSubmitted`, `writesUnknown` and `abortReason`.
