<#
.SYNOPSIS
Safely audits or enables Azure Backup Smart Tiering for Azure VM backup policies.

.DESCRIPTION
This Azure Automation runbook enumerates Recovery Services vaults at either
resource-group or subscription scope. It only changes AzureIaaSVM policies whose
ArchivedRP tiering mode is missing or DoNotTier, setting it to TierRecommended.

Safety properties:
- Audit-only unless -Apply is true.
- Never disables tiering.
- Does not replace an existing TierAfter configuration.
- Does not change schedules or retention settings.
- Uses the policy ETag when available to reject concurrent updates.
- Does not delete vaults, policies, recovery points, or backup data.

The runbook authenticates with the Automation Account system-assigned managed
identity through the Azure Automation identity endpoint and calls ARM directly.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('ResourceGroup', 'Subscription')]
    [string] $ScopeType,

    [string] $ResourceGroupName,

    [string] $VaultName,

    [string] $PolicyName,

    [bool] $Apply = $false,

    [ValidatePattern('^20[0-9]{2}-[0-9]{2}-[0-9]{2}$')]
    [string] $ApiVersion = '2025-08-01'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ScopeType -eq 'ResourceGroup' -and [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    throw 'ResourceGroupName is required when ScopeType is ResourceGroup.'
}

function Get-PropertyValue {
    param(
        [AllowNull()]
        [object] $InputObject,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Remove-PropertyIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [object] $InputObject,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -ne $InputObject.PSObject.Properties[$Name]) {
        $InputObject.PSObject.Properties.Remove($Name)
    }
}

function Get-ManagedIdentityToken {
    if ([string]::IsNullOrWhiteSpace($env:IDENTITY_ENDPOINT) -or
        [string]::IsNullOrWhiteSpace($env:IDENTITY_HEADER)) {
        throw 'Azure Automation managed identity endpoint variables are unavailable. Run this in an Automation Account with a system-assigned identity.'
    }

    $identityHeaders = @{
        'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
        Metadata            = 'True'
    }

    $tokenResponse = Invoke-RestMethod `
        -Uri $env:IDENTITY_ENDPOINT `
        -Method Post `
        -Headers $identityHeaders `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ resource = 'https://management.azure.com/' }

    if ([string]::IsNullOrWhiteSpace($tokenResponse.access_token)) {
        throw 'The Automation managed identity endpoint did not return an ARM access token.'
    }

    return $tokenResponse.access_token
}

function Invoke-ArmRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'PUT')]
        [string] $Method,
        [Parameter(Mandatory = $true)]
        [string] $Uri,
        [AllowNull()]
        [string] $Body,
        [hashtable] $AdditionalHeaders = @{}
    )

    $headers = @{
        Authorization = "Bearer $script:ArmAccessToken"
        Accept        = 'application/json'
    }
    foreach ($key in $AdditionalHeaders.Keys) {
        $headers[$key] = $AdditionalHeaders[$key]
    }

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $request = @{
                Uri         = $Uri
                Method      = $Method
                Headers     = $headers
                ErrorAction = 'Stop'
            }
            if ($null -ne $Body) {
                $request.ContentType = 'application/json'
                $request.Body = $Body
            }

            return Invoke-RestMethod @request
        }
        catch {
            $statusCode = $null
            if ($null -ne $_.Exception.Response) {
                try {
                    $statusCode = [int] $_.Exception.Response.StatusCode
                }
                catch {
                    $statusCode = $null
                }
            }

            $isTransient = $statusCode -in @(408, 429, 500, 502, 503, 504)
            if ($isTransient -and $attempt -lt 4) {
                Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
                continue
            }

            $details = if ([string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
                $_.Exception.Message
            }
            else {
                $_.ErrorDetails.Message
            }
            throw "ARM $Method failed for $Uri (HTTP $statusCode): $details"
        }
    }
}

function Get-ArmCollection {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri
    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        $page = Invoke-ArmRequest -Method GET -Uri $nextUri -Body $null
        $values = Get-PropertyValue -InputObject $page -Name 'value'
        foreach ($item in @($values)) {
            if ($null -ne $item) {
                $items.Add($item)
            }
        }
        $nextUri = Get-PropertyValue -InputObject $page -Name 'nextLink'
    }

    return $items.ToArray()
}

function Add-OrSetNoteProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object] $InputObject,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $InputObject.PSObject.Properties[$Name]) {
        $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $InputObject.$Name = $Value
    }
}

$script:ArmAccessToken = Get-ManagedIdentityToken
$managementEndpoint = 'https://management.azure.com'
$encodedSubscription = [Uri]::EscapeDataString($SubscriptionId)

if ($ScopeType -eq 'ResourceGroup') {
    $encodedResourceGroup = [Uri]::EscapeDataString($ResourceGroupName)
    $vaultListUri = "$managementEndpoint/subscriptions/$encodedSubscription/resourceGroups/$encodedResourceGroup/providers/Microsoft.RecoveryServices/vaults?api-version=$ApiVersion"
}
else {
    $vaultListUri = "$managementEndpoint/subscriptions/$encodedSubscription/providers/Microsoft.RecoveryServices/vaults?api-version=$ApiVersion"
}

