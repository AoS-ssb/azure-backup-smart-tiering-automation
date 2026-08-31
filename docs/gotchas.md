# Gotchas

Everything on this page was hit for real while building, reviewing or live-qualifying this runbook.
Read it before the first `Apply=true`.

## Cost and irreversibility

- `TierRecommended` hands the decision to Azure: eligible recovery points move to the vault-archive tier
  when Azure recommends it. Restores from archive take hours and are billed for rehydration. Nothing
  moves back automatically.
- Only policies with **monthly or yearly retention of at least 9 months** can ever produce an
  archive-eligible recovery point (≥ 3 months old with ≥ 6 months left). Daily-only policies are rejected
  by ARM with `400 BMSUserErrorInvalidPolicyInput` — 1.0 recorded that as an `Error` row, 1.1 skips them
  with `SkippedNoArchiveEligibility` and never sends the PUT.
- A backup policy PUT is a **full-document write**. The runbook sends the policy back byte-for-byte with
  only the tiering block changed (text-preserving JSON), but a concurrent edit by someone else can still be
  overwritten when the API returns no ETag — see `AllowWriteWithoutETag` below.

## Behaviour that looks like a bug but is the contract

- With the defaults (`MaxChanges=1`, `MaxProtectedItemsPerPolicy=0`) the runbook will change at most one
  policy per run and **skips any policy that protects items** (`SkippedProtectedItemsExceedLimit`). Raise
  `MaxProtectedItemsPerPolicy` to the real count of the policy you intend to change — never to a blanket
  large number.
- `Apply=true` without both `VaultName` and `PolicyName` is refused unless `AllowUnfilteredApply=true`.
  Unfiltered apply is a fleet write; the review rejected it as a default.
- `SkippedNoConcurrencyToken`: a candidate that protects items but came back without an ETag is skipped
  unless `AllowWriteWithoutETag=true`. The flag is an acknowledgement that there is no concurrency token —
  use it only inside an exclusive change window.
- `WriteOutcomeUnknown` (a lost response, or a 202 whose operation could not be followed to completion)
  fails the job and is **never resubmitted**. Re-run the audit; the next apply is idempotent.
- `ExpectedMatches` counts Azure VM policies that matched the filters, not candidates. A misspelled
  `PolicyName` aborts with `NoPolicyMatched` and zero writes.
- A `SUMMARY` exists only after execution reaches the result section. Parameter binding,
  script-level parameter validation (whitespace names, unfiltered apply), managed-identity token
  acquisition, and the top-level vault-list call can all fail earlier. The live no-reader canary
  produced the expected vault-list 403 with a Failed job and Error stream but no `SUMMARY`.
- `writesSubmitted` counts a PUT attempt, not a verified mutation. An exact apply with only the
  reader role reaches the policy, attempts the PUT, and fails with 403; expect
  `writesSubmitted=1`, `writesFailed=1`, `errors=1`, and `policiesWritten=0`. The policy is unchanged.

## Azure Automation platform

- PowerShell 7.4 runtime environment; no Az modules are needed (the runbook talks to ARM with
  `Invoke-WebRequest` and the Automation identity endpoint). Link the runbook to the runtime environment
  explicitly — a Portal-created runbook may land on the legacy runtime.
- `scripts/publish-runbook.sh` discovers the Automation Account's location. If you override
  `LOCATION`, it must be the account's actual region; quota-driven region changes should not leave a
  stale East US 2 publishing default.
- Job streams are capped at 1 MiB per job; a subscription with many vaults is better audited per resource
  group, or ship job streams to Log Analytics.
- Azure Automation stops cloud jobs after three hours; `JobTimeBudgetSeconds` (default 8400) stops new
  writes well before that and fails closed with `SkippedJobBudgetExhausted` rows.
- Text `true`/`false` job parameters bind to `[bool]` correctly (proved live).

## RBAC

- The remediator role's `backupPolicies/write` is full policy-update authority: whoever can publish or
  start runbooks in that Automation account can change schedules and retention with the managed
  identity. Assign the remediator role only at the ring vault/resource group, only for the window.
- The RBAC action for following an asynchronous policy update is
  `Microsoft.RecoveryServices/Vaults/backupPolicies/operations/read` — confirmed against the live
  provider manifest (`az provider operation show --namespace Microsoft.RecoveryServices`). A Microsoft
  Learn page names a different action; the manifest is authoritative.
- Expect propagation lag and stale tokens after a grant: `AuthorizationFailed … refresh your credentials`
  can persist until the CLI token rolls over even when the assignment is correct.
- For `ScopeType=ResourceGroup`, use `scripts/discovery-role.sh`; its custom reader definition and
  assignment are both RG-scoped. The subscription reader template is intentionally broader and
  requires custom-role authority at its subscription assignable scope.

## Fixture lifecycle

- Use `infra/test-environment.bicep` to create a new empty fixture, not to mutate a retained one.
  Azure adds service-default properties after deployment, so a later full-template update can carry
  unrelated drift. The replication guide seeds only the exact zero-item policy with a sanitized PUT.
- `retainForInspection=true` changes lifecycle tags; it does not create a lock or make deletion
  impossible. The default replication handoff removes the writer and deliberately leaves the
  reader-only resources alive.

## Reusing or modifying the code

- Run the harness non-interactively (`pwsh -NonInteractive -NoProfile -File tests/BehaviorHarness.ps1`).
- `ConvertFrom-Json` rewrites date-like strings into `DateTime`; a tag value such as `2026-08-25` would be
  sent back reformatted. The runbook keeps every value as text with `System.Text.Json.Nodes` — keep it that
  way.
- `System.Text.Json` nodes are enumerable: returning one from a PowerShell function unrolls it unless you
  use the comma operator (`return , $node`).
- `HttpResponseException` inherits from `HttpRequestException`; only treat an exception as transient when
  it carries no response.
- The `az automation` CLI group is marked experimental and cannot link a runtime environment; use the REST
  `PATCH …/runbooks/{name}?api-version=2024-10-23`.
