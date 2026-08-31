# Behavioural harness for src/Enable-SmartTiering.ps1.
# Executes the REAL runbook with a mocked ARM transport (global Invoke-RestMethod / Start-Sleep) and
# asserts per-policy actions, write counters, PUT bodies, abort reasons and thrown errors across 45
# scenarios. Dependency-free; runs on PowerShell 7.4. Exit code 1 when any oracle fails.
# Originally authored by a GPT-5.6 test-engineer run during the 2026-08-25 review; adapted for 1.1.
[CmdletBinding()]
param(
    [string] $RunbookPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Enable-SmartTiering.ps1'),
    [string] $FixturePath = (Join-Path $PSScriptRoot 'fixtures.json'),
    [string] $ResultsPath = (Join-Path $PSScriptRoot 'results.md')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$subscription = '11111111-1111-1111-1111-111111111111'
$management = 'https://management.azure.com'
$apiVersion = '2025-08-01'
$env:IDENTITY_ENDPOINT = 'http://mock.identity/token'
$env:IDENTITY_HEADER = 'mock-secret'
$fixtures = Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json
# Loading the built-in command makes HttpResponseException available before the mock shadows it.
Get-Command Microsoft.PowerShell.Utility\Invoke-RestMethod | Out-Null

function Copy-Object([AllowNull()][object] $Value) {
    if ($null -eq $Value) { return $null }
    return ($Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json)
}
function Set-Note([object] $Object, [string] $Name, [AllowNull()][object] $Value) {
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}
function Get-Value([AllowNull()][object] $Object, [string] $Name, [AllowNull()][object] $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if (@($Object.Keys) -contains $Name) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}
function New-Policy {
    param(
        [string] $Template = 'canaryPolicy', [string] $Name = 'smart-tiering-canary',
        [string] $Mode = 'TierRecommended', [AllowNull()][Nullable[int]] $ProtectedCount = $null
    )
    $policy = Copy-Object $fixtures.$Template
    $policy.name = $Name
    if ($Mode -eq 'Missing') { $policy.properties.PSObject.Properties.Remove('tieringPolicy') }
    elseif ($Template -eq 'canaryPolicy') {
        $archived = $policy.properties.tieringPolicy.ArchivedRP
        $archived.tieringMode = $Mode
        if ($Mode -eq 'TierAfter') { $archived.duration = 3; $archived.durationType = 'Months' }
        elseif ($Mode -eq 'DoNotTier') { $archived.duration = 0; $archived.durationType = 'Invalid' }
    }
    if ($null -ne $ProtectedCount) { Set-Note $policy.properties 'protectedItemsCount' ([int]$ProtectedCount) }
    return $policy
}
function Set-MonthlyHorizon([object] $Policy, [int] $Months) {
    $Policy.properties.retentionPolicy.PSObject.Properties.Remove('yearlySchedule')
    $Policy.properties.retentionPolicy.monthlySchedule.retentionDuration.count = $Months
    $Policy.properties.retentionPolicy.monthlySchedule.retentionDuration.durationType = 'Months'
    return $Policy
}
function New-Vault([string] $Name, [object[]] $Policies, [string] $Redundancy = 'GeoRedundant') {
    $id = "/subscriptions/$subscription/resourceGroups/rg-test/providers/Microsoft.RecoveryServices/vaults/$Name"
    foreach ($policy in $Policies) { $policy.id = "$id/backupPolicies/$($policy.name)" }
    return [pscustomobject]@{ name=$Name; id=$id; redundancy=$Redundancy; policies=$Policies }
}
function New-ExpectedSummary([int] $Written=0, [int] $Submitted=0, [int] $Unknown=0,
    [int] $Failed=0, [int] $Errors=0, [AllowNull()][object] $Abort=$null) {
    return [pscustomobject]@{ policiesWritten=$Written; writesSubmitted=$Submitted
        writesUnknown=$Unknown; writesFailed=$Failed; errors=$Errors; abortReason=$Abort }
}
function New-Case {
    param([string] $Id, [string] $Purpose, [object[]] $Vaults, [string[]] $ExpectedRows,
        [bool] $Apply=$false, [string] $Scope='ResourceGroup', [AllowNull()][string] $ResourceGroup='rg-test',
        [hashtable] $Options=@{})
    $data = [ordered]@{
        Id=$Id; Variant=''; Purpose=$Purpose; Vaults=$Vaults; ExpectedRows=@($ExpectedRows)
        Apply=$Apply; Scope=$Scope; ResourceGroup=$ResourceGroup; Parameters=@{}
        ExpectedSummary=(New-ExpectedSummary); ExpectedPuts=0; ExpectedDiffs=@(); ExpectedThrow=$false
        ExpectedThrowLike=''; LegacyCompatible=$false; Check=''; PaginateVaults=$false; PaginatePolicies=$false
        FaultKind=''; FaultVault=''; FaultPolicy=''; FaultCode=0; FaultCount=0
        FaultNoDetails=$false; RetryAfter=$null; VerifyLag=0; MutatePolicy=''; ReorderPolicy=''
        AsyncKind=''; AsyncRetryAfter=1; TransportPut=$false; TransportApplies=$true
        RawPolicyJson=@{}; MissingRedundancyVault=''; VerifyTieringDriftPolicy=''
        ForeignVaultNextLink=''; FaultSequence=@(); OperationTransportFailures=0
    }
    foreach ($key in $Options.Keys) { $data[$key] = $Options[$key] }
    return [pscustomobject]$data
}
function Exact-Parameters([string] $Policy, [string] $Vault='v1') {
    return @{ VaultName=$Vault; PolicyName=$Policy }
}

$diffDoNotTier = '-properties.protectedItemsCount; -properties.tieringPolicy.ArchivedRP.duration; -properties.tieringPolicy.ArchivedRP.durationType; ~properties.tieringPolicy.ArchivedRP.tieringMode:DoNotTier=>TierRecommended'
$diffGuard = '-properties.protectedItemsCount; -properties.resourceGuardOperationRequests; -properties.tieringPolicy.ArchivedRP.duration; -properties.tieringPolicy.ArchivedRP.durationType; ~properties.tieringPolicy.ArchivedRP.tieringMode:DoNotTier=>TierRecommended'
$cases = [Collections.Generic.List[object]]::new()
function Add-Case([object] $Case) { $cases.Add($Case) }

Add-Case (New-Case S01 'missing tiering, audit' @((New-Vault v1 @((New-Policy -Mode Missing)))) @('v1/smart-tiering-canary=WouldEnableTierRecommended') -Options @{LegacyCompatible=$true})
$p=New-Policy -Mode DoNotTier; Set-Note $p.properties resourceGuardOperationRequests @('read-only')
Add-Case (New-Case S02 'DoNotTier apply and body preservation' @((New-Vault v1 @($p))) @('v1/smart-tiering-canary=EnabledAndVerified') -Apply $true -Options @{Parameters=(Exact-Parameters smart-tiering-canary);ExpectedSummary=(New-ExpectedSummary 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffGuard);LegacyCompatible=$true})
Add-Case (New-Case S03 'TierAfter preserved' @((New-Vault v1 @((New-Policy -Mode TierAfter)))) @('v1/smart-tiering-canary=AlreadyEnabledAlternateMode') -Apply $true -Options @{Parameters=(Exact-Parameters smart-tiering-canary);LegacyCompatible=$true})
Add-Case (New-Case S04 'TierRecommended idempotence' @((New-Vault v1 @((New-Policy)))) @('v1/smart-tiering-canary=AlreadyCompliant') -Apply $true -Options @{Parameters=(Exact-Parameters smart-tiering-canary);LegacyCompatible=$true})
Add-Case (New-Case S05 'Invalid mode skipped' @((New-Vault v1 @((New-Policy -Mode Invalid)))) @('v1/smart-tiering-canary=SkippedUnknownMode') -Apply $true -Options @{Parameters=(Exact-Parameters smart-tiering-canary);LegacyCompatible=$true})
Add-Case (New-Case S06 'ZRS vault skipped' @((New-Vault v1 @((New-Policy -Mode Missing)) ZRS)) @('v1/-=SkippedZoneRedundantVault') -Options @{Check='Zrs';LegacyCompatible=$true})
Add-Case (New-Case S07 'AzureWorkload policy skipped' @((New-Vault v1 @((New-Policy -Template workloadPolicy -Name HourlyLogBackup -Mode Missing)))) @('v1/HourlyLogBackup=SkippedUnsupportedWorkload') -Options @{LegacyCompatible=$true})
$v1=New-Vault v1 @((New-Policy -Name p1 -Mode Missing),(New-Policy -Template workloadPolicy -Name sql1 -Mode Missing)); $v2=New-Vault v2 @((New-Policy -Name p2))
Add-Case (New-Case S08 'vault and policy nextLink pagination' @($v1,$v2) @('v1/p1=WouldEnableTierRecommended','v1/sql1=SkippedUnsupportedWorkload','v2/p2=AlreadyCompliant') -Options @{PaginateVaults=$true;PaginatePolicies=$true;Check='Pagination';LegacyCompatible=$true})
Add-Case (New-Case S09 '429 GET retries then succeeds' @((New-Vault v1 @((New-Policy -Name retry -Mode Missing)))) @('v1/retry=WouldEnableTierRecommended') -Options @{FaultKind='PolicyGet';FaultVault='v1';FaultPolicy='retry';FaultCode=429;FaultCount=1;Check='Retry429';LegacyCompatible=$true})
$v=New-Vault v1 @((New-Policy -Name broken -Mode Missing),(New-Policy -Name later))
Add-Case (New-Case S10 'policy failure is isolated from sibling' @($v) @('v1/broken=Error','v1/later=AlreadyCompliant') -Options @{FaultKind='PolicyGet';FaultVault='v1';FaultPolicy='broken';FaultCode=500;FaultCount=4;ExpectedSummary=(New-ExpectedSummary 0 0 0 0 1);ExpectedThrow=$true;Check='PolicyIsolation'})
Add-Case (New-Case S11 'two stale verification GETs' @((New-Vault v1 @((New-Policy -Name lag -Mode DoNotTier)))) @('v1/lag=EnabledAndVerified') -Apply $true -Options @{Parameters=(Exact-Parameters lag);VerifyLag=2;ExpectedSummary=(New-ExpectedSummary 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);ExpectedThrow=$false;Check='VerifyLag';LegacyCompatible=$true})
Add-Case (New-Case S12 'properties mutate before write' @((New-Vault v1 @((New-Policy -Name race -Mode DoNotTier)))) @('v1/race=Error') -Apply $true -Options @{Parameters=(Exact-Parameters race);MutatePolicy='race';ExpectedSummary=(New-ExpectedSummary 0 0 0 0 1);ExpectedThrow=$true;Check='Concurrency';LegacyCompatible=$true})
$v1=New-Vault v1 @((New-Policy -Name target -Mode Missing),(New-Policy -Name noise)); $v2=New-Vault v2 @((New-Policy -Name target),(New-Policy -Name noise2))
Add-Case (New-Case S13 'subscription PolicyName matches two vaults' @($v1,$v2) @('v1/target=WouldEnableTierRecommended','v2/target=AlreadyCompliant') -Scope Subscription -ResourceGroup $null -Options @{Parameters=@{PolicyName='target'};Check='ExactFilter';LegacyCompatible=$true})
Add-Case (New-Case S14 'PolicyName matches nothing and fails closed' @((New-Vault v1 @((New-Policy -Name real)))) @() -Apply $true -Options @{Parameters=@{VaultName='v1';PolicyName='typo'};ExpectedSummary=(New-ExpectedSummary 0 0 0 0 0 NoPolicyMatched);ExpectedThrow=$true})
Add-Case (New-Case S15 'ResourceGroup scope missing name' @() @() -ResourceGroup '' -Options @{ExpectedSummary=$null;ExpectedThrow=$true;ExpectedThrowLike='ResourceGroupName is required when ScopeType is ResourceGroup.';Check='ZeroArm';LegacyCompatible=$true})
$v1=New-Vault good1 @((New-Policy -Name p1)); $v2=New-Vault bad @((New-Policy -Name p2)); $v3=New-Vault good2 @((New-Policy -Name p3 -Mode TierAfter))
Add-Case (New-Case S16 'one bad vault in a three-vault run' @($v1,$v2,$v3) @('good1/p1=AlreadyCompliant','bad/-=Error','good2/p3=AlreadyEnabledAlternateMode') -Options @{FaultKind='VaultGet';FaultVault='bad';FaultCode=500;FaultCount=4;ExpectedSummary=(New-ExpectedSummary 0 0 0 0 1);ExpectedThrow=$true;Check='VaultIsolation';LegacyCompatible=$true})
$p=New-Policy -Name tagged -Mode DoNotTier; Set-Note $p tags ([pscustomobject]@{Owner='backup-team'}); Set-Note $p eTag 'W/"42"'; Set-Note $p location eastus2
Add-Case (New-Case S17 'root tags, location and eTag preservation' @((New-Vault v1 @($p))) @('v1/tagged=EnabledAndVerified') -Apply $true -Options @{Parameters=(Exact-Parameters tagged);ExpectedSummary=(New-ExpectedSummary 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);Check='Tags'})
Add-Case (New-Case S18 'protected item default limit' @((New-Vault v1 @((New-Policy -Name protected -Mode DoNotTier -ProtectedCount 5)))) @('v1/protected=SkippedProtectedItemsExceedLimit') -Apply $true -Options @{Variant='default';Parameters=(Exact-Parameters protected)})
Add-Case (New-Case S18 'protected item explicit opt-in' @((New-Vault v1 @((New-Policy -Name protected -Mode DoNotTier -ProtectedCount 5)))) @('v1/protected=EnabledAndVerified') -Apply $true -Options @{Variant='limit=5';Parameters=@{VaultName='v1';PolicyName='protected';MaxProtectedItemsPerPolicy=5;AllowWriteWithoutETag=$true};ExpectedSummary=(New-ExpectedSummary 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier)})
Add-Case (New-Case S19 '202 operation exceeds polling budget' @((New-Vault v1 @((New-Policy -Name uncertain -Mode DoNotTier)))) @('v1/uncertain=WriteOutcomeUnknown') -Apply $true -Options @{Parameters=@{VaultName='v1';PolicyName='uncertain';OperationTimeoutSeconds=1};AsyncKind='AsyncTimeout';ExpectedSummary=(New-ExpectedSummary 0 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);ExpectedThrow=$true;Check='LroUnknown'})
Add-Case (New-Case S20 '202 Location reaches Succeeded' @((New-Vault v1 @((New-Policy -Name async -Mode DoNotTier)))) @('v1/async=EnabledAndVerified') -Apply $true -Options @{Parameters=(Exact-Parameters async);AsyncKind='Location';ExpectedSummary=(New-ExpectedSummary 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);Check='LroSuccess'})
$v=New-Vault v1 @((New-Policy -Template defaultPolicy -Name DefaultPolicy -Mode Missing),(New-Policy -Name eligible -Mode DoNotTier))
Add-Case (New-Case S21 'daily-only default skipped; sibling enabled' @($v) @('v1/DefaultPolicy=SkippedNoArchiveEligibility','v1/eligible=EnabledAndVerified') -Apply $true -Options @{Parameters=@{AllowUnfilteredApply=$true};ExpectedSummary=(New-ExpectedSummary 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);Check='Eligibility'})
Add-Case (New-Case S22 'HTTP error without ErrorDetails keeps status' @((New-Vault v1 @((New-Policy -Name nodetail -Mode Missing)))) @('v1/nodetail=Error') -Options @{FaultKind='PolicyGet';FaultVault='v1';FaultPolicy='nodetail';FaultCode=500;FaultCount=4;FaultNoDetails=$true;ExpectedSummary=(New-ExpectedSummary 0 0 0 0 1);ExpectedThrow=$true;Check='ErrorDetails'})
Add-Case (New-Case S23 'whitespace VaultName rejected' @((New-Vault v1 @((New-Policy)))) @() -Options @{Parameters=@{VaultName='   '};ExpectedSummary=$null;ExpectedThrow=$true;ExpectedThrowLike='*VaultName was supplied but is blank*';Check='ZeroArm'})
Add-Case (New-Case S24 'unfiltered Apply rejected' @((New-Vault v1 @((New-Policy -Mode DoNotTier)))) @() -Apply $true -Options @{ExpectedSummary=$null;ExpectedThrow=$true;ExpectedThrowLike='*VaultName*PolicyName*AllowUnfilteredApply*';Check='ZeroArm'})
Add-Case (New-Case S25 'ResourceGroupName invalid at subscription scope' @() @() -Scope Subscription -ResourceGroup 'rg-test' -Options @{ExpectedSummary=$null;ExpectedThrow=$true;ExpectedThrowLike='*ResourceGroupName*Subscription*';Check='ZeroArm'})
$v=New-Vault v1 @((New-Policy -Name p1 -Mode DoNotTier),(New-Policy -Name p2 -Mode DoNotTier),(New-Policy -Name p3 -Mode DoNotTier))
Add-Case (New-Case S26 'three candidates exceed MaxChanges one' @($v) @('v1/p1=WouldEnableTierRecommended','v1/p2=WouldEnableTierRecommended','v1/p3=WouldEnableTierRecommended') -Apply $true -Options @{Parameters=@{AllowUnfilteredApply=$true;MaxChanges=1};ExpectedSummary=(New-ExpectedSummary 0 0 0 0 0 MaxChangesExceeded);ExpectedThrow=$true})
Add-Case (New-Case S27 'ExpectedMatches mismatch aborts' @((New-Vault v1 @((New-Policy -Name only -Mode DoNotTier)))) @('v1/only=WouldEnableTierRecommended') -Apply $true -Options @{Parameters=@{VaultName='v1';PolicyName='only';ExpectedMatches=2};ExpectedSummary=(New-ExpectedSummary 0 0 0 0 0 ExpectedMatchesMismatch);ExpectedThrow=$true})
Add-Case (New-Case S28 '401 GET refreshes managed identity token' @((New-Vault v1 @((New-Policy -Name refresh -Mode Missing)))) @('v1/refresh=WouldEnableTierRecommended') -Options @{FaultKind='PolicyGet';FaultVault='v1';FaultPolicy='refresh';FaultCode=401;FaultCount=1;Check='TokenRefresh'})
Add-Case (New-Case S29 '429 honors Retry-After two seconds' @((New-Vault v1 @((New-Policy -Name throttle -Mode Missing)))) @('v1/throttle=WouldEnableTierRecommended') -Options @{Parameters=@{RequestTimeoutSeconds=37};FaultKind='PolicyGet';FaultVault='v1';FaultPolicy='throttle';FaultCode=429;FaultCount=1;RetryAfter=2;Check='RetryAfter'})
Add-Case (New-Case S30 'asynchronous operation reports Failed' @((New-Vault v1 @((New-Policy -Name failed -Mode DoNotTier)))) @('v1/failed=Error') -Apply $true -Options @{Parameters=(Exact-Parameters failed);AsyncKind='AsyncFailed';ExpectedSummary=(New-ExpectedSummary 0 1 0 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);ExpectedThrow=$true;Check='LroFailed'})
Add-Case (New-Case S31 'transport loss reconciles applied PUT' @((New-Vault v1 @((New-Policy -Name reconciled -Mode DoNotTier)))) @('v1/reconciled=EnabledAndVerified') -Apply $true -Options @{Parameters=(Exact-Parameters reconciled);AsyncKind='Unused';TransportPut=$true;ExpectedSummary=(New-ExpectedSummary 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);Check='TransportReconcile'})
Add-Case (New-Case S32 'reordered JSON members compare equal' @((New-Vault v1 @((New-Policy -Name reordered -Mode DoNotTier)))) @('v1/reordered=EnabledAndVerified') -Apply $true -Options @{Parameters=(Exact-Parameters reordered);ReorderPolicy='reordered';ExpectedSummary=(New-ExpectedSummary 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);Check='Reorder'})
$p8=Set-MonthlyHorizon (New-Policy -Name retention8 -Mode Missing) 8; $p9=Set-MonthlyHorizon (New-Policy -Name retention9 -Mode Missing) 9
Add-Case (New-Case S33 'eight-month skipped; nine-month candidate' @((New-Vault v1 @($p8,$p9))) @('v1/retention8=SkippedNoArchiveEligibility','v1/retention9=WouldEnableTierRecommended') -Options @{Check='Horizon'})

$p=New-Policy -Name lexical -Mode DoNotTier; Set-Note $p tags ([pscustomobject]@{when='2026-08-25T02:00:00+03:00'}); $v=New-Vault v1 @($p)
$rawS34=$p|ConvertTo-Json -Depth 100 -Compress
Add-Case (New-Case S34 'date-like JSON strings remain byte-stable' @($v) @('v1/lexical=EnabledAndVerified') -Apply $true -Options @{Parameters=(Exact-Parameters lexical);RawPolicyJson=@{lexical=$rawS34};ExpectedSummary=(New-ExpectedSummary 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);Check='LexicalJson'})
$v=New-Vault v1 @((New-Policy -Name hidden -Mode DoNotTier))
Add-Case (New-Case S35 'missing vault redundancy fails discovery closed' @($v) @('v1/-=Error') -Options @{Variant='audit';MissingRedundancyVault='v1';ExpectedSummary=(New-ExpectedSummary 0 0 0 0 1);ExpectedThrow=$true;Check='MissingRedundancy'})
Add-Case (New-Case S35 'missing vault redundancy fails discovery closed' @($v) @('v1/-=Error') -Apply $true -Options @{Variant='apply';Parameters=(Exact-Parameters hidden);MissingRedundancyVault='v1';ExpectedSummary=(New-ExpectedSummary 0 0 0 0 1 DiscoveryErrors);ExpectedThrow=$true;Check='MissingRedundancy'})
$p=New-Policy -Name unknown-count -Mode DoNotTier; $p.properties.PSObject.Properties.Remove('protectedItemsCount')
Add-Case (New-Case S36 'missing protected-items count is not writable' @((New-Vault v1 @($p))) @('v1/unknown-count=SkippedProtectedItemsUnknown') -Apply $true -Options @{Parameters=(Exact-Parameters unknown-count);Check='ProtectedItemsUnknown'})
$p=New-Policy -Name sibling-drift -Mode DoNotTier; Set-Note $p.properties.tieringPolicy OtherRP ([pscustomobject]@{rule='KEEP'})
Add-Case (New-Case S37 'verification detects sibling tiering drift' @((New-Vault v1 @($p))) @('v1/sibling-drift=Error') -Apply $true -Options @{Parameters=(Exact-Parameters sibling-drift);VerifyTieringDriftPolicy='sibling-drift';ExpectedSummary=(New-ExpectedSummary 0 1 0 0 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);ExpectedThrow=$true;Check='TieringSiblingDrift'})
Add-Case (New-Case S38 'foreign vault continuation is rejected before transport' @((New-Vault v1 @((New-Policy -Name unseen)))) @() -Options @{ForeignVaultNextLink='https://evil.example.com/next';ExpectedSummary=$null;ExpectedThrow=$true;ExpectedThrowLike='*non-ARM URL*';Check='ForeignUrl'})
Add-Case (New-Case S39 'late 401 refresh has an independent retry' @((New-Vault v1 @((New-Policy -Name late-refresh -Mode Missing)))) @('v1/late-refresh=WouldEnableTierRecommended') -Options @{FaultKind='PolicyGet';FaultVault='v1';FaultPolicy='late-refresh';FaultSequence=@(500,500,500,401);Check='LateTokenRefresh'})
$v=New-Vault v1 @((New-Policy -Name lost-applied -Mode DoNotTier))
Add-Case (New-Case S40 'ambiguous PUT transport loss is reconciled without resubmit' @($v) @('v1/lost-applied=EnabledAndVerified') -Apply $true -Options @{Variant='applied-on-third-read';Parameters=(Exact-Parameters lost-applied);TransportPut=$true;TransportApplies=$true;VerifyLag=2;ExpectedSummary=(New-ExpectedSummary 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);Check='TransportThirdRead'})
$v=New-Vault v1 @((New-Policy -Name lost-unknown -Mode DoNotTier))
Add-Case (New-Case S40 'ambiguous PUT transport loss is reconciled without resubmit' @($v) @('v1/lost-unknown=WriteOutcomeUnknown') -Apply $true -Options @{Variant='never-applied';Parameters=(Exact-Parameters lost-unknown);TransportPut=$true;TransportApplies=$false;ExpectedSummary=(New-ExpectedSummary 0 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);ExpectedThrow=$true;Check='TransportNeverApplied'})
Add-Case (New-Case S41 'HTTP 400 is definitive and not retried' @((New-Vault v1 @((New-Policy -Name bad-request -Mode Missing)))) @('v1/bad-request=Error') -Options @{FaultKind='PolicyGet';FaultVault='v1';FaultPolicy='bad-request';FaultCode=400;FaultCount=1;ExpectedSummary=(New-ExpectedSummary 0 0 0 0 1);ExpectedThrow=$true;Check='NonRetry400'})
$p=New-Policy -Name protected-no-etag -Mode DoNotTier -ProtectedCount 5
Add-Case (New-Case S42 'protected write requires and forwards a concurrency token' @((New-Vault v1 @($p))) @('v1/protected-no-etag=SkippedNoConcurrencyToken') -Apply $true -Options @{Variant='missing-eTag';Parameters=@{VaultName='v1';PolicyName='protected-no-etag';MaxProtectedItemsPerPolicy=5;AllowWriteWithoutETag=$false}})
$p=New-Policy -Name protected-etag -Mode DoNotTier -ProtectedCount 5; Set-Note $p eTag 'W/"s42"'
Add-Case (New-Case S42 'protected write requires and forwards a concurrency token' @((New-Vault v1 @($p))) @('v1/protected-etag=EnabledAndVerified') -Apply $true -Options @{Variant='with-eTag';Parameters=@{VaultName='v1';PolicyName='protected-etag';MaxProtectedItemsPerPolicy=5;AllowWriteWithoutETag=$false};ExpectedSummary=(New-ExpectedSummary 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);Check='IfMatch'})
Add-Case (New-Case S43 'Retry-After precedes the first async-operation poll' @((New-Vault v1 @((New-Policy -Name delayed-poll -Mode DoNotTier)))) @('v1/delayed-poll=EnabledAndVerified') -Apply $true -Options @{Parameters=(Exact-Parameters delayed-poll);AsyncKind='AsyncSuccess';AsyncRetryAfter=3;ExpectedSummary=(New-ExpectedSummary 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);Check='LroFirstDelay'})
Add-Case (New-Case S44 'operation poll transport exhaustion stays unknown' @((New-Vault v1 @((New-Policy -Name poll-unknown -Mode DoNotTier)))) @('v1/poll-unknown=WriteOutcomeUnknown') -Apply $true -Options @{Parameters=(Exact-Parameters poll-unknown);AsyncKind='AsyncPollTransport';OperationTransportFailures=4;ExpectedSummary=(New-ExpectedSummary 0 1 1);ExpectedPuts=1;ExpectedDiffs=@($diffDoNotTier);ExpectedThrow=$true;Check='LroPollTransport'})
Add-Case (New-Case S45 'ZRS skip serialises absent policy fields as null' @((New-Vault v1 @((New-Policy -Mode Missing)) ZRS)) @('v1/-=SkippedZoneRedundantVault') -Options @{Check='ZrsNull'})

function Throw-MockHttp([int] $Status, [string] $Method, [string] $Uri, [AllowNull()][string] $BodyText, [AllowNull()][object] $RetryAfter) {
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Status)
    $response.RequestMessage = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Uri)
    if ($null -ne $BodyText) { $response.Content = [Net.Http.StringContent]::new($BodyText, [Text.Encoding]::UTF8, 'application/json') }
    if ($null -ne $RetryAfter) { [void]$response.Headers.TryAddWithoutValidation('Retry-After', [string[]]@([string]$RetryAfter)) }
    $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new("mock HTTP $Status for $Uri", $response)
    $record = [Management.Automation.ErrorRecord]::new($exception, 'MockArmHttp', [Management.Automation.ErrorCategory]::InvalidOperation, $Uri)
    if ($null -ne $BodyText) { $record.ErrorDetails = [Management.Automation.ErrorDetails]::new($BodyText) }
    throw $record
}
function Invoke-Fault([string] $Method, [string] $Uri) {
    $state = $global:MockState
    $key = "$Method $Uri"
    if ($Key -ne $state.FaultKey) { return }
    $status = $null
    if ($state.FaultIndex -lt $state.FaultCodes.Count) {
        $status = [int]$state.FaultCodes[$state.FaultIndex]
        $state.FaultIndex++
    }
    elseif ($state.FaultRemaining -gt 0) {
        $state.FaultRemaining--
        $status = [int]$state.Case.FaultCode
    }
    if ($null -ne $status) {
        $body = if ($state.Case.FaultNoDetails) { $null } else { "{`"error`":{`"code`":`"Mock$status`",`"message`":`"forced`"}}" }
        Throw-MockHttp $status $Method $Uri $body $state.Case.RetryAfter
    }
}
function Get-ReorderedPolicy([object] $Policy) {
    $copy = Copy-Object $Policy; $ordered = [ordered]@{}
    foreach ($property in @($copy.properties.PSObject.Properties)[-1..-(@($copy.properties.PSObject.Properties).Count)]) { $ordered[$property.Name] = $property.Value }
    $copy.properties = [pscustomobject]$ordered
    return $copy
}
function Set-MockUpdatedPolicy([object] $State, [string] $Uri, [object] $Parsed, [string] $Raw) {
    $updated = Copy-Object $State.Policies[$Uri]
    $updated.properties = Copy-Object $Parsed.properties
    foreach ($name in @('location','tags','eTag')) {
        $property = $Parsed.PSObject.Properties[$name]
        if ($null -ne $property) { Set-Note $updated $name (Copy-Object $property.Value) }
        elseif ($name -eq 'tags' -and $null -ne $updated.PSObject.Properties[$name]) { $updated.PSObject.Properties.Remove($name) }
    }
    $State.Updated[$Uri] = $updated; $State.UpdatedRaw[$Uri] = $Raw; $State.AfterPut[$Uri] = $true
}

