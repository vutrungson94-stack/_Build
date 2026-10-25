
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('SharedUtils')

$script:AlertLocks = @{}

function Get-AlertObjectValue {
    param($Object, [string]$Name, $Default = $null)

Set-StrictMode -Version 1.0
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]$key -ieq $Name) { return $Object[$key] }
        }
        return $Default
    }
    try {
        if ($null -ne $Object.PSObject -and ($Object.PSObject.Properties.Name -contains $Name)) { return $Object.$Name }
    } catch { }
    return $Default
}

function Get-AlertTenantId {
    param($State, $Data = $null)
    $value = Get-AlertObjectValue $Data 'tenantId' $null
    if ($null -eq $value) { $value = Get-AlertObjectValue $Data 'TenantId' $null }
    if ($null -eq $value -and $State) { $value = Get-AlertObjectValue $State 'TenantId' $null }
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return 'default' }
    return [string]$value
}

function Get-AlertCorrelationId {
    param($State, $Data = $null)
    $value = Get-AlertObjectValue $Data 'correlationId' $null
    if ($null -eq $value) { $value = Get-AlertObjectValue $Data 'CorrelationId' $null }
    if ($null -eq $value -and $State) { $value = Get-AlertObjectValue $State 'CorrelationId' $null }
    if ($null -eq $value) { return '' }
    return [string]$value
}

function Get-AlertSensitiveKey {
    param([string]$Name)
    return ([string]$Name -match '(?i)(token|secret|password|passwd|api[_-]?key|access[_-]?key|authorization|credential|cookie|webhook|sas|signature|private[_-]?key|auth|jwt|session)')
}

function Get-AlertRedactedUrl {
    param([AllowNull()][string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    try {
        $uri = [System.Uri]::new($Url)
        if ($uri.Scheme -notin @('http', 'https')) { return '[redacted-url]' }
        $builder = [System.UriBuilder]::new($uri)
        if (-not [string]::IsNullOrWhiteSpace($builder.UserName) -or -not [string]::IsNullOrWhiteSpace($builder.Password)) {
            $builder.UserName = '***'
            $builder.Password = '***'
        }
        $pairs = @()
        $query = [string]$builder.Query
        if ($query.StartsWith('?')) { $query = $query.Substring(1) }
        if ($query) {
            foreach ($part in ($query -split '&')) {
                if (-not $part) { continue }
                $bits = $part -split '=', 2
                $name = $bits[0]
                $value = if ($bits.Count -gt 1) { $bits[1] } else { '' }
                if (Get-AlertSensitiveKey $name) { $value = '***REDACTED***' }
                $pairs += ('{0}={1}' -f $name, $value)
            }
        }
        $builder.Query = ($pairs -join '&')
        $path = [string]$builder.Path
        if ($path -match '(?i)/(?:services|hooks|webhook|webhooks)(?:/|$)') {
            $path = '/[redacted-path]'
        } else {
            $segments = @($path -split '/' | ForEach-Object { if ($_ -match '^[A-Za-z0-9_-]{24,}$') { '[redacted-path]' } else { $_ } })
            $path = ($segments -join '/')
        }
        $builder.Path = $path
        $builder.Fragment = ''
        return $builder.Uri.AbsoluteUri
    } catch {
        return '[redacted-url]'
    }
}

<#
.SYNOPSIS
    Resolves the canonical secret-redaction routine and delegates to it.
.DESCRIPTION
    Internal guard shared by this module's redaction wrapper. The canonical routine
    is SharedUtils.Protect-BuildSecretText, resolved on every call (importing
    SharedUtils on demand when it is not loaded yet) so redaction never depends on
    module load order. It never falls back to a narrower, locally maintained
    pattern set: when the canonical routine cannot be resolved at all the text is
    fail-closed to the redaction marker rather than emitted unscrubbed.
#>
# Invoke-BuildSecretProtect is NOT defined here: SharedUtils owns and exports it
# (see SharedUtils.Invoke-BuildSecretProtect). This module used to carry a
# byte-identical private copy; because it was never exported, Alerting silently
# called its own clone instead of the "shared" helper, so the four copies only
# agreed by accident. SharedUtils is a declared module dependency of Alerting.

# Alerting's URL policy for Protect-BuildSecretText -RedactUrls: mask userinfo,
# redact sensitive query values and long path segments, then drop the query string
# (webhook URLs carry the token in the query, and a scrubber cannot tell a harmless
# parameter from a credential one without a per-caller allow-list).
$script:AlertUrlRedactor = {
    param([AllowNull()][string]$Url)
    $safeUrl = Get-AlertRedactedUrl -Url $Url
    if ($safeUrl -match '\?') { return ($safeUrl -split '\?', 2)[0] }
    return $safeUrl
}

<#
.SYNOPSIS
    Scrubs credentials/tokens (and webhook URLs) out of alert text.
.DESCRIPTION
    Thin wrapper around the canonical redaction routine
    (SharedUtils.Protect-BuildSecretText). It used to carry a fully inline pattern
    set that ignored security.redactPatterns completely, so alert text was scrubbed
    with a different (partly wider, partly narrower) rule set than log and report
    text. Alerting is the only consumer that used to scrub URLs, so it is the only
    one that opts in via -RedactUrls and the only one that supplies a URL policy;
    everything else about the redaction is now shared.
#>
function Protect-AlertText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Text, [PSCustomObject]$State = $null)
    $value = [string]$Text
    if ([string]::IsNullOrEmpty($value)) { return '' }
    return (Invoke-BuildSecretProtect -Text $value -State $State -RedactUrls -UrlRedactor $script:AlertUrlRedactor)
}

