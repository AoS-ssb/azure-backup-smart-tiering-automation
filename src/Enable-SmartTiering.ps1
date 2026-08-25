<#
.SYNOPSIS
Safely audits or enables Azure Backup Smart Tiering (TierRecommended) for Azure VM backup policies.

.DESCRIPTION
Version 1.1 of the Azure Automation runbook. It enumerates Recovery Services vaults at
resource-group or subscription scope, classifies every AzureIaasVM backup policy, and - only
when Apply is true and every preflight guard passes - sets ArchivedRP.tieringMode to
TierRecommended on policies whose mode is missing or DoNotTier.

Safety properties:
- Audit-only unless -Apply is true; Apply requires exact VaultName and PolicyName filters unless
  -AllowUnfilteredApply is set deliberately.
- Two phases: everything is discovered and classified before the first write; the apply phase
  aborts before any PUT when discovery had errors, when nothing matched, when ExpectedMatches is
  not met, or when the number of candidates exceeds MaxChanges.
- Policies that cannot have archive-eligible recovery points (no monthly/yearly retention of at
  least MinimumRetentionMonths), policies protecting more than MaxProtectedItemsPerPolicy items,
  and protected policies whose API returns no ETag (unless -AllowWriteWithoutETag) are skipped.
- Facts the runbook cannot establish (vault redundancy, protected-item count) fail closed.
- Never disables tiering; never replaces an existing TierAfter configuration.
- JSON is handled as text-preserving nodes: the write payload is the policy exactly as the API
  returned it, minus read-only members, with only ArchivedRP.tieringMode changed. Tags, location
  and every other property - including date-like strings - are sent back byte-for-byte.
- Follows the asynchronous update operation to a terminal state and reports submitted, verified,
  failed and unknown writes separately. A write whose outcome cannot be determined is never
  resubmitted. Verifies afterwards that nothing except ArchivedRP changed.
- Stops starting new writes once JobTimeBudgetSeconds has elapsed, well inside the Azure
  Automation cloud-job limit, so a long run ends with a truthful summary instead of being killed.
- Sends the managed-identity token only to https://management.azure.com.
- Errors are isolated per policy; one failing policy does not stop its siblings.
- Issues no DELETE. Note that a policy update is re-applied to every item the policy protects,
  and retention changes can shorten recovery-point lifetime - which is why the write is verified
  to change nothing but the tiering mode.

The runbook authenticates with the Automation Account system-assigned managed identity through
the Azure Automation identity endpoint and calls Azure Resource Manager directly (commercial
Azure endpoints). No Az modules are required.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('ResourceGroup', 'Subscription')]
    [string] $ScopeType,

    [string] $ResourceGroupName = '',

    [string] $VaultName = '',

    [string] $PolicyName = '',

    [bool] $Apply = $false,

    [bool] $AllowUnfilteredApply = $false,

    [bool] $AllowWriteWithoutETag = $false,

    [ValidateRange(1, 10000)]
    [int] $MaxChanges = 1,

    [ValidateRange(0, 100000)]
    [int] $ExpectedMatches = 0,

    [ValidateRange(0, 100000)]
    [int] $MaxProtectedItemsPerPolicy = 0,

    [ValidateRange(9, 1200)]
    [int] $MinimumRetentionMonths = 9,

    [ValidateRange(1, 1800)]
    [int] $OperationTimeoutSeconds = 600,

    [ValidateRange(10, 600)]
    [int] $RequestTimeoutSeconds = 100,

    [ValidateRange(60, 9000)]
    [int] $JobTimeBudgetSeconds = 8400,

    [ValidatePattern('^20[0-9]{2}-[0-9]{2}-[0-9]{2}$')]
    [string] $ApiVersion = '2025-08-01'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RunbookVersion = '1.1.0'
$script:JobStarted = [DateTime]::UtcNow
# Script-scope copies of the transport limits so helper functions reference them explicitly.
$script:RequestTimeout = $RequestTimeoutSeconds
$script:OperationTimeout = $OperationTimeoutSeconds
$script:JobBudget = $JobTimeBudgetSeconds
$script:ManagementEndpoint = 'https://management.azure.com'
$script:LastArmError = $null

# ---------------------------------------------------------------------------------------------
# Parameter validation - everything here runs before any network call.
# ---------------------------------------------------------------------------------------------

function Assert-ExactName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ParameterName,
        [AllowEmptyString()]
        [string] $Value
    )

    if ($Value.Length -gt 0 -and $Value.Trim().Length -eq 0) {
        throw "$ParameterName was supplied but is blank/whitespace. Supply the exact name, or omit the parameter."
    }
    if ($Value -cne $Value.Trim()) {
        throw "$ParameterName contains leading or trailing whitespace. Supply the exact name."
    }
}

Assert-ExactName -ParameterName 'ResourceGroupName' -Value $ResourceGroupName
Assert-ExactName -ParameterName 'VaultName' -Value $VaultName
Assert-ExactName -ParameterName 'PolicyName' -Value $PolicyName

if ($ScopeType -eq 'ResourceGroup' -and $ResourceGroupName.Length -eq 0) {
    throw 'ResourceGroupName is required when ScopeType is ResourceGroup.'
}
if ($ScopeType -eq 'Subscription' -and $ResourceGroupName.Length -gt 0) {
    throw 'ResourceGroupName must not be supplied when ScopeType is Subscription. Use ScopeType=ResourceGroup to target one resource group.'
}
if ($Apply -and -not $AllowUnfilteredApply -and ($VaultName.Length -eq 0 -or $PolicyName.Length -eq 0)) {
    throw 'Apply=true requires exact VaultName and PolicyName filters. Set AllowUnfilteredApply=true only to deliberately apply to every matched policy (still bounded by MaxChanges and ExpectedMatches).'
}

# ---------------------------------------------------------------------------------------------
# JSON layer - System.Text.Json nodes keep every value as the API sent it (no DateTime parsing).
# ---------------------------------------------------------------------------------------------

function ConvertTo-JsonNode {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    # Comma operator: JsonNode types implement IEnumerable and would otherwise be unrolled on return.
    return , [System.Text.Json.Nodes.JsonNode]::Parse($Text)
}

function Get-JsonMember {
    # Member lookup on a JsonObject: exact name first, then case-insensitive. $null when absent.
    param(
        [AllowNull()]
        [object] $Node,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $Node -or $Node -isnot [System.Text.Json.Nodes.JsonObject]) {
        return $null
    }
    if ($Node.ContainsKey($Name)) {
        return , $Node[$Name]
    }
    foreach ($pair in $Node) {
        if ($pair.Key -ieq $Name) {
            return , $pair.Value
        }
    }
    return $null
}