function global:Start-Sleep {
    [CmdletBinding()] param([double] $Seconds=0, [int] $Milliseconds=0)
    $wait = if ($PSBoundParameters.ContainsKey('Milliseconds')) { $Milliseconds / 1000.0 } else { $Seconds }
    $global:MockState.Sleeps.Add([double]$wait)
    $global:MockState.Events.Add([pscustomobject]@{Kind='Sleep';Seconds=[double]$wait;Method=$null;Uri=$null})
    # Let wall-clock deadline implementations finish S19 without a busy loop.
    if ($global:MockState.Case.Id -eq 'S19') { [Threading.Thread]::Sleep(100) }
}
function global:Invoke-WebRequest {
    # v1.1 reads raw JSON text through Invoke-WebRequest; delegate to the Invoke-RestMethod mock and
    # wrap its result the way BasicHtmlWebResponseObject exposes it (StatusCode, Headers, Content).
    param($Uri,$Method='GET',$Headers,$Body,$ContentType,$ErrorAction,$TimeoutSec,$ConnectionTimeoutSeconds,$OperationTimeoutSeconds,$SkipHttpErrorCheck,$UseBasicParsing)
    $sc = $null; $rh = $null
    $splat = @{ Uri = $Uri; Method = $Method; ErrorAction = 'Stop'; StatusCodeVariable = 'sc'; ResponseHeadersVariable = 'rh' }
    if ($null -ne $Headers) { $splat.Headers = $Headers }
    if ($null -ne $Body) { $splat.Body = $Body }
    if ($null -ne $ContentType) { $splat.ContentType = $ContentType }
    $bound = if ($null -ne $ConnectionTimeoutSeconds) { $ConnectionTimeoutSeconds } elseif ($null -ne $OperationTimeoutSeconds) { $OperationTimeoutSeconds } else { $TimeoutSec }
    if ($null -ne $bound) { $splat.TimeoutSec = $bound }
    $out = Invoke-RestMethod @splat
    $raw = $global:MockState.LastRawContent
    $content = if ($null -ne $raw) { [string]$raw } elseif ($null -eq $out) { '' } elseif ($out -is [string]) { $out } else { ($out | ConvertTo-Json -Depth 100 -Compress) }
    if ($env:HARNESS_DEBUG) { Add-Content -Path $env:HARNESS_DEBUG -Value ("$Method $Uri -> sc=$sc type=$($(if($null -eq $out){'null'}else{$out.GetType().FullName})) content=" + $content.Substring(0,[Math]::Min(400,$content.Length))) }
    if ($null -eq $sc) { $sc = 200 }
    if ($null -eq $rh) { $rh = @{} }
    return [pscustomobject]@{ StatusCode = [int]$sc; Headers = $rh; Content = $content }
}
function global:Invoke-RestMethod {
    # CmdletBinding supplies the common -ErrorAction parameter; redeclaring it is invalid.
    [CmdletBinding()] param(
        [Parameter(Mandatory)] $Uri, $Method='GET', [AllowNull()][object] $Headers,
        [AllowNull()][object] $Body, [AllowNull()][string] $ContentType,
        [AllowNull()][object] $TimeoutSec, [AllowNull()][string] $StatusCodeVariable,
        [AllowNull()][string] $ResponseHeadersVariable
    )
    $verb = $Method.ToString().ToUpperInvariant(); $uriText=[string]$Uri; $state=$global:MockState
    $state.LastRawContent=$null
    $state.Calls.Add([pscustomobject]@{Method=$verb;Uri=$uriText;Headers=(Copy-Object $Headers);Body=$Body
        ContentType=$ContentType;TimeoutSec=$TimeoutSec;ErrorAction=[string](Get-Value $PSBoundParameters ErrorAction '')})
    $state.Events.Add([pscustomobject]@{Kind='Call';Seconds=$null;Method=$verb;Uri=$uriText})
    $status=200; $responseHeaders=@{}; $result=$null
    if ($uriText -eq $env:IDENTITY_ENDPOINT) {
        if ($verb -ne 'POST') { throw "Mock identity endpoint requires POST, received $verb" }
        $state.TokenPosts++; $result=[pscustomobject]@{access_token="mock-token-$($state.TokenPosts)"}
    }
    elseif ($verb -eq 'PUT' -and $state.Policies.ContainsKey($uriText)) {
        $parsed=$Body | ConvertFrom-Json
        $state.Puts.Add([pscustomobject]@{Uri=$uriText;Raw=$Body;Parsed=$parsed;Headers=(Copy-Object $Headers);Source=(Copy-Object $state.Policies[$uriText])})
        $state.PutAttempted[$uriText]=$true
        Invoke-Fault $verb $uriText
        $transportLost = $state.TransportRemaining -gt 0
        if (-not $transportLost -or $state.Case.TransportApplies) { Set-MockUpdatedPolicy $state $uriText $parsed ([string]$Body) }
        if ($transportLost) { $state.TransportRemaining--; throw [Net.Http.HttpRequestException]::new("mock transport failure after PUT for $uriText") }
        if ($state.Case.AsyncKind) {
            $status=202
            if ($state.Case.AsyncKind -eq 'Location') { $responseHeaders=@{Location=$state.OperationUri;'Retry-After'=[string]$state.Case.AsyncRetryAfter} }
            else { $responseHeaders=@{'Azure-AsyncOperation'=$state.OperationUri;Location=$state.OperationUri;'Retry-After'=[string]$state.Case.AsyncRetryAfter} }
        }
        $result=Copy-Object $state.Updated[$uriText]
    }
    else {
        Invoke-Fault $verb $uriText
        if ($verb -eq 'GET' -and $uriText -eq $state.OperationUri) {
            $state.OperationCalls++
            if ($state.OperationTransportRemaining -gt 0) {
                $state.OperationTransportRemaining--
                throw [Net.Http.HttpRequestException]::new("mock operation-poll transport failure for $uriText")
            }
            switch ($state.Case.AsyncKind) {
                AsyncTimeout { $status=200; $responseHeaders=@{'Retry-After'='1'}; $result=[pscustomobject]@{status='InProgress'} }
                Location { if ($state.OperationCalls -eq 1) {$status=202} else {$status=200}; $responseHeaders=@{'Retry-After'='1'}; $result=[pscustomobject]@{} }
                AsyncFailed { $status=200; $result=[pscustomobject]@{status='Failed';error=[pscustomobject]@{code='OperationRejected';message='mock LRO failure'}} }
                default { $status=200; $result=[pscustomobject]@{status='Succeeded'} }
            }
        }
        elseif ($verb -eq 'GET' -and $state.Pages.ContainsKey($uriText)) { $result=Copy-Object $state.Pages[$uriText] }
        elseif ($verb -eq 'GET' -and $state.VaultDetails.ContainsKey($uriText)) { $result=Copy-Object $state.VaultDetails[$uriText] }
        elseif ($verb -eq 'GET' -and $state.Policies.ContainsKey($uriText)) {
            if (-not $state.Reads.ContainsKey($uriText)) { $state.Reads[$uriText]=0 }; $state.Reads[$uriText]++
            $source=$state.Policies[$uriText]
            $postPutRead=0
            if($state.PutAttempted.ContainsKey($uriText)){
                if(-not $state.PostPutReads.ContainsKey($uriText)){$state.PostPutReads[$uriText]=0};$state.PostPutReads[$uriText]++
                $postPutRead=$state.PostPutReads[$uriText]
            }
            if ($state.Case.MutatePolicy -eq $source.name -and $state.Reads[$uriText] -eq 2) { $result=Copy-Object $source; $result.properties.timeZone='Pacific Standard Time' }
            elseif ($state.Case.ReorderPolicy -eq $source.name -and $state.Reads[$uriText] -eq 2) { $result=Get-ReorderedPolicy $source }
            elseif ($state.AfterPut.ContainsKey($uriText)) {
                if ($state.VerifyRemaining -gt 0) {
                    $state.VerifyRemaining--; $result=Copy-Object $source
                    if($state.RawPolicies.ContainsKey($uriText)){$state.LastRawContent=$state.RawPolicies[$uriText]}
                }
                else {
                    $result=Copy-Object $state.Updated[$uriText]
                    if(-not $state.FirstUpdatedPostPutRead.ContainsKey($uriText)){$state.FirstUpdatedPostPutRead[$uriText]=$postPutRead}
                    if($state.Case.VerifyTieringDriftPolicy -eq $source.name){$result.properties.tieringPolicy.OtherRP.rule='DESTROYED';$state.LastRawContent=($result|ConvertTo-Json -Depth 100 -Compress)}
                    elseif($state.UpdatedRaw.ContainsKey($uriText)){$state.LastRawContent=$state.UpdatedRaw[$uriText]}
                }
            }
            else { $result=Copy-Object $source;if($state.RawPolicies.ContainsKey($uriText)){$state.LastRawContent=$state.RawPolicies[$uriText]} }
        }
        else { throw "Mock has no route for $verb $uriText" }
    }
    # Scope 1 is the runbook helper that directly called Invoke-RestMethod (verified on pwsh 7.4).
    if (-not [string]::IsNullOrWhiteSpace($StatusCodeVariable)) { Set-Variable -Name $StatusCodeVariable -Value $status -Scope 1 }
    if (-not [string]::IsNullOrWhiteSpace($ResponseHeadersVariable)) { Set-Variable -Name $ResponseHeadersVariable -Value $responseHeaders -Scope 1 }
    return $result
}