function ConvertTo-AlertSafeValue {
    param($Value, [string]$Name = '', [PSCustomObject]$State = $null)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in @($Value.Keys | Sort-Object { [string]$_ })) {
            $childName = [string]$key
            if (Get-AlertSensitiveKey $childName) { $result[$childName] = '***REDACTED***' }
            else { $result[$childName] = ConvertTo-AlertSafeValue -Value $Value[$key] -Name $childName -State $State }
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return @(foreach ($item in $Value) { ConvertTo-AlertSafeValue -Value $item -Name $Name -State $State })
    }
    if ($Value -is [string] -or $Value -is [ValueType]) {
        if (Get-AlertSensitiveKey $Name) { return '***REDACTED***' }
        return Protect-AlertText -Text ([string]$Value) -State $State
    }
    if ($Value.PSObject -and $Value.PSObject.Properties.Count -gt 0) {
        $result = @{}
        foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
            if (Get-AlertSensitiveKey $property.Name) { $result[$property.Name] = '***REDACTED***' }
            else { $result[$property.Name] = ConvertTo-AlertSafeValue -Value $property.Value -Name $property.Name -State $State }
        }
        return $result
    }
    return Protect-AlertText -Text ([string]$Value) -State $State
}

function Get-AlertIdempotencyKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][object]$Payload,
        [PSCustomObject]$State = $null,
        [string]$TenantId = '',
        [string]$CorrelationId = ''
    )
    $keyPayload = ConvertTo-AlertSafeValue -Value $Payload -State $State
    if ($keyPayload -is [System.Collections.IDictionary]) {
        $explicit = Get-AlertObjectValue $keyPayload 'idempotencyKey' (Get-AlertObjectValue $keyPayload 'eventId' '')
        if ($explicit) { return [string]$explicit }
        $copy = @{}
        foreach ($key in $keyPayload.Keys) { if ([string]$key -notmatch '^(?i:timestamp)$') { $copy[$key] = $keyPayload[$key] } }
        $keyPayload = $copy
    }
    $canonical = [PSCustomObject]@{
        Label = $Label
        TenantId = $TenantId
        CorrelationId = $CorrelationId
        Payload = $keyPayload
    } | ConvertTo-Json -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonDefaultDepth' -Fallback 10) } else { 10 }) -Compress
    [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildStringHash')
    $hashed = Get-BuildStringHash -Text $canonical -OnFailure ''
    if ($hashed) { return $hashed }
    return [guid]::NewGuid().ToString('N')
}