$vaults = @(Get-ArmCollection -Uri $vaultListUri)
if (-not [string]::IsNullOrWhiteSpace($VaultName)) {
    $vaults = @($vaults | Where-Object { $_.name -eq $VaultName })
}

$results = [System.Collections.Generic.List[object]]::new()
$writeCount = 0
$errorCount = 0

foreach ($vault in $vaults) {
    try {
        $vaultDetailsUri = "$managementEndpoint$($vault.id)?api-version=$ApiVersion"
        $vaultDetails = Invoke-ArmRequest -Method GET -Uri $vaultDetailsUri -Body $null
        $redundancySettings = Get-PropertyValue -InputObject $vaultDetails.properties -Name 'redundancySettings'
        $standardTierRedundancy = Get-PropertyValue -InputObject $redundancySettings -Name 'standardTierStorageRedundancy'
        if ($standardTierRedundancy -in @('ZoneRedundant', 'ZRS')) {
            $result = [ordered]@{
                subscriptionId = $SubscriptionId
                scopeType       = $ScopeType
                vault           = $vault.name
                policy          = $null
                workload        = $null
                previousMode    = $null
                currentMode     = $null
                action          = 'SkippedZoneRedundantVault'
            }
            $results.Add([pscustomobject] $result)
            Write-Output ($result | ConvertTo-Json -Compress)
            continue
        }

        $policyListUri = "$managementEndpoint$($vault.id)/backupPolicies?api-version=$ApiVersion"
        $policies = @(Get-ArmCollection -Uri $policyListUri)
        if (-not [string]::IsNullOrWhiteSpace($PolicyName)) {
            $policies = @($policies | Where-Object { $_.name -eq $PolicyName })
        }

        foreach ($policy in $policies) {
            # Always evaluate a fresh point read. Collection results can be stale and
            # Azure Resource Graph (if added later for discovery) is eventually consistent.
            $policyUri = "$managementEndpoint$($policy.id)?api-version=$ApiVersion"
            $policy = Invoke-ArmRequest -Method GET -Uri $policyUri -Body $null
            $managementType = Get-PropertyValue -InputObject $policy.properties -Name 'backupManagementType'
            if ($managementType -ne 'AzureIaasVM') {
                $result = [ordered]@{
                    subscriptionId = $SubscriptionId
                    scopeType       = $ScopeType
                    vault           = $vault.name
                    policy          = $policy.name
                    workload        = $managementType
                    previousMode    = $null
                    currentMode     = $null
                    action          = 'SkippedUnsupportedWorkload'
                }
                $results.Add([pscustomobject] $result)
                Write-Output ($result | ConvertTo-Json -Compress)
                continue
            }

            $tieringPolicy = Get-PropertyValue -InputObject $policy.properties -Name 'tieringPolicy'
            $archivedRp = Get-PropertyValue -InputObject $tieringPolicy -Name 'ArchivedRP'
            $currentMode = Get-PropertyValue -InputObject $archivedRp -Name 'tieringMode'

            if ($currentMode -eq 'TierRecommended') {
                $action = 'AlreadyCompliant'
            }
            elseif ($currentMode -eq 'TierAfter') {
                $action = 'AlreadyEnabledAlternateMode'
            }
            elseif ($null -ne $currentMode -and $currentMode -notin @('DoNotTier', 'Invalid')) {
                $action = 'SkippedUnknownMode'
            }
            elseif ($currentMode -eq 'Invalid') {
                $action = 'SkippedUnknownMode'
            }
            elseif (-not $Apply) {
                $action = 'WouldEnableTierRecommended'
            }
            else {
                # Re-read immediately before the full-policy PUT. Some API versions do not
                # emit an ETag, so abort if the policy changed during this job's evaluation.
                $preWritePolicy = Invoke-ArmRequest -Method GET -Uri $policyUri -Body $null
                $evaluatedPropertiesJson = $policy.properties | ConvertTo-Json -Depth 100 -Compress
                $preWritePropertiesJson = $preWritePolicy.properties | ConvertTo-Json -Depth 100 -Compress
                if ($evaluatedPropertiesJson -ne $preWritePropertiesJson) {
                    throw 'The policy changed after evaluation. No update was submitted; rerun the job against the new version.'
                }
                $policy = $preWritePolicy
                $properties = $policy.properties | ConvertTo-Json -Depth 100 | ConvertFrom-Json
                Remove-PropertyIfPresent -InputObject $properties -Name 'protectedItemsCount'
                Remove-PropertyIfPresent -InputObject $properties -Name 'resourceGuardOperationRequests'

                $updatedTieringPolicy = Get-PropertyValue -InputObject $properties -Name 'tieringPolicy'
                if ($null -eq $updatedTieringPolicy) {
                    $updatedTieringPolicy = [pscustomobject] @{}
                    Add-OrSetNoteProperty -InputObject $properties -Name 'tieringPolicy' -Value $updatedTieringPolicy
                }

                $updatedArchivedRp = Get-PropertyValue -InputObject $updatedTieringPolicy -Name 'ArchivedRP'
                if ($null -eq $updatedArchivedRp) {
                    $updatedArchivedRp = [pscustomobject] @{}
                    Add-OrSetNoteProperty -InputObject $updatedTieringPolicy -Name 'ArchivedRP' -Value $updatedArchivedRp
                }
                Add-OrSetNoteProperty -InputObject $updatedArchivedRp -Name 'tieringMode' -Value 'TierRecommended'
                Remove-PropertyIfPresent -InputObject $updatedArchivedRp -Name 'duration'
                Remove-PropertyIfPresent -InputObject $updatedArchivedRp -Name 'durationType'

                $payload = [ordered] @{ properties = $properties }
                $location = Get-PropertyValue -InputObject $policy -Name 'location'
                if (-not [string]::IsNullOrWhiteSpace($location)) {
                    $payload.location = $location
                }
                $etag = Get-PropertyValue -InputObject $policy -Name 'eTag'
                if (-not [string]::IsNullOrWhiteSpace($etag)) {
                    $payload.eTag = $etag
                }

                $putHeaders = @{}
                if (-not [string]::IsNullOrWhiteSpace($etag)) {
                    $putHeaders['If-Match'] = $etag
                }

                $null = Invoke-ArmRequest `
                    -Method PUT `
                    -Uri $policyUri `
                    -Body ($payload | ConvertTo-Json -Depth 100 -Compress) `
                    -AdditionalHeaders $putHeaders

                $verifiedPolicy = $null
                $verifiedMode = $null
                for ($verificationAttempt = 1; $verificationAttempt -le 12; $verificationAttempt++) {
                    $verifiedPolicy = Invoke-ArmRequest -Method GET -Uri $policyUri -Body $null
                    $verifiedTiering = Get-PropertyValue -InputObject $verifiedPolicy.properties -Name 'tieringPolicy'
                    $verifiedArchivedRp = Get-PropertyValue -InputObject $verifiedTiering -Name 'ArchivedRP'
                    $verifiedMode = Get-PropertyValue -InputObject $verifiedArchivedRp -Name 'tieringMode'
                    if ($verifiedMode -eq 'TierRecommended') {
                        break
                    }
                    Start-Sleep -Seconds 5
                }
                if ($verifiedMode -ne 'TierRecommended') {
                    throw "Verification failed: expected TierRecommended, received '$verifiedMode'."
                }

                $scheduleBefore = Get-PropertyValue -InputObject $policy.properties -Name 'schedulePolicy' | ConvertTo-Json -Depth 100 -Compress
                $scheduleAfter = Get-PropertyValue -InputObject $verifiedPolicy.properties -Name 'schedulePolicy' | ConvertTo-Json -Depth 100 -Compress
                $retentionBefore = Get-PropertyValue -InputObject $policy.properties -Name 'retentionPolicy' | ConvertTo-Json -Depth 100 -Compress
                $retentionAfter = Get-PropertyValue -InputObject $verifiedPolicy.properties -Name 'retentionPolicy' | ConvertTo-Json -Depth 100 -Compress
                if ($scheduleBefore -ne $scheduleAfter -or $retentionBefore -ne $retentionAfter) {
                    throw 'Post-write verification detected a schedule or retention change.'
                }

                $currentMode = $verifiedMode
                $action = 'EnabledAndVerified'
                $writeCount++
            }

            $result = [ordered]@{
                subscriptionId = $SubscriptionId
                scopeType       = $ScopeType
                vault           = $vault.name
                policy          = $policy.name
                workload        = $managementType
                previousMode    = if ($null -eq $currentMode -or $action -eq 'EnabledAndVerified') { Get-PropertyValue -InputObject $archivedRp -Name 'tieringMode' } else { $currentMode }
                currentMode     = $currentMode
                action          = $action
            }
            $results.Add([pscustomobject] $result)
            Write-Output ($result | ConvertTo-Json -Compress)
        }
    }
    catch {
        $errorCount++
        $result = [ordered]@{
            subscriptionId = $SubscriptionId
            scopeType       = $ScopeType
            vault           = $vault.name
            policy          = $null
            workload        = $null
            previousMode    = $null
            currentMode     = $null
            action          = 'Error'
            message         = $_.Exception.Message
        }
        $results.Add([pscustomobject] $result)
        Write-Warning ($result | ConvertTo-Json -Compress)
    }
}

$summary = [ordered]@{
    subscriptionId = $SubscriptionId
    scopeType       = $ScopeType
    resourceGroup   = $ResourceGroupName
    vaultFilter     = $VaultName
    policyFilter    = $PolicyName
    apply           = $Apply
    vaultsScanned   = $vaults.Count
    policiesSeen    = $results.Count
    policiesWritten = $writeCount
    errors           = $errorCount
}
Write-Output ('SUMMARY ' + ($summary | ConvertTo-Json -Compress))

if ($errorCount -gt 0) {
    throw "Smart Tiering remediation completed with $errorCount error(s)."
}