function New-MockState([object] $Case) {
    $state=[pscustomobject]@{Case=$Case;Calls=[Collections.Generic.List[object]]::new();Sleeps=[Collections.Generic.List[double]]::new();Events=[Collections.Generic.List[object]]::new()
        Puts=[Collections.Generic.List[object]]::new();Pages=@{};VaultDetails=@{};Policies=@{};RawPolicies=@{};Reads=@{};Updated=@{};UpdatedRaw=@{};AfterPut=@{};PutAttempted=@{};PostPutReads=@{};FirstUpdatedPostPutRead=@{}
        FaultKey='';FaultRemaining=$Case.FaultCount;FaultCodes=@($Case.FaultSequence);FaultIndex=0;VerifyRemaining=$Case.VerifyLag;TransportRemaining=$(if($Case.TransportPut){1}else{0})
        TokenPosts=0;OperationCalls=0;OperationTransportRemaining=$Case.OperationTransportFailures;OperationUri="$management/mock-operation/$($Case.Id)-$($Case.Variant)";VaultListUri='';LastRawContent=$null}
    $state.VaultListUri=if($Case.Scope -eq 'Subscription'){"$management/subscriptions/$subscription/providers/Microsoft.RecoveryServices/vaults?api-version=$apiVersion"}else{"$management/subscriptions/$subscription/resourceGroups/$($Case.ResourceGroup)/providers/Microsoft.RecoveryServices/vaults?api-version=$apiVersion"}
    $items=@($Case.Vaults|ForEach-Object{[pscustomobject]@{id=$_.id;name=$_.name;type='Microsoft.RecoveryServices/vaults'}})
    if(-not [string]::IsNullOrWhiteSpace($Case.ForeignVaultNextLink)){$state.Pages[$state.VaultListUri]=[pscustomobject]@{value=$items;nextLink=$Case.ForeignVaultNextLink}}
    elseif($Case.PaginateVaults){$next="$management/mock/vaults?page=2";$state.Pages[$state.VaultListUri]=[pscustomobject]@{value=@($items[0]);nextLink=$next};$state.Pages[$next]=[pscustomobject]@{value=@($items[1..($items.Count-1)])}}
    else{$state.Pages[$state.VaultListUri]=[pscustomobject]@{value=$items}}
    foreach($vault in $Case.Vaults){
        $detail="$management$($vault.id)?api-version=$apiVersion";$state.VaultDetails[$detail]=[pscustomobject]@{id=$vault.id;name=$vault.name;properties=[pscustomobject]@{redundancySettings=[pscustomobject]@{standardTierStorageRedundancy=$vault.redundancy;crossRegionRestore='Disabled'}}}
        if($Case.MissingRedundancyVault -eq $vault.name){$state.VaultDetails[$detail].properties.PSObject.Properties.Remove('redundancySettings')}
        $list="$management$($vault.id)/backupPolicies?api-version=$apiVersion"
        if($Case.PaginatePolicies -and $vault -eq $Case.Vaults[0]){$next="$management/mock/policies/$($vault.name)?page=2";$state.Pages[$list]=[pscustomobject]@{value=@($vault.policies[0]);nextLink=$next};$state.Pages[$next]=[pscustomobject]@{value=@($vault.policies[1..($vault.policies.Count-1)])}}
        else{$state.Pages[$list]=[pscustomobject]@{value=@($vault.policies)}}
        foreach($policy in $vault.policies){$uri="$management$($policy.id)?api-version=$apiVersion";$state.Policies[$uri]=Copy-Object $policy
            $rawPolicy=Get-Value $Case.RawPolicyJson $policy.name $null;if($null -ne $rawPolicy){$state.RawPolicies[$uri]=[string]$rawPolicy}
            if($Case.FaultVault -eq $vault.name -and $Case.FaultPolicy -eq $policy.name){if($Case.FaultKind -eq 'PolicyGet'){$state.FaultKey="GET $uri"};if($Case.FaultKind -eq 'PolicyPut'){$state.FaultKey="PUT $uri"}}}
        if($Case.FaultKind -eq 'VaultGet' -and $Case.FaultVault -eq $vault.name){$state.FaultKey="GET $detail"}
    }
    return $state
}