function Get-AlertTimeout {
    param($Config, [int]$TimeoutSec = 0, [PSCustomObject]$State = $null)
    if ($TimeoutSec -gt 0) { return $TimeoutSec }
    $value = Get-AlertObjectValue $Config 'timeoutSec' 0
    if ($value) { return [int]$value }
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { return [int](Get-BuildConstant -Key 'WebhookTimeoutSec' -State $State -Fallback 10) } catch { }
    }
    return 10
}

function Get-AlertRetryValues {
    param($Config, [int]$MaxAttempts = 0, [int]$RetryDelayMs = 0, [PSCustomObject]$State = $null)
    $attempts = $MaxAttempts
    $retryConfig = Get-AlertObjectValue $Config 'retry' $null
    if ($attempts -le 0) { $attempts = [int](Get-AlertObjectValue $Config 'retryAttempts' 0) }
    if ($attempts -le 0 -and $retryConfig) { $attempts = [int](Get-AlertObjectValue $retryConfig 'maxAttempts' (Get-AlertObjectValue $retryConfig 'attempts' 0)) }
    if ($attempts -le 0) { $attempts = [int](Get-AlertObjectValue $Config 'maxAttempts' 0) }
    if ($attempts -le 0) { $attempts = 3 }
    $attempts = [Math]::Max(1, [Math]::Min(10, $attempts))
    $delay = $RetryDelayMs
    if ($delay -lt 0) { $delay = 0 }
    if ($delay -eq 0) { $delay = [int](Get-AlertObjectValue $Config 'retryDelayMs' 0) }
    if ($delay -eq 0 -and $retryConfig) { $delay = [int](Get-AlertObjectValue $retryConfig 'delayMs' 0) }
    $delay = [Math]::Max(0, [Math]::Min(10000, $delay))
    return @{ MaxAttempts = $attempts; RetryDelayMs = $delay }
}

function Invoke-WebhookPost {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][object]$Payload,
        [Parameter(Mandatory)][string]$Label,
        [hashtable]$Headers = @{},
        [PSCustomObject]$State,
        [int]$TimeoutSec = 0,
        [int]$MaxAttempts = 0,
        [int]$RetryDelayMs = 0,
        [string]$IdempotencyKey = '',
        [object]$Config = $null
    )
    try { $uri = [System.Uri]::new($Url) } catch { return $false }
    if ($uri.Scheme -notin @('http', 'https')) { return $false }
    $safePayload = ConvertTo-AlertSafeValue -Value $Payload -State $State
    $body = $safePayload | ConvertTo-Json -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonDefaultDepth' -Fallback 10) } else { 10 }) -Compress
    $effectiveTimeout = Get-AlertTimeout -Config $Config -TimeoutSec $TimeoutSec -State $State
    $retry = Get-AlertRetryValues -Config $Config -MaxAttempts $MaxAttempts -RetryDelayMs $RetryDelayMs -State $State
    if ([string]::IsNullOrWhiteSpace($IdempotencyKey)) { $IdempotencyKey = Get-AlertIdempotencyKey -Label $Label -Payload $Payload -State $State }
    $requestHeaders = @{}
    if ($Headers) { foreach ($key in @($Headers.Keys)) { $requestHeaders[[string]$key] = [string]$Headers[$key] } }
    if (-not ($requestHeaders.Keys | Where-Object { [string]$_ -ieq 'Idempotency-Key' })) { $requestHeaders['Idempotency-Key'] = $IdempotencyKey }
    $lastError = ''
    for ($attempt = 1; $attempt -le $retry.MaxAttempts; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri $Url -Method Post -Body $body -ContentType 'application/json' -Headers $requestHeaders -TimeoutSec $effectiveTimeout -ErrorAction Stop
            if ($response -is [bool] -and -not $response) { throw (Resolve-LogMessage -Key 'log.alerting.line251' -Fallback 'transport returned false') }
            $statusCode = 0
            try { if ($response -and ($response.PSObject.Properties.Name -contains 'StatusCode')) { $statusCode = [int]$response.StatusCode } } catch { }
            if ($statusCode -gt 0 -and ($statusCode -lt 200 -or $statusCode -ge 300)) { throw (Resolve-LogMessage -Key 'log.alerting.line254' -MessageArgs @([string]$statusCode) -Fallback "HTTP status $statusCode") }
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.alert.notificationSent' -MessageArgs @([string]$Label) -Fallback '[{0}] Notification sent') 'Info' $State }
            return $true
        } catch {
            $lastError = Protect-AlertText -Text $_.Exception.Message -State $State
            if ($attempt -lt $retry.MaxAttempts -and $retry.RetryDelayMs -gt 0) { Start-Sleep -Milliseconds $retry.RetryDelayMs }
        }
    }
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.alert.deliveryFailed' -MessageArgs @([string]$Label, [string]$retry.MaxAttempts, [string]$lastError) -Fallback '[{0}] Failed after {1} attempt(s): {2}') 'Warn' $State }
    return $false
}

