[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$runbookPath = Join-Path $repositoryRoot 'src/Enable-SmartTiering.ps1'
$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $runbookPath,
    [ref] $tokens,
    [ref] $parseErrors
)

if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Error $_.ToString() }
    throw "PowerShell parsing failed with $($parseErrors.Count) error(s)."
}

$content = Get-Content -LiteralPath $runbookPath -Raw
$requiredSafetyMarkers = @(
    "[bool] `$Apply = `$false",
    "[ValidateSet('GET', 'PUT')]",
    "SkippedZoneRedundantVault",
    "SkippedUnsupportedWorkload",
    "AlreadyEnabledAlternateMode",
    "WouldEnableTierRecommended",
    "EnabledAndVerified",
    "Post-write verification detected a schedule or retention change",
    "SkippedNoArchiveEligibility",
    "SkippedProtectedItemsExceedLimit",
    "WriteOutcomeUnknown",
    "AllowUnfilteredApply",
    "MaxChanges",
    "Azure-AsyncOperation"
)

foreach ($marker in $requiredSafetyMarkers) {
    if (-not $content.Contains($marker)) {
        throw "Required safety marker is missing: $marker"
    }
}

$forbiddenMarkers = @(
    "Invoke-ArmRequest -Method DELETE",
    "Disable-AzRecoveryServicesBackupProtection",
    "Remove-AzRecoveryServices",
    "az group delete"
)

foreach ($marker in $forbiddenMarkers) {
    if ($content.Contains($marker)) {
        throw "Forbidden destructive marker found: $marker"
    }
}

Write-Output 'PowerShell parsing and static safety checks passed.'