function Get-JsonString {
    param(
        [AllowNull()]
        [object] $Node
    )

    if ($null -eq $Node) {
        return $null
    }
    if ($Node -is [System.Text.Json.Nodes.JsonValue]) {
        return [string]$Node.ToString()
    }
    return [string]$Node.ToJsonString()
}

function Get-JsonNonNegativeInt {
    # Returns an [int] >= 0, or $null when the member is absent or not a non-negative integer.
    param(
        [AllowNull()]
        [object] $Node
    )

    if ($null -eq $Node -or $Node -isnot [System.Text.Json.Nodes.JsonValue]) {
        return $null
    }
    $parsed = 0
    if ([int]::TryParse([string]$Node.ToString(), [ref]$parsed) -and $parsed -ge 0) {
        return [int]$parsed
    }
    return $null
}

function Copy-JsonNode {
    param(
        [AllowNull()]
        [object] $Node
    )

    if ($null -eq $Node) {
        return $null
    }
    return , [System.Text.Json.Nodes.JsonNode]::Parse($Node.ToJsonString())
}

function Clear-JsonMember {
    param(
        [AllowNull()]
        [object] $Node,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $Node -or $Node -isnot [System.Text.Json.Nodes.JsonObject]) {
        return
    }
    $matching = @(foreach ($pair in $Node) { if ($pair.Key -ieq $Name) { $pair.Key } })
    foreach ($key in $matching) {
        [void]$Node.Remove($key)
    }
}