# SINGLE SOURCE for the webhook-token rotation interval.
# BuildConstants.WebhookTokenRotationHours (alerting.rotationIntervalHours,
# shipped as 24) was declared and mapped to config but four call sites
# hardcoded 24, so tuning the key had no effect.
function Get-AlertRotationHours {
    [CmdletBinding()]
    [OutputType([double])]
    param()
    $v = 24
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $v = [int](Get-BuildConstant -Key 'WebhookTokenRotationHours' -Fallback 24) } catch { $v = 24 }
    }
    if ($v -le 0) { $v = 24 }
    return [double]$v
}

function New-WebhookToken {
    [CmdletBinding()]
    param([int]$ByteLength = 0)
    if ($ByteLength -le 0) { $ByteLength = 24; if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { try { $ByteLength = [int](Get-BuildConstant -Key 'WebhookTokenByteLength' -Fallback 24) } catch { } } }
    try {
        $bytes = [byte[]]::new([Math]::Max(16, $ByteLength))
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes)
        $rng.Dispose()
        return [System.Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    } catch { return [guid]::NewGuid().ToString('N') }
}

function Test-WebhookTokenExpired {
    [CmdletBinding()]
    param([DateTime]$CreatedAt, [double]$IntervalHours = 0)
    if ($CreatedAt -eq [DateTime]::MinValue) { return $true }
    if ($IntervalHours -le 0) { $IntervalHours = Get-AlertRotationHours }
    return (((Get-Date) - $CreatedAt).TotalHours -ge $IntervalHours)
}

function Update-WebhookToken {
    [CmdletBinding()]
    param([PSCustomObject]$State, [double]$IntervalHours = 0)
    $created = [DateTime]::MinValue
    if ($State -and ($State.PSObject.Properties.Name -contains 'AlertingTokenCreatedAt') -and $State.AlertingTokenCreatedAt) { try { $created = [DateTime]$State.AlertingTokenCreatedAt } catch { } }
    $existing = if ($State -and ($State.PSObject.Properties.Name -contains 'AlertingToken')) { [string]$State.AlertingToken } else { '' }
    if ($existing -and -not (Test-WebhookTokenExpired -CreatedAt $created -IntervalHours $IntervalHours)) { return $existing }
    $token = New-WebhookToken
    if ($State) {
        if (-not ($State.PSObject.Properties.Name -contains 'AlertingToken')) { $State | Add-Member -MemberType NoteProperty -Name 'AlertingToken' -Value $token -Force } else { $State.AlertingToken = $token }
        if (-not ($State.PSObject.Properties.Name -contains 'AlertingTokenCreatedAt')) { $State | Add-Member -MemberType NoteProperty -Name 'AlertingTokenCreatedAt' -Value (Get-Date) -Force } else { $State.AlertingTokenCreatedAt = Get-Date }
    }
    return $token
}

