# Changelog

## 1.1.0 — 2026-08-25 (unreleased; branch `v1.1/tribunal-hardening`)

Hardening release driven by an adversarial multi-model review of 1.0 (thirteen GPT-5.6 runs,
one Claude cross-check, an executable offline harness, and a live audit of the 1.0 runbook against
the still-running validation fixture). No behaviour of the documented exact-name canary changed;
every item below closes a confirmed finding.

### Runbook (`src/Enable-SmartTiering.ps1`)
- **Archive-eligibility gate.** Policies without monthly/yearly retention of at least
  `MinimumRetentionMonths` (default 9) are reported as `SkippedNoArchiveEligibility` and never
  written. The 1.0 runbook selected the service-created daily-only `DefaultPolicy` and
  `EnhancedPolicy` as write candidates (confirmed live on 2026-08-25; ARM answers the resulting PUT
  with HTTP 400 `BMSUserErrorInvalidPolicyInput`, and 1.0's vault-level catch then skipped every later
  policy in that vault).
- **Per-policy error isolation.** A failing policy no longer stops the remaining policies in its
  vault; error rows carry the policy name, resource ID and the stage that failed.
- **Fail-closed apply.** `Apply=true` requires exact `VaultName` and `PolicyName` unless
  `AllowUnfilteredApply=true`; whitespace-only names are rejected instead of disabling the
  filter; `ResourceGroupName` with `ScopeType=Subscription` is rejected instead of ignored; the
  apply phase aborts before any write when nothing matched (`NoPolicyMatched`), when
  `ExpectedMatches` is not met, or when candidates exceed `MaxChanges` (default 1).
- **Two-phase execution.** Everything is discovered and classified before the first PUT.
- **Protected-item ceiling.** Candidates protecting more than `MaxProtectedItemsPerPolicy`
  (default 0) items are `SkippedProtectedItemsExceedLimit`; every row reports the count.
- **Honest writer.** The update's `202` is followed via `Azure-AsyncOperation`/`Location` to a
  terminal state; `writesSubmitted`, `policiesWritten` (verified), `writesFailed` and
  `writesUnknown` are reported separately; a write whose outcome is unknown is never resubmitted.
- **Text-preserving JSON.** The runbook reads raw response text and edits it with
  `System.Text.Json.Nodes`; PowerShell's `ConvertFrom-Json` silently rewrote date-like strings
  (for example a tag value `2026-08-25T02:00:00+03:00` became `…T23:00:00+00:00`) in 1.0's payload.
- **Full verification.** Root `tags` are preserved byte-for-byte and every property except
  `tieringPolicy.ArchivedRP` (and the two server-managed counters) is compared structurally
  (member-order-insensitive, case-sensitive) after the write.
- **Fail-closed facts.** Unknown vault redundancy is an error (its policies are not evaluated); a
  missing protected-item count is `SkippedProtectedItemsUnknown`; a protected policy without an ETag
  is `SkippedNoConcurrencyToken` unless `AllowWriteWithoutETag`; any discovery error aborts apply.
- **Job budget.** `JobTimeBudgetSeconds` (default 8400) stops new writes before Azure Automation's
  three-hour cloud-job limit; unwritten candidates are reported and the job fails closed.
- **Token hygiene.** The managed-identity token is only sent to `https://management.azure.com`;
  continuation and operation URLs are validated before use.
- **Transport.** `Invoke-WebRequest` with connection and operation timeouts on every call, null-safe
  error extraction (StrictMode no longer masks transport or empty-body errors), transport failures
  without an HTTP response treated as transient for reads, one token refresh on `401` that does not
  consume a retry, `Retry-After` honoured (up to 300 s) with jitter, ambiguous PUT outcomes
  reconciled by re-reading and reported as `WriteOutcomeUnknown` — never resubmitted.
- **Output.** Every row has a UTC timestamp, vault and policy resource IDs, policy type, protected
  item count, retention horizon, stage and operation status; `policiesMatched` counts real
  policies only; `SUMMARY` includes `abortReason` and `runbookVersion`.

### Repository
- `tests/BehaviorHarness.ps1`: dependency-free behavioural harness that executes the real runbook
  against a mocked ARM transport (45 scenarios, S34–S45 pinning the review findings); runs in CI on
  the runner's PowerShell 7.4.
- CI pins `actions/checkout` to a commit SHA, runs PSScriptAnalyzer (warnings fail), and asserts
  the exact RBAC actions.
- RBAC: the remediator role description states that `backupPolicies/write` is full policy-update
  authority; the no-op `NotActions` entry is removed; the reader guidance is scoped per run type.
  (`backupPolicies/operations/read` is the manifest-confirmed action for polling the update
  operation; a docs-derived suggestion to use `operationsStatus/read` was checked against the live
  provider manifest and rejected.)
- Docs: `DoNotTier` mutation walkthrough separated from the safe redeploy, teardown steps,
  modify-protection fan-out and 180-day archive early-deletion cost disclosed, commercial-cloud-only
  endpoints stated, and this changelog versus the July 2026 predecessor.

### Known limitations carried forward
- The REST API returned no ETag during validation; concurrency protection is the pre-write
  structural comparison plus an operator-enforced exclusive change window. Fail closed for
  protected policies until an ETag-bearing API version is confirmed.
- V2/hourly, tagged and protected policies still require their own live canaries before use.
- Commercial Azure endpoints only.

## 1.0.0 — 2026-08-25
Initial publication: live-validated REST runbook, Bicep test fixture, custom RBAC templates,
marker-based static validation. Superseded the July 2026 `Enable-RsvSmartTiering` prototype
(which had a `TierAfter` mode, an LTR eligibility check, a weekly schedule and deploy/teardown
scripts — all intentionally dropped; the eligibility check returns in 1.1.0).