function Get-FirstDifference {
    # JSON path of the first difference between two nodes, or $null when identical. Object member
    # order is ignored; member names and string values are compared case-sensitively.
    param(
        [AllowNull()]
        [object] $Left,
        [AllowNull()]
        [object] $Right,
        [string] $Path = '$'
    )

    if ($null -eq $Left -and $null -eq $Right) {
        return $null
    }
    if ($null -eq $Left -or $null -eq $Right) {
        return $Path
    }
    $leftIsObject = $Left -is [System.Text.Json.Nodes.JsonObject]
    $rightIsObject = $Right -is [System.Text.Json.Nodes.JsonObject]
    $leftIsArray = $Left -is [System.Text.Json.Nodes.JsonArray]
    $rightIsArray = $Right -is [System.Text.Json.Nodes.JsonArray]

    if ($leftIsObject -and $rightIsObject) {
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($pair in $Left) { if (-not $names.Contains($pair.Key)) { $names.Add($pair.Key) } }
        foreach ($pair in $Right) { if (-not $names.Contains($pair.Key)) { $names.Add($pair.Key) } }
        $sorted = $names.ToArray()
        [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        foreach ($name in $sorted) {
            $childPath = "$Path.$name"
            if (-not $Left.ContainsKey($name) -or -not $Right.ContainsKey($name)) {
                return $childPath
            }
            $difference = Get-FirstDifference -Left $Left[$name] -Right $Right[$name] -Path $childPath
            if ($null -ne $difference) {
                return $difference
            }
        }
        return $null
    }
    if ($leftIsArray -and $rightIsArray) {
        if ($Left.Count -ne $Right.Count) {
            return "$Path.length"
        }
        for ($index = 0; $index -lt $Left.Count; $index++) {
            $difference = Get-FirstDifference -Left $Left[$index] -Right $Right[$index] -Path "$Path[$index]"
            if ($null -ne $difference) {
                return $difference
            }
        }
        return $null
    }
    if ($leftIsObject -or $rightIsObject -or $leftIsArray -or $rightIsArray) {
        return $Path
    }
    if ($Left.ToJsonString() -cne $Right.ToJsonString()) {
        return $Path
    }
    return $null
}

function Get-HeaderValue {
    param(
        [AllowNull()]
        [object] $Headers,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $Headers) {
        return $null
    }
    $keys = $null
    if ($Headers -is [System.Collections.IDictionary]) {
        $keys = @($Headers.Keys)
    }
    else {
        $keysProperty = $Headers.PSObject.Properties['Keys']
        if ($null -ne $keysProperty) {
            $keys = @($keysProperty.Value)
        }
    }
    if ($null -eq $keys) {
        return $null
    }
    foreach ($key in $keys) {
        if ([string]$key -ieq $Name) {
            $value = $Headers[$key]
            if ($null -eq $value) {
                return $null
            }
            $first = @($value)[0]
            if ($null -eq $first) {
                return $null
            }
            return [string]$first
        }
    }
    return $null
}

function Get-RetentionHorizon {
    # Months of monthly/yearly long-term retention. Only monthly and yearly recovery points can
    # reach the archive tier, so a policy without them has a horizon of 0. Only the documented
    # units for those schedules (Months, Years) count; anything else is treated as 0 (fail closed).
    param(
        [AllowNull()]
        [object] $RetentionPolicy
    )

    $months = 0
    foreach ($scheduleName in @('monthlySchedule', 'yearlySchedule')) {
        $schedule = Get-JsonMember -Node $RetentionPolicy -Name $scheduleName
        if ($null -eq $schedule) {
            continue
        }
        $duration = Get-JsonMember -Node $schedule -Name 'retentionDuration'
        $count = Get-JsonNonNegativeInt -Node (Get-JsonMember -Node $duration -Name 'count')
        $durationType = [string](Get-JsonString -Node (Get-JsonMember -Node $duration -Name 'durationType'))
        if ($null -eq $count) {
            continue
        }
        $candidate = switch ($durationType) {
            'Years' { $count * 12 }
            'Months' { $count }
            default { 0 }
        }
        if ($candidate -gt $months) {
            $months = $candidate
        }
    }
    return [int]$months
}

# ---------------------------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------------------------

function Get-RemainingJobBudget {
    $elapsed = ([DateTime]::UtcNow - $script:JobStarted).TotalSeconds
    return [int][Math]::Max(0, [Math]::Floor($script:JobBudget - $elapsed))
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
        -Body @{ resource = 'https://management.azure.com/' } `
        -TimeoutSec $script:RequestTimeout

    $accessToken = $null
    if ($null -ne $tokenResponse) {
        $tokenProperty = $tokenResponse.PSObject.Properties['access_token']
        if ($null -ne $tokenProperty) {
            $accessToken = $tokenProperty.Value
        }
    }
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw 'The Automation managed identity endpoint did not return an ARM access token.'
    }
    return [string]$accessToken
}

function Get-ErrorInfo {
    # Null-safe extraction of HTTP status, Retry-After and message from an ErrorRecord. Works for
    # HttpResponseException (has Response) and for transport exceptions (no Response) under
    # StrictMode. Transient = documented retryable status codes, or a transport failure with no
    # HTTP response at all. HttpResponseException inherits HttpRequestException, so the response
    # check comes first.
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $info = [ordered]@{
        StatusCode        = $null
        RetryAfterSeconds = $null
        Message           = $null
        Transient         = $false
        ExceptionType     = $null
    }

    $exception = $ErrorRecord.Exception
    $hasResponse = $false
    if ($null -ne $exception) {
        $info.ExceptionType = $exception.GetType().FullName
        $responseProperty = $exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            $hasResponse = $true
            $response = $responseProperty.Value
            $statusProperty = $response.PSObject.Properties['StatusCode']
            if ($null -ne $statusProperty -and $null -ne $statusProperty.Value) {
                try { $info.StatusCode = [int]$statusProperty.Value } catch { $info.StatusCode = $null }
            }
            $headersProperty = $response.PSObject.Properties['Headers']
            if ($null -ne $headersProperty -and $null -ne $headersProperty.Value) {
                try {
                    $retryAfterProperty = $headersProperty.Value.PSObject.Properties['RetryAfter']
                    if ($null -ne $retryAfterProperty -and $null -ne $retryAfterProperty.Value) {
                        $deltaProperty = $retryAfterProperty.Value.PSObject.Properties['Delta']
                        if ($null -ne $deltaProperty -and $null -ne $deltaProperty.Value) {
                            $info.RetryAfterSeconds = [int][Math]::Ceiling($deltaProperty.Value.TotalSeconds)
                        }
                    }
                    if ($null -eq $info.RetryAfterSeconds) {
                        $headerText = Get-HeaderValue -Headers $headersProperty.Value -Name 'Retry-After'
                        if ($null -ne $headerText -and $headerText -match '^\d+$') {
                            $info.RetryAfterSeconds = [int]$headerText
                        }
                    }
                }
                catch {
                    $info.RetryAfterSeconds = $null
                }
            }
        }
        if (-not $hasResponse -and (
                $exception -is [System.Net.Http.HttpRequestException] -or
                $exception -is [System.Threading.Tasks.TaskCanceledException] -or
                $exception -is [System.OperationCanceledException] -or
                $exception -is [System.TimeoutException])) {
            $info.Transient = $true
        }
    }

    $details = $null
    $detailsProperty = $ErrorRecord.PSObject.Properties['ErrorDetails']
    if ($null -ne $detailsProperty -and $null -ne $detailsProperty.Value) {
        $messageProperty = $detailsProperty.Value.PSObject.Properties['Message']
        if ($null -ne $messageProperty) {
            $details = $messageProperty.Value
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($details)) {
        $info.Message = [string]$details
    }
    elseif ($null -ne $exception -and -not [string]::IsNullOrWhiteSpace($exception.Message)) {
        $info.Message = $exception.Message
    }
    else {
        $info.Message = [string]$ErrorRecord
    }

    if ($info.StatusCode -in @(408, 429, 500, 502, 503, 504)) {
        $info.Transient = $true
    }
    return [pscustomobject]$info
}

function Get-BackoffDelay {
    # Retry-After is the server's required wait (bounded by the remaining job budget and a sanity
    # ceiling); otherwise exponential backoff. A little jitter avoids synchronised retries.
    param(
        [Parameter(Mandatory = $true)]
        [int] $Attempt,
        [AllowNull()]
        [object] $RetryAfterSeconds
    )

    $base = [Math]::Pow(2, $Attempt)
    if ($null -ne $RetryAfterSeconds -and [int]$RetryAfterSeconds -gt 0) {
        $base = [Math]::Min([int]$RetryAfterSeconds, 300)
    }
    $delay = [int]$base + (Get-Random -Minimum 0 -Maximum 2)
    return [int][Math]::Max(0, [Math]::Min($delay, (Get-RemainingJobBudget)))
}

function Assert-ArmUri {
    # The bearer token is only ever sent to Azure Resource Manager over HTTPS.
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri
    )

    $parsed = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed)) {
        throw "Refusing to call a malformed URL: $Uri"
    }
    $expectedHost = ([Uri]$script:ManagementEndpoint).Host
    if ($parsed.Scheme -ne 'https' -or $parsed.Host -ine $expectedHost) {
        throw "Refusing to send the ARM token to a non-ARM URL: $Uri"
    }
}

function Invoke-ArmRequest {
    # Returns [pscustomobject]@{ StatusCode; Headers; Content; Body } where Body is a JsonNode.
    # GET: retries transient failures (status or transport) with backoff and refreshes the token
    # once on 401 without consuming an attempt. PUT: retries only 429 (not processed) and 401; any
    # other PUT failure is thrown so the caller can classify and reconcile instead of resubmitting.
    # $script:LastArmError holds the diagnostic of the last failure that was thrown.
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

    Assert-ArmUri -Uri $Uri

    $maxAttempts = 4
    $tokenRefreshed = $false
    $lastInfo = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $headers = @{
            Authorization = "Bearer $script:ArmAccessToken"
            Accept        = 'application/json'
        }
        foreach ($key in $AdditionalHeaders.Keys) {
            $headers[$key] = $AdditionalHeaders[$key]
        }

        try {
            $request = @{
                Uri                      = $Uri
                Method                   = $Method
                Headers                  = $headers
                ErrorAction              = 'Stop'
                ConnectionTimeoutSeconds = $script:RequestTimeout
                OperationTimeoutSeconds  = $script:RequestTimeout
            }
            if ($null -ne $Body) {
                $request.ContentType = 'application/json'
                $request.Body = $Body
            }
            $response = Invoke-WebRequest @request
            $content = ''
            if ($null -ne $response.Content) {
                $content = [string]$response.Content
            }
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Headers    = $response.Headers
                Content    = $content
                Body       = (ConvertTo-JsonNode -Text $content)
            }
        }
        catch {
            $info = Get-ErrorInfo -ErrorRecord $_
            $lastInfo = $info
            if ($info.StatusCode -eq 401 -and -not $tokenRefreshed) {
                $tokenRefreshed = $true
                $script:ArmAccessToken = Get-ManagedIdentityToken
                $attempt--
                continue
            }
            $canRetry = $info.Transient -and ($attempt -lt $maxAttempts)
            if ($Method -eq 'PUT') {
                $canRetry = ($info.StatusCode -eq 429) -and ($attempt -lt $maxAttempts)
            }
            if ($canRetry -and (Get-RemainingJobBudget) -gt 0) {
                Start-Sleep -Seconds (Get-BackoffDelay -Attempt $attempt -RetryAfterSeconds $info.RetryAfterSeconds)
                continue
            }
            $script:LastArmError = $info
            $statusText = if ($null -eq $info.StatusCode) { 'transport' } else { [string]$info.StatusCode }
            throw "ARM $Method failed for $Uri (HTTP $statusText): $($info.Message)"
        }
    }
    $script:LastArmError = $lastInfo
    $lastText = if ($null -eq $lastInfo) { 'no diagnostic' } else { "HTTP $($lastInfo.StatusCode): $($lastInfo.Message)" }
    throw "ARM $Method failed for $Uri after $maxAttempts attempts ($lastText)."
}

function Get-ArmCollection {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri
    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        $page = (Invoke-ArmRequest -Method GET -Uri $nextUri -Body $null).Body
        $values = Get-JsonMember -Node $page -Name 'value'
        if ($values -is [System.Text.Json.Nodes.JsonArray]) {
            foreach ($item in $values) {
                if ($null -ne $item) {
                    $items.Add($item)
                }
            }
        }
        $nextUri = Get-JsonString -Node (Get-JsonMember -Node $page -Name 'nextLink')
    }
    return $items.ToArray()
}

function Get-PollInterval {
    param(
        [AllowNull()]
        [object] $Headers,
        [int] $Current,
        [datetime] $Deadline
    )

    $interval = $Current
    $retryAfter = Get-HeaderValue -Headers $Headers -Name 'Retry-After'
    if ($null -ne $retryAfter -and $retryAfter -match '^\d+$') {
        $interval = [Math]::Min([int]$retryAfter, 300)
    }
    $remaining = [int][Math]::Floor(($Deadline - [DateTime]::UtcNow).TotalSeconds)
    return [int][Math]::Max(0, [Math]::Min($interval, $remaining))
}

function Wait-ArmOperation {
    # Follows an asynchronous ARM update to a terminal state within one deadline. Waits the
    # server-requested interval before the first poll. Returns
    # [pscustomobject]@{ Status = Synchronous|Succeeded|Failed|Canceled|Unknown; Message }.
    # Any failure to observe the operation yields Unknown - the write may have been applied.
    param(
        [Parameter(Mandatory = $true)]
        [object] $PutResponse,
        [Parameter(Mandatory = $true)]
        [string] $ResourceUri
    )

    $statusCode = 0
    if ($null -ne $PutResponse.StatusCode) {
        $statusCode = [int]$PutResponse.StatusCode
    }
    if ($statusCode -ne 202) {
        return [pscustomobject]@{ Status = 'Synchronous'; Message = "HTTP $statusCode" }
    }

    $asyncUri = Get-HeaderValue -Headers $PutResponse.Headers -Name 'Azure-AsyncOperation'
    $locationUri = Get-HeaderValue -Headers $PutResponse.Headers -Name 'Location'
    $budget = [Math]::Min($script:OperationTimeout, [Math]::Max(1, (Get-RemainingJobBudget)))
    $deadline = [DateTime]::UtcNow.AddSeconds($budget)
    $interval = Get-PollInterval -Headers $PutResponse.Headers -Current 5 -Deadline $deadline

    try {
        if (-not [string]::IsNullOrWhiteSpace($asyncUri)) {
            while ($true) {
                Start-Sleep -Seconds $interval
                $poll = Invoke-ArmRequest -Method GET -Uri $asyncUri -Body $null
                $status = [string](Get-JsonString -Node (Get-JsonMember -Node $poll.Body -Name 'status'))
                if ($status -ieq 'Succeeded') {
                    return [pscustomobject]@{ Status = 'Succeeded'; Message = 'Azure-AsyncOperation reported Succeeded' }
                }
                if ($status -ieq 'Failed' -or $status -ieq 'Canceled' -or $status -ieq 'Cancelled') {
                    $errorNode = Get-JsonMember -Node $poll.Body -Name 'error'
                    $errorText = if ($null -eq $errorNode) { $status } else { $errorNode.ToJsonString() }
                    $finalStatus = if ($status -ieq 'Failed') { 'Failed' } else { 'Canceled' }
                    return [pscustomobject]@{ Status = $finalStatus; Message = "Azure-AsyncOperation reported $finalStatus`: $errorText" }
                }
                if ([DateTime]::UtcNow -ge $deadline) {
                    return [pscustomobject]@{ Status = 'Unknown'; Message = "Azure-AsyncOperation still '$status' after $budget seconds" }
                }
                $interval = Get-PollInterval -Headers $poll.Headers -Current $interval -Deadline $deadline
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($locationUri)) {
            while ($true) {
                Start-Sleep -Seconds $interval
                $poll = Invoke-ArmRequest -Method GET -Uri $locationUri -Body $null
                $pollStatus = 0
                if ($null -ne $poll.StatusCode) {
                    $pollStatus = [int]$poll.StatusCode
                }
                if ($pollStatus -ne 202) {
                    return [pscustomobject]@{ Status = 'Succeeded'; Message = "Location returned HTTP $pollStatus" }
                }
                if ([DateTime]::UtcNow -ge $deadline) {
                    return [pscustomobject]@{ Status = 'Unknown'; Message = "Location still HTTP 202 after $budget seconds" }
                }
                $interval = Get-PollInterval -Headers $poll.Headers -Current $interval -Deadline $deadline
            }
        }

        # 202 without operation headers: poll the resource itself until the mode is visible.
        while ($true) {
            Start-Sleep -Seconds $interval
            $resource = (Invoke-ArmRequest -Method GET -Uri $ResourceUri -Body $null).Body
            $mode = Get-JsonString -Node (Get-JsonMember -Node (Get-JsonMember -Node (Get-JsonMember -Node (Get-JsonMember -Node $resource -Name 'properties') -Name 'tieringPolicy') -Name 'ArchivedRP') -Name 'tieringMode')
            if ($mode -eq 'TierRecommended') {
                return [pscustomobject]@{ Status = 'Succeeded'; Message = 'No operation headers; resource shows the new mode' }
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                return [pscustomobject]@{ Status = 'Unknown'; Message = "No operation headers and the resource did not show TierRecommended within $budget seconds" }
            }
            $interval = Get-PollInterval -Headers $null -Current 5 -Deadline $deadline
        }
    }
    catch {
        return [pscustomobject]@{ Status = 'Unknown'; Message = "The update was accepted (HTTP 202) but its operation could not be observed: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------------------------
# Result rows
# ---------------------------------------------------------------------------------------------

$results = [System.Collections.Generic.List[object]]::new()
$counters = [ordered]@{
    vaultsScanned     = 0
    vaultsSkipped     = 0
    policiesMatched   = 0
    policiesEvaluated = 0
    candidates        = 0
    policiesWritten   = 0
    writesSubmitted   = 0
    writesUnknown     = 0
    writesFailed      = 0
    writesSkipped     = 0
    errors            = 0
}

function Format-ResultRow {
    param(
        [AllowNull()][object] $Vault,
        [AllowNull()][object] $Policy,
        [AllowNull()][object] $Workload,
        [AllowNull()][object] $PolicyType,
        [AllowNull()][object] $ProtectedItemsCount,
        [AllowNull()][object] $RetentionHorizonMonths,
        [AllowNull()][object] $PreviousMode,
        [AllowNull()][object] $CurrentMode,
        [Parameter(Mandatory = $true)][string] $Action,
        [Parameter(Mandatory = $true)][string] $Stage,
        [AllowNull()][object] $OperationStatus,
        [AllowNull()][object] $Message
    )

    $vaultName = $null
    $vaultId = $null
    if ($null -ne $Vault) {
        $vaultName = Get-JsonString -Node (Get-JsonMember -Node $Vault -Name 'name')
        $vaultId = Get-JsonString -Node (Get-JsonMember -Node $Vault -Name 'id')
    }
    $policyName = $null
    $policyId = $null
    if ($null -ne $Policy) {
        $policyName = Get-JsonString -Node (Get-JsonMember -Node $Policy -Name 'name')
        $policyId = Get-JsonString -Node (Get-JsonMember -Node $Policy -Name 'id')
    }

    return [ordered]@{
        timestamp              = [DateTime]::UtcNow.ToString('o')
        subscriptionId         = $SubscriptionId
        scopeType              = $ScopeType
        vault                  = $vaultName
        vaultId                = $vaultId
        policy                 = $policyName
        policyId               = $policyId
        workload               = $Workload
        policyType             = $PolicyType
        protectedItemsCount    = $ProtectedItemsCount
        retentionHorizonMonths = $RetentionHorizonMonths
        previousMode           = $PreviousMode
        currentMode            = $CurrentMode
        action                 = $Action
        stage                  = $Stage
        operationStatus        = $OperationStatus
        message                = $Message
    }
}

function Write-ResultRow {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary] $Row
    )

    $results.Add([pscustomobject]$Row)
    $json = ($Row | ConvertTo-Json -Compress)
    Write-Output $json
    if ($Row.action -eq 'Error' -or $Row.action -eq 'WriteOutcomeUnknown') {
        Write-Warning $json
    }
}