function Send-SlackNotification {
    param([string]$WebhookUrl, [string]$Message, [string]$Channel, [string]$Username = 'gbuild', [string]$Emoji = ':rocket:', [PSCustomObject]$State)
    $payload = [ordered]@{ username = $Username; icon_emoji = $Emoji; text = (Protect-AlertText $Message $State) }
    if ($Channel) { $payload['channel'] = $Channel }
    return Invoke-WebhookPost -Url $WebhookUrl -Payload $payload -Label 'SLACK' -State $State
}

function Send-TeamsNotification {
    param([string]$WebhookUrl, [string]$Title, [string]$Message, [string]$Color = '0072C6', [PSCustomObject]$State)
    $payload = [ordered]@{ '@type' = 'MessageCard'; '@context' = 'http://schema.org/extensions'; title = (Protect-AlertText $Title $State); text = (Protect-AlertText $Message $State); themeColor = $Color }
    return Invoke-WebhookPost -Url $WebhookUrl -Payload $payload -Label 'TEAMS' -State $State
}

function Send-DiscordNotification {
    param([string]$WebhookUrl, [string]$Message, [string]$Username = 'gbuild', [string]$AvatarUrl, [PSCustomObject]$State)
    $payload = [ordered]@{ username = $Username; content = (Protect-AlertText $Message $State) }
    if ($AvatarUrl) { $payload['avatar_url'] = $AvatarUrl }
    return Invoke-WebhookPost -Url $WebhookUrl -Payload $payload -Label 'DISCORD' -State $State
}