function Get-Diff([AllowNull()][object] $Before,[AllowNull()][object] $After,[string] $Path='') {
    if($null -eq $Before -or $null -eq $After){if($null -ne $Before -or $null -ne $After){return "~${Path}:$Before=>$After"};return}
    $bp=@($Before.PSObject.Properties);$ap=@($After.PSObject.Properties)
    if($Before -is [pscustomobject] -and $After -is [pscustomobject] -and $bp.Count -gt 0 -and $ap.Count -gt 0){
        foreach($name in @(@($bp.Name)+@($ap.Name)|Sort-Object -Unique)){$child=if($Path){"$Path.$name"}else{$name};$b=$Before.PSObject.Properties[$name];$a=$After.PSObject.Properties[$name]
            if($null -eq $b){"+$child"}elseif($null -eq $a){"-$child"}else{Get-Diff $b.Value $a.Value $child}}
    }elseif(($Before|ConvertTo-Json -Depth 100 -Compress) -ne ($After|ConvertTo-Json -Depth 100 -Compress)){"~${Path}:$Before=>$After"}
}
function Get-PutDiff([object] $Put) {
    $before=[ordered]@{properties=Copy-Object $Put.Source.properties}
    foreach($name in @('tags','location','eTag')){if($null -ne $Put.Source.PSObject.Properties[$name]){$before[$name]=Copy-Object $Put.Source.$name}}
    $diff=@(Get-Diff ([pscustomobject]$before) $Put.Parsed)
    return $(if($diff.Count){$diff -join '; '}else{'none'})
}
function Get-RowTarget([object] $Row) {
    $vault=[string](Get-Value $Row vault '');$policy=Get-Value $Row policy $null
    return $(if([string]::IsNullOrEmpty([string]$policy)){"$vault/-"}else{"$vault/$policy"})
}
function Add-Failure([Collections.Generic.List[string]] $Failures,[bool] $Condition,[string] $Message) {
    if(-not $Condition){$Failures.Add($Message)}
}
function Format-Metrics([AllowNull()][object] $Summary) {
    if($null -eq $Summary){return '<no summary>'}
    $values=@('policiesWritten','writesSubmitted','writesUnknown','writesFailed','errors')|ForEach-Object{[string](Get-Value $Summary $_ '[missing]')}
    $abort=Get-Value $Summary abortReason '[missing]';if($null -eq $abort){$abort='<null>'}
    return (($values -join '/')+"/$abort")
}