# ---------------------------------------------------------------------------------------------
# Phase 1 - discover and classify (no writes)
# ---------------------------------------------------------------------------------------------

$script:ArmAccessToken = Get-ManagedIdentityToken
$encodedSubscription = [Uri]::EscapeDataString($SubscriptionId)

if ($ScopeType -eq 'ResourceGroup') {
    $encodedResourceGroup = [Uri]::EscapeDataString($ResourceGroupName)
    $vaultListUri = "$script:ManagementEndpoint/subscriptions/$encodedSubscription/resourceGroups/$encodedResourceGroup/providers/Microsoft.RecoveryServices/vaults?api-version=$ApiVersion"
}
else {
    $vaultListUri = "$script:ManagementEndpoint/subscriptions/$encodedSubscription/providers/Microsoft.RecoveryServices/vaults?api-version=$ApiVersion"
}

$vaults = @(Get-ArmCollection -Uri $vaultListUri)
if ($VaultName.Length -gt 0) {
    $filteredVaults = [System.Collections.Generic.List[object]]::new()
    foreach ($listedVault in $vaults) {
        if ((Get-JsonString -Node (Get-JsonMember -Node $listedVault -Name 'name')) -eq $VaultName) {
            $filteredVaults.Add($listedVault)
        }
    }
    $vaults = $filteredVaults.ToArray()
}
$counters.vaultsScanned = $vaults.Count