function Send-Alert {
    [CmdletBinding()]
    [OutputType([bool])]
      param(
          # The message and the severity are both optional on purpose: the
          # other tool calls this command with -Status and -Severity, and the
          # two tools export the same command name into one namespace. A call
          # written for either tool must bind against either implementation.
          [Alias('Status')][string]$Message = '',
          [Alias('StatusName')][ValidateSet('Info', 'Warning', 'Error', 'Critical')][string]$Severity = 'Critical',
          [PSCustomObject]$State = $null,
          [hashtable]$Data = @{}
      )
      if ([string]::IsNullOrWhiteSpace($Message)) { $Message = [string](Get-AlertObjectValue $Data 'message' '') }
    $cfg = Get-ConfigSection -State $State -Path 'alerting'
    if (-not $cfg) { return $false }
    $source = Get-AlertObjectValue $Data 'source' ''
    $enabledValue = Get-AlertObjectValue $cfg 'enabled' $null
    if ($null -ne $enabledValue -and -not [bool]$enabledValue -and $source -ne 'anomaly-detector') { return $false }
    $minSeverity = [string](Get-AlertObjectValue $cfg 'minSeverity' 'Critical')
    if (Get-Command Get-SeverityRank -ErrorAction SilentlyContinue) {
        $sev = Get-SeverityRank -Severity $Severity
        $min = Get-SeverityRank -Severity $minSeverity
        if ($sev -ge 0 -and $min -ge 0 -and $sev -lt $min) { return $false }
    }
    $url = [string](Get-AlertObjectValue $cfg 'webhookUrl' '')
    if ($url -match '\$\{env:') { $url = Resolve-EnvPlaceholder -Text $url }
    if ([string]::IsNullOrWhiteSpace($url) -or $url -match '\$\{env:') {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.alert.noWebhook' -MessageArgs @([string]$Severity) -Fallback '[ALERT] No usable webhook configured for {0}') 'Warn' $State }
        return $false
    }
    $stateTenant = Get-AlertTenantId -State $State -Data $null
    $dataTenant = Get-AlertTenantId -State $null -Data $Data
    if ($stateTenant -ne 'default' -and $dataTenant -ne 'default' -and $stateTenant -ne $dataTenant) { return $false }
    $tenant = if ($stateTenant -ne 'default') { $stateTenant } else { $dataTenant }
    $correlation = Get-AlertCorrelationId -State $State -Data $Data
    $safeMessage = Protect-AlertText -Text $Message -State $State
    $safeData = ConvertTo-AlertSafeValue -Value $Data -State $State
    $provider = [string](Get-AlertObjectValue $cfg 'provider' '')
    if (-not $provider) {
        if ($url -match 'hooks\.slack\.com') { $provider = 'slack' }
        elseif ($url -match 'discord(?:app)?\.com/api/webhooks') { $provider = 'discord' }
        elseif ($url -match 'webhook\.office\.com|outlook\.office\.com|teams\.') { $provider = 'teams' }
    }
    if ($provider -in @('slack', 'teams', 'discord')) {
        if ($provider -eq 'slack') { return Send-SlackNotification -WebhookUrl $url -Message ("[$Severity] $safeMessage") -Channel ([string](Get-AlertObjectValue $safeData 'channel' '')) -Username ([string](Get-AlertObjectValue $safeData 'username' 'gbuild')) -State $State }
        if ($provider -eq 'teams') { return Send-TeamsNotification -WebhookUrl $url -Title ([string](Get-AlertObjectValue $safeData 'title' "gbuild $Severity")) -Message $safeMessage -State $State }
        return Send-DiscordNotification -WebhookUrl $url -Message "**$Severity**: $safeMessage" -Username ([string](Get-AlertObjectValue $safeData 'username' 'gbuild')) -AvatarUrl ([string](Get-AlertObjectValue $safeData 'avatar_url' '')) -State $State
    }
    $payload = [ordered]@{ severity = $Severity; message = $safeMessage; tenantId = $tenant; correlationId = $correlation; data = $safeData; timestamp = (Get-Date).ToString('o') }
    $headers = @{}
    $configuredHeaders = Get-AlertObjectValue $cfg 'headers' $null
    if ($configuredHeaders) {
        if ($configuredHeaders -is [System.Collections.IDictionary]) { foreach ($key in $configuredHeaders.Keys) { $headers[[string]$key] = [string]$configuredHeaders[$key] } }
        elseif ($configuredHeaders.PSObject) { foreach ($property in $configuredHeaders.PSObject.Properties) { $headers[$property.Name] = [string]$property.Value } }
    }
    if ([bool](Get-AlertObjectValue $cfg 'rotateTokens' $false)) {
        $interval = [double](Get-AlertObjectValue $cfg 'rotationIntervalHours' (Get-AlertRotationHours))
        $token = Update-WebhookToken -State $State -IntervalHours $interval
        if ($token) { $headers['X-Gbuild-Token'] = $token }
    }
    return Invoke-WebhookPost -Url $url -Payload $payload -Label 'ALERT' -Headers $headers -State $State -TimeoutSec ([int](Get-AlertObjectValue $cfg 'timeoutSec' 0)) -MaxAttempts ([int](Get-AlertObjectValue $cfg 'retryAttempts' 0)) -RetryDelayMs ([int](Get-AlertObjectValue $cfg 'retryDelayMs' 0)) -Config $cfg
}

Export-ModuleMember -Function @('Send-Alert', 'New-WebhookToken', 'Test-WebhookTokenExpired', 'Update-WebhookToken', 'Invoke-WebhookPost', 'Protect-AlertText', 'Get-AlertRedactedUrl', 'Get-AlertIdempotencyKey')
