# Replicate this in Azure — step by step

From an empty subscription to a live-qualified enable-only write on an empty backup policy, with the
checkpoint you should see at each step. The fixture holds no backup data and costs nothing material.
Read [gotchas.md](gotchas.md) first.

## 0. Prerequisites (5 min)

- Commercial Azure subscription; Owner or User Access Administrator **only** for the RBAC steps (4, 6).
- Azure CLI ≥ 2.60 with Bicep and the `automation` extension (marked experimental; warnings are harmless).
- Automation Accounts are quota-limited per region on small subscriptions — if step 1 fails with
  `Conflict … exceeded your quota for Automation accounts`, choose another region.
- No PowerShell modules are needed in Azure: the runbook talks to ARM with `Invoke-WebRequest` and the
  Automation identity endpoint. PowerShell 7.4 locally only for the offline harness.

```bash
SUB=<subscription-id>
RG=<test-resource-group>              # new and empty: the deployment is incremental and overwrites same-named vaults/policies
AA=<automation-account-name>
RG_VAULT=<rg-canary-vault>            # names must not exist anywhere in the subscription
SUB_VAULT=<subscription-canary-vault>
REGION=<azure-region>
```

## 1. Fixture: Automation Account, PowerShell 7.4 runtime, two empty vaults, one canary policy each (5 min)

```bash
az group create -n $RG -l $REGION
test "$(az resource list -g $RG --query 'length(@)' -o tsv)" = "0"
az deployment group create -g $RG --template-file infra/test-environment.bicep --parameters \
  resourceGroupScopeVaultName=$RG_VAULT subscriptionScopeVaultName=$SUB_VAULT automationAccountName=$AA \
  backupPolicyName=smart-tiering-remediation-canary testPolicyTieringMode=TierRecommended retainForInspection=false
PRINCIPAL=$(az automation account show -g $RG -n $AA --query identity.principalId -o tsv)
```

The template does **not** import the runbook or create RBAC. Each new vault also receives the service
defaults (`DefaultPolicy`, `EnhancedPolicy`, `HourlyLogBackup`); 1.1 classifies the first two as
`SkippedNoArchiveEligibility` (daily-only retention can never reach the archive tier).

## 2. Publish the runbook, linked to the runtime (1 min)

```bash
SUBSCRIPTION_ID=$SUB RESOURCE_GROUP=$RG AUTOMATION_ACCOUNT=$AA scripts/publish-runbook.sh
```

**Checkpoint** — the script prints `remote state/runtime: Published PowerShell74` and
`OK: published bytes equal the local file`; record the hash with your change.

## 3. First audit — before any RBAC (1 min)

```bash
az automation runbook start -g $RG --automation-account-name $AA -n Enable-SmartTiering --parameters \
  SubscriptionId=$SUB ScopeType=ResourceGroup ResourceGroupName=$RG VaultName=$RG_VAULT \
  PolicyName=smart-tiering-remediation-canary Apply=false
```

**Checkpoint** — job `Failed` with a `SUMMARY` line whose `abortReason`/message names the authorization
failure (the vault listing is refused with HTTP 403 until a role is assigned); zero rows, zero writes. That
is the fail-closed path.

## 4. Reader role (2 min, Owner/UAA)

```bash
sed "s#REPLACE_WITH_SUBSCRIPTION_ID#$SUB#" infra/rbac/discovery-reader-role.template.json > /tmp/reader.json
az role definition create --role-definition @/tmp/reader.json
az role assignment create --assignee-object-id $PRINCIPAL --assignee-principal-type ServicePrincipal \
  --role "Azure Backup Smart Tiering Discovery Reader" --scope /subscriptions/$SUB/resourceGroups/$RG
```

Subscription scope only when you need `ScopeType=Subscription` discovery. Allow up to ten minutes for
propagation; a job started too early fails like step 3.

## 5. Audit (1 min)

Same command as step 3. **Checkpoint** — `Completed`; the canary policy is `AlreadyCompliant`
(the safe redeploy seeds it with `TierRecommended`), the service defaults are `SkippedNoArchiveEligibility`,
`errors=0`, `writesSubmitted=0`.

To see a real write, seed the canary as `DoNotTier` by redeploying step 1 with
`testPolicyTieringMode=DoNotTier`, then audit again: exactly one `WouldEnableTierRecommended` row.

## 6. Guards, then the canary write (10 min, Owner/UAA for the grant)

Guards (each must end `Failed`, `SUMMARY` present, zero writes):

| Parameters | Result |
|---|---|
| `Apply=true` with `VaultName='  '` (whitespace) | parameter validation, zero ARM calls |
| `Apply=true` without `VaultName`/`PolicyName` and without `AllowUnfilteredApply` | refused before any write |
| `Apply=true PolicyName=<misspelled>` | `abortReason=NoPolicyMatched` |
| `Apply=true` with only the reader role | the PUT is refused with 403 → `Failed`, nothing changed (negative RBAC proof) |

Grant the writer role for the window and apply:

```bash
scripts/ring-role.sh grant $SUB $RG $PRINCIPAL
az automation runbook start -g $RG --automation-account-name $AA -n Enable-SmartTiering --parameters \
  SubscriptionId=$SUB ScopeType=ResourceGroup ResourceGroupName=$RG VaultName=$RG_VAULT \
  PolicyName=smart-tiering-remediation-canary Apply=true ExpectedMatches=1
```

**Checkpoint** — `Completed`; `WouldEnableTierRecommended` → `EnabledAndVerified` (HTTP 200),
`writesSubmitted=1`, `policiesWritten=1`; the policy's schedule and retention are byte-for-byte unchanged
(compare `az backup policy show` before/after — only `tieringPolicy.ArchivedRP` differs). Run it again:
`AlreadyCompliant`, `policiesWritten=0`.

With the defaults (`MaxChanges=1`, `MaxProtectedItemsPerPolicy=0`) a policy that protects items is skipped;
raise `MaxProtectedItemsPerPolicy` to that policy's real item count when you mean it.

**Revoke immediately after:**

```bash
scripts/ring-role.sh revoke $SUB $RG $PRINCIPAL
```

## 7. Operate

- Schedule audits only; every apply is a human-started job with exact `VaultName` + `PolicyName` and
  `ExpectedMatches=1`.
- Alert on `unknown > 0` / `errors > 0`; `WriteOutcomeUnknown` is never resubmitted — re-audit and re-apply.
- `AllowWriteWithoutETag=true` only inside an exclusive change window.

## 8. Teardown

```bash
scripts/ring-role.sh revoke $SUB $RG $PRINCIPAL
az role assignment delete --assignee $PRINCIPAL --role "Azure Backup Smart Tiering Discovery Reader" --scope /subscriptions/$SUB/resourceGroups/$RG
az role definition delete --name "Azure Backup Smart Tiering Discovery Reader"
az group delete -n $RG --yes --no-wait
```

## What "replicated" looks like

[validation.md](validation.md) records this sequence run on 2026-08-24/25 against the released bytes:
audit, seeded `DoNotTier` → exact apply (`EnabledAndVerified`, HTTP 200) → idempotent apply, the guards, and
the live proof that ARM rejects `TierRecommended` on a daily-only policy with `400 BMSUserErrorInvalidPolicyInput`.