$candidateList = [System.Collections.Generic.List[object]]::new()
$safeRedundancies = @('GeoRedundant', 'LocallyRedundant')
$zoneRedundancies = @('ZoneRedundant', 'ZRS')

foreach ($vault in $vaults) {
    $vaultId = Get-JsonString -Node (Get-JsonMember -Node $vault -Name 'id')
    try {
        if ([string]::IsNullOrWhiteSpace($vaultId)) {
            throw 'The vault listing entry has no resource id.'
        }
        $vaultDetailsUri = "$script:ManagementEndpoint$vaultId`?api-version=$ApiVersion"
        $vaultDetails = (Invoke-ArmRequest -Method GET -Uri $vaultDetailsUri -Body $null).Body
        $redundancy = Get-JsonString -Node (Get-JsonMember -Node (Get-JsonMember -Node (Get-JsonMember -Node $vaultDetails -Name 'properties') -Name 'redundancySettings') -Name 'standardTierStorageRedundancy')
        if ($redundancy -in $zoneRedundancies) {
            $counters.vaultsSkipped++
            Write-ResultRow -Row (Format-ResultRow -Vault $vault -Policy $null -Workload $null -PolicyType $null -ProtectedItemsCount $null -RetentionHorizonMonths $null -PreviousMode $null -CurrentMode $null -Action 'SkippedZoneRedundantVault' -Stage 'Discover' -OperationStatus $null -Message 'Vault archive is not supported on zone-redundant vaults.')
            continue
        }
        if ($redundancy -notin $safeRedundancies) {
            $shown = if ($null -eq $redundancy) { 'missing' } else { "'$redundancy'" }
            throw "Could not establish the vault's standard-tier storage redundancy ($shown); refusing to evaluate its policies."
        }

        $policyListUri = "$script:ManagementEndpoint$vaultId/backupPolicies?api-version=$ApiVersion"
        $policies = @(Get-ArmCollection -Uri $policyListUri)
        if ($PolicyName.Length -gt 0) {
            $filteredPolicies = [System.Collections.Generic.List[object]]::new()
            foreach ($candidatePolicy in $policies) {
                if ((Get-JsonString -Node (Get-JsonMember -Node $candidatePolicy -Name 'name')) -eq $PolicyName) {
                    $filteredPolicies.Add($candidatePolicy)
                }
            }
            $policies = $filteredPolicies.ToArray()
        }
    }
    catch {
        $counters.errors++
        $counters.vaultsSkipped++
        Write-ResultRow -Row (Format-ResultRow -Vault $vault -Policy $null -Workload $null -PolicyType $null -ProtectedItemsCount $null -RetentionHorizonMonths $null -PreviousMode $null -CurrentMode $null -Action 'Error' -Stage 'Discover' -OperationStatus $null -Message $_.Exception.Message)
        continue
    }

    foreach ($listedPolicy in $policies) {
        try {
            # Always evaluate a fresh point read; collection results can be stale.
            $policyId = Get-JsonString -Node (Get-JsonMember -Node $listedPolicy -Name 'id')
            if ([string]::IsNullOrWhiteSpace($policyId)) {
                throw 'The policy listing entry has no resource id.'
            }
            $policyUri = "$script:ManagementEndpoint$policyId`?api-version=$ApiVersion"
            $policyResponse = Invoke-ArmRequest -Method GET -Uri $policyUri -Body $null
            $policy = $policyResponse.Body
            $properties = Get-JsonMember -Node $policy -Name 'properties'
            $counters.policiesEvaluated++

            $managementType = Get-JsonString -Node (Get-JsonMember -Node $properties -Name 'backupManagementType')
            $policyType = Get-JsonString -Node (Get-JsonMember -Node $properties -Name 'policyType')
            $protectedItemsCount = Get-JsonNonNegativeInt -Node (Get-JsonMember -Node $properties -Name 'protectedItemsCount')
            $currentMode = Get-JsonString -Node (Get-JsonMember -Node (Get-JsonMember -Node (Get-JsonMember -Node $properties -Name 'tieringPolicy') -Name 'ArchivedRP') -Name 'tieringMode')
            $etag = Get-JsonString -Node (Get-JsonMember -Node $policy -Name 'eTag')

            if ($managementType -ne 'AzureIaasVM') {
                Write-ResultRow -Row (Format-ResultRow -Vault $vault -Policy $policy -Workload $managementType -PolicyType $policyType -ProtectedItemsCount $protectedItemsCount -RetentionHorizonMonths $null -PreviousMode $null -CurrentMode $null -Action 'SkippedUnsupportedWorkload' -Stage 'Evaluate' -OperationStatus $null -Message $null)
                continue
            }
            $counters.policiesMatched++

            $horizonMonths = Get-RetentionHorizon -RetentionPolicy (Get-JsonMember -Node $properties -Name 'retentionPolicy')

            $action = $null
            $message = $null
            if ($currentMode -eq 'TierRecommended') {
                $action = 'AlreadyCompliant'
            }
            elseif ($currentMode -eq 'TierAfter') {
                $action = 'AlreadyEnabledAlternateMode'
            }
            elseif ($null -ne $currentMode -and $currentMode -ne 'DoNotTier') {
                $action = 'SkippedUnknownMode'
                $message = "Unrecognised tiering mode '$currentMode'."
            }
            elseif ($horizonMonths -lt $MinimumRetentionMonths) {
                $action = 'SkippedNoArchiveEligibility'
                $message = "Monthly/yearly retention horizon is $horizonMonths month(s); at least $MinimumRetentionMonths are required before any recovery point can become archive-eligible. (Azure's per-recovery-point age, dependency and region rules still apply.)"
            }
            elseif ($null -eq $protectedItemsCount) {
                $action = 'SkippedProtectedItemsUnknown'
                $message = 'The API did not return a usable protectedItemsCount; refusing to write without knowing how many items the policy protects.'
            }
            elseif ($protectedItemsCount -gt $MaxProtectedItemsPerPolicy) {
                $action = 'SkippedProtectedItemsExceedLimit'
                $message = "Policy protects $protectedItemsCount item(s); MaxProtectedItemsPerPolicy is $MaxProtectedItemsPerPolicy. Raise the limit deliberately to include it."
            }
            elseif ($protectedItemsCount -gt 0 -and [string]::IsNullOrWhiteSpace($etag) -and -not $AllowWriteWithoutETag) {
                $action = 'SkippedNoConcurrencyToken'
                $message = 'The API returned no ETag for a policy that protects items; a full-policy write could overwrite a concurrent change. Set AllowWriteWithoutETag=true only inside an exclusive change window.'
            }
            else {
                $action = 'WouldEnableTierRecommended'
                $counters.candidates++
                $candidateList.Add([pscustomobject]@{
                    Vault               = $vault
                    Policy              = $policy
                    PolicyUri           = $policyUri
                    Workload            = $managementType
                    PolicyType          = $policyType
                    ProtectedItemsCount = $protectedItemsCount
                    HorizonMonths       = $horizonMonths
                    PreviousMode        = $currentMode
                })
            }

            Write-ResultRow -Row (Format-ResultRow -Vault $vault -Policy $policy -Workload $managementType -PolicyType $policyType -ProtectedItemsCount $protectedItemsCount -RetentionHorizonMonths $horizonMonths -PreviousMode $currentMode -CurrentMode $currentMode -Action $action -Stage 'Evaluate' -OperationStatus $null -Message $message)
        }
        catch {
            $counters.errors++
            Write-ResultRow -Row (Format-ResultRow -Vault $vault -Policy $listedPolicy -Workload $null -PolicyType $null -ProtectedItemsCount $null -RetentionHorizonMonths $null -PreviousMode $null -CurrentMode $null -Action 'Error' -Stage 'Evaluate' -OperationStatus $null -Message $_.Exception.Message)
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Phase 2 - preflight and apply
# ---------------------------------------------------------------------------------------------

$abortReason = $null

if ($Apply) {
    if ($counters.errors -gt 0) {
        $abortReason = 'DiscoveryErrors'
    }
    elseif ($counters.policiesMatched -eq 0) {
        $abortReason = 'NoPolicyMatched'
    }
    elseif ($ExpectedMatches -gt 0 -and $counters.policiesMatched -ne $ExpectedMatches) {
        $abortReason = 'ExpectedMatchesMismatch'
    }
    elseif ($counters.candidates -gt $MaxChanges) {
        $abortReason = 'MaxChangesExceeded'
    }
}
elseif ($counters.policiesMatched -eq 0 -and ($VaultName.Length -gt 0 -or $PolicyName.Length -gt 0)) {
    Write-Warning 'No AzureIaasVM policy matched the supplied filters. Check the exact vault and policy names before running Apply.'
}

function Get-TieringMode {
    param(
        [AllowNull()]
        [object] $PolicyNode
    )

    return Get-JsonString -Node (Get-JsonMember -Node (Get-JsonMember -Node (Get-JsonMember -Node (Get-JsonMember -Node $PolicyNode -Name 'properties') -Name 'tieringPolicy') -Name 'ArchivedRP') -Name 'tieringMode')
}

function Get-ComparablePropertySet {
    # A copy of the policy's properties with the intended change and the server-managed counters
    # removed, so that before/after comparison flags every other difference (including any other
    # member of tieringPolicy).
    param(
        [Parameter(Mandatory = $true)]
        [object] $PolicyNode
    )

    $copy = Copy-JsonNode -Node (Get-JsonMember -Node $PolicyNode -Name 'properties')
    if ($null -eq $copy) {
        return $null
    }
    Clear-JsonMember -Node $copy -Name 'protectedItemsCount'
    Clear-JsonMember -Node $copy -Name 'resourceGuardOperationRequests'
    Clear-JsonMember -Node (Get-JsonMember -Node $copy -Name 'tieringPolicy') -Name 'ArchivedRP'
    return , $copy
}

if ($Apply -and $null -eq $abortReason) {
    foreach ($candidate in $candidateList) {
        if ((Get-RemainingJobBudget) -le 0) {
            $counters.writesSkipped++
            Write-ResultRow -Row (Format-ResultRow -Vault $candidate.Vault -Policy $candidate.Policy -Workload $candidate.Workload -PolicyType $candidate.PolicyType -ProtectedItemsCount $candidate.ProtectedItemsCount -RetentionHorizonMonths $candidate.HorizonMonths -PreviousMode $candidate.PreviousMode -CurrentMode $candidate.PreviousMode -Action 'SkippedJobBudgetExhausted' -Stage 'Write' -OperationStatus $null -Message "JobTimeBudgetSeconds ($script:JobBudget) elapsed before this policy was written; rerun to continue.")
            continue
        }

        $stage = 'PreWrite'
        $operation = $null
        try {
            $preWriteResponse = Invoke-ArmRequest -Method GET -Uri $candidate.PolicyUri -Body $null
            $preWritePolicy = $preWriteResponse.Body
            $preWriteDifference = Get-FirstDifference -Left (Get-JsonMember -Node $candidate.Policy -Name 'properties') -Right (Get-JsonMember -Node $preWritePolicy -Name 'properties') -Path '$.properties'
            if ($null -ne $preWriteDifference) {
                throw "The policy changed after evaluation (first difference at $preWriteDifference). No update was submitted; rerun the job against the new version."
            }

            # Build the payload from the raw response text so every value is sent back exactly.
            $payload = ConvertTo-JsonNode -Text $preWriteResponse.Content
            foreach ($readOnlyRoot in @('id', 'name', 'type', 'systemData')) {
                Clear-JsonMember -Node $payload -Name $readOnlyRoot
            }
            $payloadProperties = Get-JsonMember -Node $payload -Name 'properties'
            if ($null -eq $payloadProperties) {
                throw 'The policy has no properties object; refusing to write.'
            }
            Clear-JsonMember -Node $payloadProperties -Name 'protectedItemsCount'
            Clear-JsonMember -Node $payloadProperties -Name 'resourceGuardOperationRequests'
            $tieringPolicyNode = Get-JsonMember -Node $payloadProperties -Name 'tieringPolicy'
            if ($null -eq $tieringPolicyNode) {
                $tieringPolicyNode = [System.Text.Json.Nodes.JsonObject]::new()
                $payloadProperties['tieringPolicy'] = $tieringPolicyNode
            }
            $archivedRpNode = Get-JsonMember -Node $tieringPolicyNode -Name 'ArchivedRP'
            if ($null -eq $archivedRpNode) {
                $archivedRpNode = [System.Text.Json.Nodes.JsonObject]::new()
                $tieringPolicyNode['ArchivedRP'] = $archivedRpNode
            }
            Clear-JsonMember -Node $archivedRpNode -Name 'tieringMode'
            Clear-JsonMember -Node $archivedRpNode -Name 'duration'
            Clear-JsonMember -Node $archivedRpNode -Name 'durationType'
            $archivedRpNode['tieringMode'] = [System.Text.Json.Nodes.JsonValue]::Create('TierRecommended')

            # If-Match is sent when an ETag exists; the API does not document compare-and-swap
            # semantics for backup policies, so this is best-effort, not a guarantee.
            $etag = Get-JsonString -Node (Get-JsonMember -Node $preWritePolicy -Name 'eTag')
            $putHeaders = @{}
            if (-not [string]::IsNullOrWhiteSpace($etag)) {
                $putHeaders['If-Match'] = $etag
            }

            $stage = 'Write'
            $counters.writesSubmitted++
            $putResponse = $null
            $putFailure = $null
            $putFailureInfo = $null
            try {
                $putResponse = Invoke-ArmRequest -Method PUT -Uri $candidate.PolicyUri -Body $payload.ToJsonString() -AdditionalHeaders $putHeaders
            }
            catch {
                $putFailure = $_.Exception.Message
                $putFailureInfo = $script:LastArmError
            }

            if ($null -ne $putFailure) {
                $definitive = $false
                if ($null -ne $putFailureInfo -and $null -ne $putFailureInfo.StatusCode) {
                    $code = [int]$putFailureInfo.StatusCode
                    $definitive = ($code -ge 400) -and ($code -lt 500) -and ($code -ne 408)
                }
                if ($definitive) {
                    throw "PUT was rejected: $putFailure"
                }

                # Ambiguous (transport failure, timeout, 5xx): the write may have been applied.
                # Re-read for a bounded period instead of resubmitting.
                $reconciled = $false
                $reconcileError = $null
                for ($reconcileAttempt = 1; $reconcileAttempt -le 6; $reconcileAttempt++) {
                    try {
                        $reRead = (Invoke-ArmRequest -Method GET -Uri $candidate.PolicyUri -Body $null).Body
                        if ((Get-TieringMode -PolicyNode $reRead) -eq 'TierRecommended') {
                            $reconciled = $true
                            break
                        }
                    }
                    catch {
                        $reconcileError = $_.Exception.Message
                    }
                    if ($reconcileAttempt -lt 6) {
                        Start-Sleep -Seconds 5
                    }
                }
                if (-not $reconciled) {
                    $counters.writesUnknown++
                    $unknownMessage = "PUT outcome unknown: $putFailure"
                    if ($null -ne $reconcileError) {
                        $unknownMessage += " Reconciliation read also failed: $reconcileError"
                    }
                    Write-ResultRow -Row (Format-ResultRow -Vault $candidate.Vault -Policy $candidate.Policy -Workload $candidate.Workload -PolicyType $candidate.PolicyType -ProtectedItemsCount $candidate.ProtectedItemsCount -RetentionHorizonMonths $candidate.HorizonMonths -PreviousMode $candidate.PreviousMode -CurrentMode $null -Action 'WriteOutcomeUnknown' -Stage 'Write' -OperationStatus 'Unknown' -Message $unknownMessage)
                    continue
                }
                $operation = [pscustomobject]@{ Status = 'Succeeded'; Message = "PUT response was lost ($putFailure) but the policy shows TierRecommended on re-read." }
            }
            else {
                $operation = Wait-ArmOperation -PutResponse $putResponse -ResourceUri $candidate.PolicyUri
            }

            if ($operation.Status -eq 'Unknown') {
                $counters.writesUnknown++
                Write-ResultRow -Row (Format-ResultRow -Vault $candidate.Vault -Policy $candidate.Policy -Workload $candidate.Workload -PolicyType $candidate.PolicyType -ProtectedItemsCount $candidate.ProtectedItemsCount -RetentionHorizonMonths $candidate.HorizonMonths -PreviousMode $candidate.PreviousMode -CurrentMode $null -Action 'WriteOutcomeUnknown' -Stage 'Write' -OperationStatus 'Unknown' -Message $operation.Message)
                continue
            }
            if ($operation.Status -eq 'Failed' -or $operation.Status -eq 'Canceled') {
                throw "The update operation ended in state $($operation.Status): $($operation.Message)"
            }

            $stage = 'Verify'
            # The operation is complete, but reads can lag briefly behind the write. Re-read for up to
            # one minute before declaring the outcome unknown.
            $verifiedPolicy = $null
            $verifiedMode = $null
            for ($verificationAttempt = 1; $verificationAttempt -le 12; $verificationAttempt++) {
                $verifiedPolicy = (Invoke-ArmRequest -Method GET -Uri $candidate.PolicyUri -Body $null).Body
                $verifiedMode = Get-TieringMode -PolicyNode $verifiedPolicy
                if ($verifiedMode -eq 'TierRecommended' -or $verificationAttempt -eq 12) {
                    break
                }
                Start-Sleep -Seconds 5
            }
            if ($verifiedMode -ne 'TierRecommended') {
                $counters.writesUnknown++
                Write-ResultRow -Row (Format-ResultRow -Vault $candidate.Vault -Policy $candidate.Policy -Workload $candidate.Workload -PolicyType $candidate.PolicyType -ProtectedItemsCount $candidate.ProtectedItemsCount -RetentionHorizonMonths $candidate.HorizonMonths -PreviousMode $candidate.PreviousMode -CurrentMode $verifiedMode -Action 'WriteOutcomeUnknown' -Stage 'Verify' -OperationStatus $operation.Status -Message "The operation reported $($operation.Status) but the policy still reports '$verifiedMode' after 12 reads.")
                continue
            }

            $propertyDifference = Get-FirstDifference -Left (Get-ComparablePropertySet -PolicyNode $preWritePolicy) -Right (Get-ComparablePropertySet -PolicyNode $verifiedPolicy) -Path '$.properties'
            if ($null -ne $propertyDifference) {
                throw "Post-write verification detected a schedule or retention change or other unintended drift (first difference at $propertyDifference)."
            }
            $tagDifference = Get-FirstDifference -Left (Get-JsonMember -Node $preWritePolicy -Name 'tags') -Right (Get-JsonMember -Node $verifiedPolicy -Name 'tags') -Path '$.tags'
            if ($null -ne $tagDifference) {
                throw "Post-write verification detected a tag change (first difference at $tagDifference)."
            }

            $counters.policiesWritten++
            Write-ResultRow -Row (Format-ResultRow -Vault $candidate.Vault -Policy $candidate.Policy -Workload $candidate.Workload -PolicyType $candidate.PolicyType -ProtectedItemsCount $candidate.ProtectedItemsCount -RetentionHorizonMonths $candidate.HorizonMonths -PreviousMode $candidate.PreviousMode -CurrentMode 'TierRecommended' -Action 'EnabledAndVerified' -Stage 'Verify' -OperationStatus $operation.Status -Message $operation.Message)
        }
        catch {
            $counters.errors++
            if ($stage -eq 'Write') {
                $counters.writesFailed++
            }
            $operationStatus = $null
            if ($null -ne $operation) {
                $operationStatus = $operation.Status
            }
            Write-ResultRow -Row (Format-ResultRow -Vault $candidate.Vault -Policy $candidate.Policy -Workload $candidate.Workload -PolicyType $candidate.PolicyType -ProtectedItemsCount $candidate.ProtectedItemsCount -RetentionHorizonMonths $candidate.HorizonMonths -PreviousMode $candidate.PreviousMode -CurrentMode $null -Action 'Error' -Stage $stage -OperationStatus $operationStatus -Message $_.Exception.Message)
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------------------------

$summary = [ordered]@{
    runbookVersion             = $script:RunbookVersion
    subscriptionId             = $SubscriptionId
    scopeType                  = $ScopeType
    resourceGroup              = $ResourceGroupName
    vaultFilter                = $VaultName
    policyFilter               = $PolicyName
    apply                      = $Apply
    allowUnfilteredApply       = $AllowUnfilteredApply
    allowWriteWithoutETag      = $AllowWriteWithoutETag
    maxChanges                 = $MaxChanges
    expectedMatches            = $ExpectedMatches
    maxProtectedItemsPerPolicy = $MaxProtectedItemsPerPolicy
    minimumRetentionMonths     = $MinimumRetentionMonths
    jobTimeBudgetSeconds       = $JobTimeBudgetSeconds
    vaultsScanned              = $counters.vaultsScanned
    vaultsSkipped              = $counters.vaultsSkipped
    policiesMatched            = $counters.policiesMatched
    policiesEvaluated          = $counters.policiesEvaluated
    candidates                 = $counters.candidates
    policiesWritten            = $counters.policiesWritten
    writesSubmitted            = $counters.writesSubmitted
    writesUnknown              = $counters.writesUnknown
    writesFailed               = $counters.writesFailed
    writesSkipped              = $counters.writesSkipped
    errors                     = $counters.errors
    abortReason                = $abortReason
}
Write-Output ('SUMMARY ' + ($summary | ConvertTo-Json -Compress))

if ($null -ne $abortReason) {
    $explanation = switch ($abortReason) {
        'DiscoveryErrors' { "$($counters.errors) error(s) occurred while discovering or classifying policies, so the change set could not be trusted; nothing was written." }
        'NoPolicyMatched' { 'no AzureIaasVM policy matched the supplied filters, so nothing was written. Check the exact vault and policy names.' }
        'ExpectedMatchesMismatch' { "the filters matched $($counters.policiesMatched) AzureIaasVM policy(ies) but ExpectedMatches is $ExpectedMatches; nothing was written." }
        'MaxChangesExceeded' { "$($counters.candidates) policy(ies) would change but MaxChanges is $MaxChanges; nothing was written. Narrow the filters or raise MaxChanges deliberately." }
        default { 'apply was aborted before any write.' }
    }
    throw "Apply aborted ($abortReason): $explanation"
}
if ($counters.writesUnknown -gt 0) {
    throw "Smart Tiering remediation finished with $($counters.writesUnknown) write(s) of unknown outcome and $($counters.errors) error(s). Re-run in audit mode to establish the current state before applying again."
}
if ($counters.writesSkipped -gt 0) {
    throw "Smart Tiering remediation stopped after the job time budget elapsed; $($counters.writesSkipped) candidate(s) were not written. Rerun to continue."
}
if ($counters.errors -gt 0) {
    throw "Smart Tiering remediation completed with $($counters.errors) error(s)."
}