$isLegacyRunbook=$false;$legacyControlPath=$env:SMART_TIERING_LEGACY_RUNBOOK
if(-not [string]::IsNullOrWhiteSpace($legacyControlPath) -and (Test-Path -LiteralPath $RunbookPath) -and (Test-Path -LiteralPath $legacyControlPath)){try{$resolvedRunbook=(Resolve-Path -LiteralPath $RunbookPath).Path;$resolvedControl=(Resolve-Path -LiteralPath $legacyControlPath).Path;$command=Get-Command -Name $RunbookPath -ErrorAction Stop;$isLegacyRunbook=($resolvedRunbook -ceq $resolvedControl -and -not $command.Parameters.ContainsKey('AllowUnfilteredApply'))}catch{}}

function Invoke-Case([object] $Case) {
    $global:MockState=New-MockState $Case;$records=[Collections.Generic.List[object]]::new();$thrown=$null
    $params=@{SubscriptionId=$subscription;ScopeType=$Case.Scope;Apply=[bool]$Case.Apply;ApiVersion=$apiVersion}
    if($null -ne $Case.ResourceGroup){$params.ResourceGroupName=$Case.ResourceGroup};foreach($key in $Case.Parameters.Keys){$params[$key]=$Case.Parameters[$key]}
    try{& $RunbookPath @params 3>&1|ForEach-Object{$records.Add($_)}}catch{$thrown=$_.Exception.Message}
    $outputs=[Collections.Generic.List[string]]::new();$warnings=[Collections.Generic.List[string]]::new();$orderedRecords=[Collections.Generic.List[object]]::new()
    foreach($record in $records){if($record -is [Management.Automation.WarningRecord]){$warnings.Add($record.Message);$orderedRecords.Add([pscustomobject]@{Warning=$true;Line=$record.Message})}else{$outputs.Add([string]$record);$orderedRecords.Add([pscustomobject]@{Warning=$false;Line=[string]$record})}}
    $outputRows=[Collections.Generic.List[object]]::new();$warningRows=[Collections.Generic.List[object]]::new();$summary=$null;$parseFailures=[Collections.Generic.List[string]]::new()
    foreach($line in $outputs){if($line -like 'SUMMARY *'){try{$summary=$line.Substring(8)|ConvertFrom-Json}catch{$parseFailures.Add("invalid SUMMARY JSON: $($_.Exception.Message)")}}
        elseif($line -match '^\{.*\}$'){try{$outputRows.Add(($line|ConvertFrom-Json))}catch{$parseFailures.Add("invalid output row JSON: $line")}}}
    foreach($line in $warnings){if($line -match '^\{.*\}$'){try{$warningRows.Add(($line|ConvertFrom-Json))}catch{}}}
    $outputSignatures=@{};foreach($row in $outputRows){$outputSignatures[($row|ConvertTo-Json -Depth 100 -Compress)]=$true}
    $combined=[Collections.Generic.List[object]]::new();foreach($item in $orderedRecords){if($item.Line -notmatch '^\{.*\}$'){continue};try{$row=$item.Line|ConvertFrom-Json;$signature=$row|ConvertTo-Json -Depth 100 -Compress;if(-not $item.Warning -or -not $outputSignatures.ContainsKey($signature)){$combined.Add($row)}}catch{}}
    $order=[Collections.Generic.List[string]]::new();$terminal=[ordered]@{}
    foreach($row in $combined){if($null -eq (Get-Value $row action $null)){continue};$target=Get-RowTarget $row;if(-not $terminal.Contains($target)){$order.Add($target)};$terminal[$target]=$row}
    $actualRows=@($order|ForEach-Object{"$_=$([string](Get-Value $terminal[$_] action ''))"});$failures=[Collections.Generic.List[string]]::new();foreach($f in $parseFailures){$failures.Add($f)}
    $expectedRows=@($Case.ExpectedRows)
    if($isLegacyRunbook -and $Case.LegacyCompatible){$ea=@($expectedRows|ForEach-Object{($_ -split '=',2)[1]});$aa=@($actualRows|ForEach-Object{($_ -split '=',2)[1]});Add-Failure $failures (($ea -join ',') -eq ($aa -join ',')) "actions expected '$($ea -join ',')', got '$($aa -join ',')'"}
    else{Add-Failure $failures (($expectedRows -join ',') -eq ($actualRows -join ',')) "policy actions expected '$($expectedRows -join ',')', got '$($actualRows -join ',')'"}
    $effective=$null
    if($null -eq $Case.ExpectedSummary){Add-Failure $failures ($null -eq $summary) "expected no SUMMARY, got '$(Format-Metrics $summary)'"}
    else{
        if($null -eq $summary){Add-Failure $failures $false 'expected SUMMARY but none was emitted';$effective=[pscustomobject]@{policiesWritten='[missing]';writesSubmitted='[missing]';writesUnknown='[missing]';writesFailed='[missing]';errors='[missing]';abortReason='[missing]'}}
        else{$effective=[ordered]@{};foreach($name in @('policiesWritten','writesSubmitted','writesUnknown','writesFailed','errors','abortReason')){$value=Get-Value $summary $name '[missing]'
                if($value -eq '[missing]' -and $isLegacyRunbook -and $Case.LegacyCompatible){$value=switch($name){writesSubmitted{$global:MockState.Puts.Count};writesUnknown{0};writesFailed{0};abortReason{$null};default{'[missing]'}}};$effective[$name]=$value};$effective=[pscustomobject]$effective}
        foreach($name in @('policiesWritten','writesSubmitted','writesUnknown','writesFailed','errors','abortReason')){$expected=Get-Value $Case.ExpectedSummary $name;$actual=Get-Value $effective $name '[missing]';$equal=if($null -eq $expected){$null -eq $actual}else{[string]$expected -eq [string]$actual};Add-Failure $failures $equal "$name expected '$expected', got '$actual'"}
    }
    Add-Failure $failures ($global:MockState.Puts.Count -eq $Case.ExpectedPuts) "PUT count expected $($Case.ExpectedPuts), got $($global:MockState.Puts.Count)"
    $diffs=@($global:MockState.Puts|ForEach-Object{Get-PutDiff $_});$expectedDiffs=@($Case.ExpectedDiffs)
    Add-Failure $failures (($expectedDiffs -join ' || ') -eq ($diffs -join ' || ')) "PUT diff expected '$($expectedDiffs -join ' || ')', got '$($diffs -join ' || ')'"
    Add-Failure $failures (([bool]$thrown) -eq $Case.ExpectedThrow) "throw expected $($Case.ExpectedThrow), got $([bool]$thrown) ('$thrown')"
    if($Case.ExpectedThrowLike){Add-Failure $failures ($null -ne $thrown -and $thrown -like $Case.ExpectedThrowLike) "throw text expected like '$($Case.ExpectedThrowLike)', got '$thrown'"}
    $armCalls=@($global:MockState.Calls|Where-Object{$_.Uri -like "$management/*"})
    if(-not $isLegacyRunbook){$timeout=Get-Value $Case.Parameters RequestTimeoutSeconds 100;$bad=@($armCalls|Where-Object{[int]$_.TimeoutSec -ne [int]$timeout});Add-Failure $failures ($bad.Count -eq 0) "$($bad.Count) ARM call(s) lacked TimeoutSec=$timeout"
        foreach($spec in $expectedRows){$parts=$spec -split '=',2;$found=@($outputRows|Where-Object{(Get-RowTarget $_)-eq $parts[0] -and (Get-Value $_ action '')-eq $parts[1]});Add-Failure $failures ($found.Count -gt 0) "terminal row '$spec' was not written to output";if($parts[1]-eq 'Error'){$warn=@($warningRows|Where-Object{(Get-RowTarget $_)-eq $parts[0] -and (Get-Value $_ action '')-eq 'Error'});Add-Failure $failures ($warn.Count -gt 0) "Error row '$($parts[0])' was not also written as warning"}}
        if($null -ne $Case.ExpectedSummary){Add-Failure $failures ($outputs.Count -gt 0 -and $outputs[$outputs.Count-1] -like 'SUMMARY *') 'SUMMARY was not the final output line'}
    }
    switch($Case.Check){
        Zrs{Add-Failure $failures (@($global:MockState.Calls|Where-Object{$_.Uri -like '*/backupPolicies?*'}).Count -eq 0) 'ZRS policy list/read occurred'}
        Pagination{Add-Failure $failures (@($global:MockState.Calls|Where-Object{$_.Uri -like '*mock/*page=2'}).Count -eq 2) 'both nextLink routes were not called'}
        Retry429{Add-Failure $failures ($global:MockState.Sleeps.Count -ge 1 -and $global:MockState.Sleeps[0] -ge 2) '429 retry/backoff was not observed'}
        PolicyIsolation{$row=Get-Value $terminal 'v1/broken';Add-Failure $failures ((Get-Value $row stage '')-eq 'Evaluate') 'policy error stage was not Evaluate';Add-Failure $failures ((Get-Value $row message '')-like '*HTTP 500*') 'policy error lost HTTP 500';Add-Failure $failures (@($global:MockState.Calls|Where-Object{$_.Uri -like '*/backupPolicies/later?*'}).Count -gt 0) 'sibling policy was not point-read'}
        VerifyLag{Add-Failure $failures (($global:MockState.Sleeps -join ',') -eq '5,5') "verification sleeps expected 5,5, got '$($global:MockState.Sleeps -join ',')'"}
        Concurrency{if($isLegacyRunbook){Add-Failure $failures (@($warnings|Where-Object{$_ -like '*changed after evaluation*'}).Count -gt 0) 'concurrency diagnostic absent'}else{$row=Get-Value $terminal 'v1/race';Add-Failure $failures ((Get-Value $row stage '')-eq 'PreWrite') 'concurrency error stage was not PreWrite'}}
        ExactFilter{Add-Failure $failures (@($global:MockState.Calls|Where-Object{$_.Uri -like '*/backupPolicies/noise*'}).Count -eq 0) 'nonmatching policies were point-read'}
        VaultIsolation{if(-not $isLegacyRunbook){$row=Get-Value $terminal 'bad/-';Add-Failure $failures ((Get-Value $row stage '')-eq 'Discover') 'vault error stage was not Discover'}}
        Tags{if($global:MockState.Puts.Count){$put=$global:MockState.Puts[0];Add-Failure $failures ($null -ne $put.Parsed.PSObject.Properties['tags'] -and $put.Parsed.tags.Owner -eq 'backup-team') 'tags missing/changed in PUT';Add-Failure $failures ($put.Parsed.eTag -eq 'W/"42"' -and $put.Headers.'If-Match' -eq 'W/"42"') 'eTag/If-Match not preserved'}}
        LroUnknown{Add-Failure $failures ($global:MockState.OperationCalls -gt 0) 'async operation URL was not polled'}
        LroSuccess{$row=Get-Value $terminal 'v1/async';Add-Failure $failures ($global:MockState.OperationCalls -ge 2) 'Location URL did not receive 202 then 200 polls';Add-Failure $failures ((Get-Value $row operationStatus '')-eq 'Succeeded') 'successful LRO status was not Succeeded'}
        Eligibility{Add-Failure $failures ($global:MockState.Puts.Count -eq 1 -and $global:MockState.Puts[0].Uri -like '*/backupPolicies/eligible?*') 'PUT was not limited to eligible sibling'}
        ErrorDetails{$row=Get-Value $terminal 'v1/nodetail';Add-Failure $failures ((Get-Value $row message '')-like '*HTTP 500*') 'HTTP 500 diagnostic was not retained'}
        ZeroArm{Add-Failure $failures ($armCalls.Count -eq 0) "expected zero ARM calls, got $($armCalls.Count)"}
        TokenRefresh{$calls=@($global:MockState.Calls|Where-Object{$_.Uri -like '*/backupPolicies/refresh?*'});$tokens=@($global:MockState.Calls|Where-Object{$_.Uri -eq $env:IDENTITY_ENDPOINT});Add-Failure $failures ($global:MockState.TokenPosts -eq 2 -and @($tokens|Where-Object{$_.Method -ne 'POST'}).Count -eq 0) "identity POSTs expected 2, got $($global:MockState.TokenPosts)";Add-Failure $failures ($calls.Count -eq 2 -and $calls[0].Headers.Authorization -eq 'Bearer mock-token-1' -and $calls[1].Headers.Authorization -eq 'Bearer mock-token-2') '401 retry did not use refreshed token'}
        RetryAfter{Add-Failure $failures (@($global:MockState.Sleeps|Where-Object{$_ -ge 2}).Count -gt 0) "no recorded sleep honored Retry-After 2; got '$($global:MockState.Sleeps -join ',')'"}
        LroFailed{$row=Get-Value $terminal 'v1/failed';Add-Failure $failures ($global:MockState.OperationCalls -gt 0) 'failed operation URL was not polled';Add-Failure $failures ((Get-Value $row stage '')-eq 'Write' -and (Get-Value $row operationStatus '')-eq 'Failed') 'failed LRO row lacked Write/Failed';Add-Failure $failures ((Get-Value $row message '')-like '*OperationRejected*') 'failed LRO diagnostic lost operation body'}
        TransportReconcile{Add-Failure $failures ($global:MockState.Puts.Count -eq 1) 'transport reconciliation blindly retried PUT';Add-Failure $failures ($global:MockState.OperationCalls -eq 0) 'transport reconciliation unexpectedly polled an LRO'}
        Horizon{$r8=Get-Value $terminal 'v1/retention8';$r9=Get-Value $terminal 'v1/retention9';Add-Failure $failures ((Get-Value $r8 retentionHorizonMonths -1)-eq 8 -and (Get-Value $r9 retentionHorizonMonths -1)-eq 9) 'retention horizons were not 8 and 9'}
        LexicalJson{if($global:MockState.Puts.Count){$raw=[string]$global:MockState.Puts[0].Raw;$node=[System.Text.Json.Nodes.JsonNode]::Parse($raw);$when=[string]$node['tags']['when'].ToString();$runTime=[string]$node['properties']['schedulePolicy']['scheduleRunTimes'][0].ToString();$encodedWhen=$raw.Contains('"when":"2026-08-25T02:00:00+03:00"') -or $raw.Contains('"when":"2026-08-25T02:00:00\u002B03:00"');$encodedRunTime=$raw.Contains('"scheduleRunTimes":["2026-08-25T02:00:00Z"]');Add-Failure $failures ($when -ceq '2026-08-25T02:00:00+03:00' -and $encodedWhen) "PUT rewrote tags.when ('$when')";Add-Failure $failures ($runTime -ceq '2026-08-25T02:00:00Z' -and $encodedRunTime) "PUT rewrote scheduleRunTimes[0] ('$runTime')"}}
        MissingRedundancy{$row=Get-Value $terminal 'v1/-';Add-Failure $failures ((Get-Value $row stage '')-eq 'Discover') 'missing-redundancy row stage was not Discover';$policyCalls=@($global:MockState.Calls|Where-Object{$_.Uri -like '*/vaults/v1/backupPolicies*'});Add-Failure $failures ($policyCalls.Count -eq 0) "missing-redundancy vault received $($policyCalls.Count) policy call(s)"}
        ProtectedItemsUnknown{$row=Get-Value $terminal 'v1/unknown-count';Add-Failure $failures ($null -eq (Get-Value $row protectedItemsCount $null)) 'unknown protectedItemsCount was not emitted as null'}
        TieringSiblingDrift{$row=Get-Value $terminal 'v1/sibling-drift';Add-Failure $failures ((Get-Value $row stage '')-eq 'Verify') 'sibling tiering drift row stage was not Verify';Add-Failure $failures ((Get-Value $row message '')-like '*tieringPolicy.OtherRP*') 'verification diagnostic did not name tieringPolicy.OtherRP'}
        ForeignUrl{$foreign=@($global:MockState.Calls|Where-Object{$_.Uri -like 'https://evil.example.com/*'});Add-Failure $failures ($foreign.Count -eq 0) "foreign host received $($foreign.Count) authenticated call(s)"}
        LateTokenRefresh{$calls=@($global:MockState.Calls|Where-Object{$_.Uri -like '*/backupPolicies/late-refresh?*'});Add-Failure $failures ($global:MockState.TokenPosts -eq 2) "identity POSTs expected 2, got $($global:MockState.TokenPosts)";Add-Failure $failures ($calls.Count -eq 5) "policy GET attempts expected 5, got $($calls.Count)";if($calls.Count -eq 5){Add-Failure $failures (@($calls[0..3]|Where-Object{$_.Headers.Authorization -ne 'Bearer mock-token-1'}).Count -eq 0 -and $calls[4].Headers.Authorization -eq 'Bearer mock-token-2') 'late 401 retry did not use the refreshed token on the fifth request'}}
        TransportThirdRead{$row=Get-Value $terminal 'v1/lost-applied';$uri=$(if($global:MockState.Puts.Count){$global:MockState.Puts[0].Uri}else{''});$first=$(if($uri -and $global:MockState.FirstUpdatedPostPutRead.ContainsKey($uri)){$global:MockState.FirstUpdatedPostPutRead[$uri]}else{-1});Add-Failure $failures ($first -eq 3) "reconciliation first observed the applied write on read $first, expected 3";Add-Failure $failures ((Get-Value $row message '')-like '*PUT response was lost*') 'successful reconciliation lost the PUT-response-loss diagnostic'}
        TransportNeverApplied{$row=Get-Value $terminal 'v1/lost-unknown';$uri=$(if($global:MockState.Puts.Count){$global:MockState.Puts[0].Uri}else{''});$reads=$(if($uri -and $global:MockState.PostPutReads.ContainsKey($uri)){$global:MockState.PostPutReads[$uri]}else{0});Add-Failure $failures ($reads -eq 6) "ambiguous PUT reconciliation reads expected 6, got $reads";Add-Failure $failures (-not $global:MockState.AfterPut.ContainsKey($uri)) 'never-applied transport variant changed mock state';Add-Failure $failures ((Get-Value $row message '')-like '*PUT outcome unknown*mock transport failure*') 'unknown outcome row lost the original PUT diagnostic'}
        NonRetry400{$calls=@($global:MockState.Calls|Where-Object{$_.Uri -like '*/backupPolicies/bad-request?*'});$row=Get-Value $terminal 'v1/bad-request';Add-Failure $failures ($calls.Count -eq 1) "HTTP 400 GET attempts expected 1, got $($calls.Count)";Add-Failure $failures ((Get-Value $row message '')-like '*HTTP 400*') 'HTTP 400 diagnostic was not retained'}
        IfMatch{if($global:MockState.Puts.Count){Add-Failure $failures ($global:MockState.Puts[0].Headers.'If-Match' -ceq 'W/"s42"') "If-Match expected 'W/`"s42`"', got '$($global:MockState.Puts[0].Headers.'If-Match')'"}}
        LroFirstDelay{$sleepIndex=-1;$pollIndex=-1;for($i=0;$i-lt$global:MockState.Events.Count;$i++){$event=$global:MockState.Events[$i];if($sleepIndex-lt 0 -and $event.Kind-eq'Sleep' -and $event.Seconds-eq 3){$sleepIndex=$i};if($pollIndex-lt 0 -and $event.Kind-eq'Call' -and $event.Uri-eq$global:MockState.OperationUri){$pollIndex=$i}};Add-Failure $failures ($global:MockState.Sleeps.Count -gt 0 -and $global:MockState.Sleeps[0] -eq 3) "first LRO sleep expected 3, got '$($global:MockState.Sleeps -join ',')'";Add-Failure $failures ($sleepIndex -ge 0 -and $pollIndex -gt $sleepIndex) 'three-second sleep did not occur before the first operation poll';Add-Failure $failures ($global:MockState.OperationCalls -eq 1) "operation poll count expected 1, got $($global:MockState.OperationCalls)"}
        LroPollTransport{$row=Get-Value $terminal 'v1/poll-unknown';Add-Failure $failures ($global:MockState.OperationCalls -eq 4) "transport-failed operation polls expected 4, got $($global:MockState.OperationCalls)";Add-Failure $failures ((Get-Value $row stage '')-eq 'Write' -and (Get-Value $row operationStatus '')-eq 'Unknown') 'poll exhaustion row was not Write/Unknown'}
        ZrsNull{$zrsLines=@($outputs|Where-Object{$_ -like '*"action":"SkippedZoneRedundantVault"*'});Add-Failure $failures ($zrsLines.Count -gt 0) 'no raw ZRS-skip output row was captured';foreach($line in $zrsLines){foreach($field in @('policy','policyId','workload','policyType','protectedItemsCount','retentionHorizonMonths','previousMode','currentMode','operationStatus')){Add-Failure $failures ($line.Contains(('"{0}":null' -f $field))) "ZRS row did not serialize $field as JSON null: $line"};Add-Failure $failures (-not $line.Contains(':""')) "ZRS row serialized an absent value as an empty string: $line"};Add-Failure $failures (@($global:MockState.Calls|Where-Object{$_.Uri -like '*/backupPolicies?*'}).Count -eq 0) 'ZRS policy list/read occurred'}
    }
    return [pscustomobject]@{Case=$Case;Pass=($failures.Count -eq 0);Failures=@($failures);ExpectedRows=$expectedRows;ActualRows=$actualRows
        ExpectedMetrics=(Format-Metrics $Case.ExpectedSummary);ActualMetrics=(Format-Metrics $(if($null -ne $effective){$effective}else{$summary}));Puts=$global:MockState.Puts.Count
        ExpectedPuts=$Case.ExpectedPuts;Diffs=$diffs;ExpectedDiffs=$expectedDiffs;Outputs=@($outputs);Warnings=@($warnings);Thrown=$thrown;Sleeps=@($global:MockState.Sleeps);PutRecords=@($global:MockState.Puts);ArmCalls=$armCalls.Count;TokenPosts=$global:MockState.TokenPosts;OperationCalls=$global:MockState.OperationCalls}
}

$runResults=@($cases|ForEach-Object{Invoke-Case $_});$scenarioGroups=@($runResults|Group-Object{$_.Case.Id})
$passCount=@($scenarioGroups|Where-Object{@($_.Group|Where-Object{-not $_.Pass}).Count -eq 0}).Count;$failCount=$scenarioGroups.Count-$passCount
$md=[Collections.Generic.List[string]]::new();$md.Add('# Offline behavioral harness results');$md.Add('')
$pwshPath=Join-Path $PSHOME 'pwsh';$md.Add(('Re-run: `{0} -NoProfile -File ./BehaviorHarness.ps1 -RunbookPath {1} -ResultsPath ./results.md`' -f $pwshPath,$RunbookPath));$md.Add('')
$md.Add(('PowerShell: {0}; real runbook: `{1}`; scenarios: {2}; oracle PASS: {3}; oracle FAIL: {4}.' -f $PSVersionTable.PSVersion,$RunbookPath,$scenarioGroups.Count,$passCount,$failCount));$md.Add('')
$md.Add('Each oracle compares terminal action per policy, policiesWritten/writesSubmitted/writesUnknown/writesFailed/errors/abortReason, PUT count and structural fixture diff, and throw state.');$md.Add('')
if($isLegacyRunbook){$md.Add('Legacy compatibility: for only the required v1.0-pass scenarios, absent new zero-valued counters are inferred from captured PUTs; captured SUMMARY lines below remain unmodified.');$md.Add('')}
$md.Add('| Scenario | Expected: policy actions / written-submitted-unknown-failed-errors-abort / PUTs / throw | Actual | PUT diff vs fixture (expected → actual) | Result |');$md.Add('|---|---|---|---|---|')
foreach($group in $scenarioGroups){$expected=[Collections.Generic.List[string]]::new();$actual=[Collections.Generic.List[string]]::new();$diff=[Collections.Generic.List[string]]::new()
    foreach($r in $group.Group){$label=if($r.Case.Variant){"[$($r.Case.Variant)] "}else{''};$expected.Add("$label$($r.ExpectedRows -join ',') / $($r.ExpectedMetrics) / $($r.ExpectedPuts) / $($r.Case.ExpectedThrow)");$actual.Add("$label$($r.ActualRows -join ',') / $($r.ActualMetrics) / $($r.Puts) / $([bool]$r.Thrown)");$ed=if($r.ExpectedDiffs.Count){$r.ExpectedDiffs -join '<br>'}else{'none'};$ad=if($r.Diffs.Count){$r.Diffs -join '<br>'}else{'none'};$diff.Add("$label$ed → $ad")}
    $ok=@($group.Group|Where-Object{-not $_.Pass}).Count -eq 0;$mark=if($ok){'PASS'}else{'**FAIL**'};$md.Add("| $($group.Name) $($group.Group[0].Case.Purpose) | $($expected -join '<br>') | $($actual -join '<br>') | $($diff -join '<br>') | $mark |")}
$md.Add('');$md.Add('## Failed-oracle diagnostics');$md.Add('')
if($failCount -eq 0){$md.Add('- None.')}else{foreach($r in $runResults|Where-Object{-not $_.Pass}){$variant=if($r.Case.Variant){" ($($r.Case.Variant))"}else{''};foreach($failure in $r.Failures){$md.Add("- $($r.Case.Id)$variant`: $failure")}}}
$md.Add('');$md.Add('## Captured streams and PUTs');$md.Add('')
foreach($r in $runResults){$variant=if($r.Case.Variant){" [$($r.Case.Variant)]"}else{''};$md.Add("<details><summary>$($r.Case.Id)$variant — $($r.Case.Purpose)</summary>");$md.Add('');$md.Add('```text');$md.Add('OUTPUT:');$md.Add($(if($r.Outputs.Count){$r.Outputs -join "`n"}else{'<none>'}));$md.Add('WARNING:');$md.Add($(if($r.Warnings.Count){$r.Warnings -join "`n"}else{'<none>'}));$md.Add("THROWN: $(if($r.Thrown){$r.Thrown}else{'<none>'})");$md.Add("SLEEPS: $($r.Sleeps -join ',')");$md.Add("ARM CALLS: $($r.ArmCalls); TOKEN POSTS: $($r.TokenPosts); LRO CALLS: $($r.OperationCalls)");$md.Add('```')
    for($i=0;$i-lt$r.PutRecords.Count;$i++){$put=$r.PutRecords[$i];$md.Add("PUT $($i+1) headers=$($put.Headers|ConvertTo-Json -Compress) diff=$($r.Diffs[$i])");$md.Add('```json');$md.Add([string]$put.Raw);$md.Add('```')};$md.Add('');$md.Add('</details>');$md.Add('')}
$md|Set-Content -LiteralPath $ResultsPath -Encoding utf8
Write-Output "Harness complete: $passCount PASS, $failCount FAIL. Results: $ResultsPath"
if($failCount -gt 0){exit 1}
