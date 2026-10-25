
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-ElapsedSeconds'
Import-GBuildModuleIfMissing -Name 'SharedUtils' -SentinelCommand 'Get-ConfigSection'
Import-GBuildModuleIfMissing -Name 'PathUtils' -SentinelCommand 'Resolve-BuildRootedPath'
Import-GBuildModuleIfMissing -Name 'Alerting' -SentinelCommand 'Invoke-WebhookPost'
Import-GBuildModuleIfMissing -Name 'Metrics' -SentinelCommand 'Send-OtelMetrics'
Import-GBuildModuleIfMissing -Name 'ConfigProvider' -SentinelCommand 'Get-SectionValue'

function Get-InfraTimeout {
    param([int]$Value, [int]$Fallback)

Set-StrictMode -Version 1.0
    if ($Value -gt 0) { return $Value }
    return [Math]::Max(1, $Fallback)
}

function Protect-InfraText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Text, [PSCustomObject]$State = $null)
    if ($null -eq $Text) { return '' }
    # Canonical routine, same shape as Security/Sast. The local assignment regex
    # this replaces was a fourth copy of the same rule. Its extra alternatives
    # (sas, signature, auth, jwt, session) are NOT carried over verbatim: the
    # canonical pattern set is a superset of every one of them, so keeping a local
    # copy only created a fifth thing to drift. This module's own URL redactor is
    # passed through so host-stripping behaviour is unchanged.
    $urlRedactor = { param($candidate) Get-InfraRedactedUrl -Url $candidate }
    return (Invoke-BuildSecretProtect -Text ([string]$Text) -State $State -RedactUrls -UrlRedactor $urlRedactor)
}

function Get-InfraRedactedUrl {
    param([AllowNull()][string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    if ($Url -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { return Protect-InfraText -Text $Url }
    if (Get-Command Get-AlertRedactedUrl -ErrorAction SilentlyContinue) {
        try { return [string](Get-AlertRedactedUrl -Url $Url) } catch { }
    }
    try {
        $uri = [System.Uri]::new($Url)
        return '{0}://{1}/[redacted]' -f $uri.Scheme, $uri.Host
    } catch { return '[redacted-url]' }
}

function ConvertTo-InfraArgument {
    param([string]$Value)
    return (ConvertTo-BuildArgument -Value $Value)
}

function Invoke-InfraProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 5,
        [string]$WorkingDirectory = ''
    )
    $effectiveTimeout = Get-InfraTimeout -Value $TimeoutSec -Fallback 5
    $file = $FilePath
    $args = @($ArgumentList)
    $ext = [System.IO.Path]::GetExtension($file)
    if ($ext -in @('.cmd', '.bat')) {
        # Only Windows can execute a .cmd/.bat. $env:ComSpec is empty on
        # Linux/macOS, so the old `else { 'cmd.exe' }` fallback launched a
        # non-existent binary instead of failing. Fail closed, as SDK.psm1 does.
        if ([string]::IsNullOrWhiteSpace($env:ComSpec)) { return '' }
        $file = $env:ComSpec
        $args = @('/d', '/c', $FilePath) + $args
    }
    $psi = New-BuildProcessStartInfo -FilePath $file -Arguments (($args | ForEach-Object { ConvertTo-InfraArgument ([string]$_) }) -join ' ') -WorkingDirectory $WorkingDirectory
    if ($null -eq $psi) { return '' }
    $process = $null
    try {
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        [void]$process.Start()
        $completed = $process.WaitForExit($effectiveTimeout * 1000)
        if (-not $completed) {
            # Teardown is owned by SharedUtils.Stop-BuildProcess. The local
            # fallback preserves the previous kill-and-wait shape only when that
            # owner cannot be resolved.
            if (Get-Command Stop-BuildProcess -ErrorAction SilentlyContinue) {
                Stop-BuildProcess -Process $process -WaitMs 1000
            } else {
                try { $process.Kill() } catch { }
                try { $process.WaitForExit(1000) } catch { }
            }
            return [PSCustomObject]@{ Success = $false; ExitCode = 124; Output = ''; Error = "process timed out after ${effectiveTimeout}s"; TimedOut = $true }
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $errorText = [string]$stderr
        if ([string]::IsNullOrWhiteSpace($errorText)) { $errorText = [string]$stdout }
        return [PSCustomObject]@{ Success = ($process.ExitCode -eq 0); ExitCode = $process.ExitCode; Output = [string]$stdout; Error = $errorText; TimedOut = $false }
    } catch {
        return [PSCustomObject]@{ Success = $false; ExitCode = -1; Output = ''; Error = $_.Exception.Message; TimedOut = $false }
    } finally {
        if ($process) { try { $process.Dispose() } catch { } }
    }
}

function Get-VerificationConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([PSCustomObject]$State)
    $v = Get-ConfigSection -State $State -Path 'verification'
    $connectDefault = [int](Get-BuildConstant -Key 'VerificationConnectTimeoutSec' -Fallback 10)
    $requestDefault = [int](Get-BuildConstant -Key 'VerificationRequestTimeoutSec' -Fallback 5)
    $connectValue = [int](Get-SectionValue -Section $v -Key 'connectTimeout' -Default 0)
    $requestValue = [int](Get-SectionValue -Section $v -Key 'requestTimeout' -Default 0)
    return [PSCustomObject]@{
        Enabled = if ($v -and $null -ne (Get-SectionValue -Section $v -Key 'enabled' -Default $null)) { [bool](Get-SectionValue -Section $v -Key 'enabled' -Default $false) } else { $false }
        Ssh = if ($v -and $null -ne (Get-SectionValue -Section $v -Key 'ssh' -Default $null)) { [bool](Get-SectionValue -Section $v -Key 'ssh' -Default $true) } else { $true }
        RemoteCache = if ($v -and $null -ne (Get-SectionValue -Section $v -Key 'remoteCache' -Default $null)) { [bool](Get-SectionValue -Section $v -Key 'remoteCache' -Default $true) } else { $true }
        Otel = if ($v -and $null -ne (Get-SectionValue -Section $v -Key 'otel' -Default $null)) { [bool](Get-SectionValue -Section $v -Key 'otel' -Default $true) } else { $true }
        Webhook = if ($v -and $null -ne (Get-SectionValue -Section $v -Key 'webhook' -Default $null)) { [bool](Get-SectionValue -Section $v -Key 'webhook' -Default $true) } else { $true }
        WebhookSendTest = if ($v -and $null -ne (Get-SectionValue -Section $v -Key 'webhookSendTest' -Default $null)) { [bool](Get-SectionValue -Section $v -Key 'webhookSendTest' -Default $false) } else { $false }
        Sdk = if ($v -and $null -ne (Get-SectionValue -Section $v -Key 'sdk' -Default $null)) { [bool](Get-SectionValue -Section $v -Key 'sdk' -Default $true) } else { $true }
        Remediate = if ($v -and $null -ne (Get-SectionValue -Section $v -Key 'remediate' -Default $null)) { [bool](Get-SectionValue -Section $v -Key 'remediate' -Default $false) } elseif ($v -and $null -ne (Get-SectionValue -Section $v -Key 'autoRemediate' -Default $null)) { [bool](Get-SectionValue -Section $v -Key 'autoRemediate' -Default $false) } else { $false }
        OtelSendTest = if ($v -and $null -ne (Get-SectionValue -Section $v -Key 'otelSendTest' -Default $null)) { [bool](Get-SectionValue -Section $v -Key 'otelSendTest' -Default $false) } else { $false }
        ConnectTimeout = if ($connectValue -gt 0) { $connectValue } else { $connectDefault }
        RequestTimeout = if ($requestValue -gt 0) { $requestValue } else { $requestDefault }
        OutputDir = if (-not [string]::IsNullOrWhiteSpace([string](Get-SectionValue -Section $v -Key 'outputDir' -Default ''))) { [string](Get-SectionValue -Section $v -Key 'outputDir' -Default '') } else { [string](Get-BuildConstant -Key 'ReportOutputDir' -Fallback 'build-reports') }
    }
}

function New-VerificationCheck {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'skipped')][string]$Status,
        [string]$Detail = '',
        [double]$DurationSec = 0,
        [string]$Target = '',
        [PSCustomObject]$State = $null
    )
    return [PSCustomObject]@{
        Name = $Name
        Status = $Status
        Detail = Protect-InfraText -Text $Detail -State $State
        DurationSec = [math]::Round($DurationSec, 3)
        Target = Get-InfraRedactedUrl -Url $Target
        CheckedAt = (Get-Date).ToString('o')
    }
}

function Invoke-VerifySdk {
    [CmdletBinding()]
    param([PSCustomObject]$State, [int]$RequestTimeout = 5)
    $start = Get-Date
    $dotnet = if ($State -and ($State.PSObject.Properties.Name -contains 'DotnetCmd')) { [string]$State.DotnetCmd } else { '' }
    if (-not $dotnet -and $State -and (Get-Command Get-SmartSdk -ErrorAction SilentlyContinue)) {
        try { $resolved = Get-SmartSdk -State $State -ToolType 'Dotnet'; if ($resolved) { $dotnet = [string]$resolved } } catch { }
    }
    if (-not $dotnet) { $dotnet = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'DotnetToolName' -Fallback 'dotnet') } else { 'dotnet' } }
    $timeout = Get-InfraTimeout -Value $RequestTimeout -Fallback 5
    $workingDir = ''
    if ($State -and ($State.PSObject.Properties.Name -contains 'WorkingDir')) { $workingDir = [string]$State.WorkingDir }
    $result = Invoke-InfraProcess -FilePath $dotnet -ArgumentList @('--list-sdks') -TimeoutSec $timeout -WorkingDirectory $workingDir
    $ok = $result.Success -and -not [string]::IsNullOrWhiteSpace($result.Output)
    $detail = if ($ok) { 'dotnet --list-sdks OK' } else { "dotnet --list-sdks failed (exit=$($result.ExitCode)): possible ghost/stub SDK" }
    return New-VerificationCheck -Name 'sdk.dotnet' -Status $(if ($ok) { 'passed' } else { 'failed' }) -Detail $detail -DurationSec (Get-ElapsedSeconds $start) -Target $dotnet -State $State
}

function Invoke-VerifySshHost {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$HostObj, [PSCustomObject]$State, [int]$ConnectTimeout = 10, [int]$RequestTimeout = 5)
    $label = "$(Get-SectionValue -Section $HostObj -Key 'user' -Default '' )@$(Get-SectionValue -Section $HostObj -Key 'hostname' -Default '')"
    $start = Get-Date
    if (Get-Command Invoke-RemoteCommand -ErrorAction SilentlyContinue) {
        try {
            $strict = if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { Get-ConfigValue -Path 'distributed.strictHostKeyChecking' -State $State -Default 'accept-new' } else { 'accept-new' }
            $result = Invoke-RemoteCommand -TargetHost $HostObj -Command 'echo ok' -RepoRoot '/' -ConnectTimeout (Get-InfraTimeout $ConnectTimeout 10) -State $State -StrictHostKeyChecking $strict
            if ($result -and $result.Success) { return New-VerificationCheck -Name 'distributed.ssh' -Status 'passed' -Detail 'ssh echo ok' -DurationSec (Get-ElapsedSeconds $start) -Target $label -State $State }
            # NOT $error: read-only automatic variable. Assigning it was a no-op on
            # PowerShell 6+, so this interpolated the LAST ERROR RECORD instead
            # of the ssh failure reason - right on PS 5.1, wrong on PS 7.
            $sshError = if ($result) { Get-SectionValue -Section $result -Key 'Error' -Default 'ssh failed' } else { 'ssh failed' }
            return New-VerificationCheck -Name 'distributed.ssh' -Status 'failed' -Detail "ssh failed: $sshError" -DurationSec (Get-ElapsedSeconds $start) -Target $label -State $State
        } catch { return New-VerificationCheck -Name 'distributed.ssh' -Status 'failed' -Detail "ssh error: $($_.Exception.Message)" -DurationSec (Get-ElapsedSeconds $start) -Target $label -State $State }
    }
    return New-VerificationCheck -Name 'distributed.ssh' -Status 'skipped' -Detail 'Distributed module not loaded' -Target $label -State $State
}

function Invoke-VerifyRemoteCache {
    [CmdletBinding()]
    param([PSCustomObject]$State, [int]$RequestTimeout = 5)
    $start = Get-Date
    if (-not (Get-Command Get-RemoteCacheConfig -ErrorAction SilentlyContinue)) { return New-VerificationCheck -Name 'cache.remote' -Status 'skipped' -Detail 'CacheProvider module not loaded' -State $State }
    try {
        $rc = Get-RemoteCacheConfig -State $State
        if (-not $rc -or -not [bool](Get-SectionValue -Section $rc -Key 'Enabled' -Default $false)) { return New-VerificationCheck -Name 'cache.remote' -Status 'skipped' -Detail 'cacheRemote.enabled=false' -State $State }
        $type = [string](Get-SectionValue -Section $rc -Key 'Type' -Default '')
        $endpoint = [string](Get-SectionValue -Section $rc -Key 'Endpoint' -Default '')
        $container = [string](Get-SectionValue -Section $rc -Key 'Container' -Default '')
        $region = [string](Get-SectionValue -Section $rc -Key 'Region' -Default '')
        if ($type -eq 'azureBlob' -and (-not $endpoint -or -not $container)) { return New-VerificationCheck -Name 'cache.remote' -Status 'failed' -Detail 'Azure Blob missing endpoint/container configuration' -DurationSec (Get-ElapsedSeconds $start) -State $State }
        if ($type -eq 'awsS3' -and (-not $region -or -not $container)) { return New-VerificationCheck -Name 'cache.remote' -Status 'failed' -Detail 'AWS S3 missing region/bucket configuration' -DurationSec (Get-ElapsedSeconds $start) -State $State }
        if ($type -notin @('azureBlob', 'awsS3')) { return New-VerificationCheck -Name 'cache.remote' -Status 'skipped' -Detail "Unsupported remote cache type: $type" -DurationSec (Get-ElapsedSeconds $start) -State $State }
        $canary = 'gbuild-infra-verification/probe'
        $target = if ($type -eq 'azureBlob') { $endpoint } else { $region }
        $providerError = ''
        if (Get-Command Test-CacheEntryExists -ErrorAction SilentlyContinue) {
            try { if ([bool](Test-CacheEntryExists -State $State -Key $canary)) { return New-VerificationCheck -Name 'cache.remote' -Status 'passed' -Detail "Canary entry found via provider HEAD probe ($type)" -DurationSec (Get-ElapsedSeconds $start) -Target $target -State $State } } catch { $providerError = $_.Exception.Message }
        }
        $status = -1
        $timeout = Get-InfraTimeout -Value $RequestTimeout -Fallback 5
        if ($type -eq 'azureBlob') {
            $url = "$($endpoint.TrimEnd('/'))/$container/$canary"
            $sas = [string](Get-SectionValue -Section $rc -Key 'AuthToken' -Default '')
            if ($sas) { $url += $(if ($sas.StartsWith('?')) { $sas } else { '?' + $sas }) }
            try { $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec $timeout -UseBasicParsing -ErrorAction Stop; $status = [int]$response.StatusCode } catch { if ($_.Exception.Response) { try { $status = [int]$_.Exception.Response.StatusCode } catch { } } }
        } else {
            if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { return New-VerificationCheck -Name 'cache.remote' -Status 'skipped' -Detail 'aws CLI not installed - cannot classify S3 probe' -DurationSec (Get-ElapsedSeconds $start) -Target $target -State $State }
            $result = Invoke-InfraProcess -FilePath 'aws' -ArgumentList @('s3api', 'head-object', '--bucket', $container, '--key', $canary, '--region', $region) -TimeoutSec $timeout
            if ($result.Success) { $status = 200 }
            elseif ($result.Error -match '404|Not Found') { $status = 404 }
            elseif ($result.Error -match '403|AccessDenied|InvalidAccessKeyId|SignatureDoesNotMatch') { $status = 403 }
        }
        if ($status -eq 200 -or $status -eq 404) { return New-VerificationCheck -Name 'cache.remote' -Status 'passed' -Detail "HEAD probe returned $status (endpoint reachable; canary is read-only)" -DurationSec (Get-ElapsedSeconds $start) -Target $target -State $State }
        if ($status -eq 403) { return New-VerificationCheck -Name 'cache.remote' -Status 'failed' -Detail 'HEAD probe rejected with 403 (credentials/token invalid)' -DurationSec (Get-ElapsedSeconds $start) -Target $target -State $State }
        $why = if ($providerError) { "; provider probe: $providerError" } else { '' }
        return New-VerificationCheck -Name 'cache.remote' -Status 'failed' -Detail "configured-but-unreachable (probe status: $status)$why" -DurationSec (Get-ElapsedSeconds $start) -Target $target -State $State
    } catch { return New-VerificationCheck -Name 'cache.remote' -Status 'failed' -Detail "probe error: $($_.Exception.Message)" -DurationSec (Get-ElapsedSeconds $start) -State $State }
}

function Invoke-VerifyOtel {
    [CmdletBinding()]
    param([PSCustomObject]$State, [int]$RequestTimeout = 5, [bool]$SendTest = $false)
    $start = Get-Date
    $otel = Get-ConfigSection -State $State -Path 'telemetry.otel'
    $endpoint = [string](Get-SectionValue -Section $otel -Key 'endpoint' -Default '')
    if ($otel -and -not [bool](Get-SectionValue -Section $otel -Key 'enabled' -Default $false)) { return New-VerificationCheck -Name 'telemetry.otel' -Status 'skipped' -Detail 'telemetry.otel.enabled=false' -State $State }
    if ($endpoint -match '\$\{env:') { $endpoint = Resolve-EnvPlaceholder -Text $endpoint }
    if ([string]::IsNullOrWhiteSpace($endpoint) -or $endpoint -match '\$\{env:') { return New-VerificationCheck -Name 'telemetry.otel' -Status 'skipped' -Detail 'No telemetry.otel.endpoint configured' -State $State }
    $path = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'OtlpMetricsPath' -Fallback '/v1/metrics') } else { '/v1/metrics' }
    $target = '{0}{1}' -f $endpoint.TrimEnd('/'), $path
    if ($SendTest) {
        if (-not (Get-Command Send-OtelMetrics -ErrorAction SilentlyContinue)) { return New-VerificationCheck -Name 'telemetry.otel' -Status 'failed' -Detail 'OTLP sender is not loaded' -DurationSec (Get-ElapsedSeconds $start) -Target $target -State $State }
        try {
            $ok = [bool](Send-OtelMetrics -State $State -OtelEndpoint $endpoint -TimeoutSec (Get-InfraTimeout $RequestTimeout 5))
            return New-VerificationCheck -Name 'telemetry.otel' -Status $(if ($ok) { 'passed' } else { 'failed' }) -Detail $(if ($ok) { 'OTLP test send accepted' } else { 'OTLP test send rejected/failed' }) -DurationSec (Get-ElapsedSeconds $start) -Target $target -State $State
        } catch { return New-VerificationCheck -Name 'telemetry.otel' -Status 'failed' -Detail "OTLP test error: $($_.Exception.Message)" -DurationSec (Get-ElapsedSeconds $start) -Target $target -State $State }
    }
    try {
        $response = Invoke-WebRequest -Uri $target -Method Head -TimeoutSec (Get-InfraTimeout $RequestTimeout 5) -UseBasicParsing -ErrorAction Stop
        $status = [int]$response.StatusCode
        return New-VerificationCheck -Name 'telemetry.otel' -Status 'passed' -Detail "OTLP endpoint reachable (HTTP $status)" -DurationSec (Get-ElapsedSeconds $start) -Target $target -State $State
    } catch {
        $status = 0
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
        if ($status -gt 0 -and $status -lt 500) { return New-VerificationCheck -Name 'telemetry.otel' -Status 'passed' -Detail "OTLP endpoint reachable (HTTP $status)" -DurationSec (Get-ElapsedSeconds $start) -Target $target -State $State }
        return New-VerificationCheck -Name 'telemetry.otel' -Status 'failed' -Detail "OTLP endpoint probe error: $($_.Exception.Message)" -DurationSec (Get-ElapsedSeconds $start) -Target $target -State $State
    }
}

function Invoke-VerifyWebhook {
    [CmdletBinding()]
    param([PSCustomObject]$State, [bool]$SendTest = $false, [int]$RequestTimeout = 5)
    $start = Get-Date
    $alerting = Get-ConfigSection -State $State -Path 'alerting'
    $url = [string](Get-SectionValue -Section $alerting -Key 'webhookUrl' -Default '')
    if ($url -match '\$\{env:') { $url = Resolve-EnvPlaceholder -Text $url }
    if ([string]::IsNullOrWhiteSpace($url) -or $url -match '\$\{env:') { return New-VerificationCheck -Name 'alerting.webhook' -Status 'skipped' -Detail 'No alerting.webhookUrl configured' -State $State }
    if (-not $SendTest) { return New-VerificationCheck -Name 'alerting.webhook' -Status 'passed' -Detail 'Webhook URL configured; no test sent' -DurationSec (Get-ElapsedSeconds $start) -Target $url -State $State }
    try {
        $ok = [bool](Invoke-WebhookPost -Url $url -Payload @{ text = 'gbuild infra verification probe'; markdown = $true } -Label 'VERIFY-WEBHOOK' -State $State -TimeoutSec (Get-InfraTimeout $RequestTimeout 5) -MaxAttempts 1 -RetryDelayMs 0)
        return New-VerificationCheck -Name 'alerting.webhook' -Status $(if ($ok) { 'passed' } else { 'failed' }) -Detail $(if ($ok) { 'Test alert sent successfully' } else { 'Test alert rejected/failed' }) -DurationSec (Get-ElapsedSeconds $start) -Target $url -State $State
    } catch { return New-VerificationCheck -Name 'alerting.webhook' -Status 'failed' -Detail "Webhook probe error: $($_.Exception.Message)" -DurationSec (Get-ElapsedSeconds $start) -Target $url -State $State }
}

function Invoke-InfraRemediate {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [AllowEmptyCollection()][object[]]$Checks,
        [Parameter(Mandatory)][PSCustomObject]$Config
    )
    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($check in @($Checks | Where-Object { $_.Status -eq 'failed' })) {
        $entry = [ordered]@{ Name = [string]$check.Name; Attempted = $true; Remediated = $false; Detail = '' }
        try {
            switch ([string]$check.Name) {
                'telemetry.otel' {
                    $service = if (Get-Command Get-Service -ErrorAction SilentlyContinue) { Get-Service -Name 'otel-collector' -ErrorAction SilentlyContinue } else { $null }
                    if ($service -and (Get-Command Restart-Service -ErrorAction SilentlyContinue)) {
                        Restart-Service -Name 'otel-collector' -Force -ErrorAction Stop
                        $entry.Remediation = $true
                        $entry.Detail = 'restarted otel-collector service'
                    } else { $entry.Detail = 'collector service is not available' }
                }
                'distributed.ssh' {
                    $hostObj = $null
                    $hosts = @()
                    if (Get-Command Get-DistributedConfig -ErrorAction SilentlyContinue) { $hosts = @((Get-DistributedConfig -State $State).hosts) }
                    foreach ($candidate in $hosts) {
                        $candidateLabel = "$(Get-SectionValue -Section $candidate -Key 'user' -Default '' )@$(Get-SectionValue -Section $candidate -Key 'hostname' -Default '')"
                        if ($candidateLabel -eq [string]$check.Target -or (Get-SectionValue -Section $candidate -Key 'hostname' -Default '') -eq [string]$check.Target) { $hostObj = $candidate; break }
                    }
                    if ($hostObj -and (Get-Command Invoke-RemoteCommand -ErrorAction SilentlyContinue)) {
                        $retry = Invoke-VerifySshHost -HostObj $hostObj -State $State -ConnectTimeout ([int]$Config.ConnectTimeout)
                        if ($retry.Status -eq 'passed') { $entry.Remediation = $true; $entry.Detail = 'SSH host is reachable' }
                        else { $entry.Detail = 'SSH host remains unreachable' }
                    } else { $entry.Detail = 'matching distributed host was not found' }
                }
                'cache.remote' {
                    if (Get-Command Clear-BuildCache -ErrorAction SilentlyContinue) { Clear-BuildCache -State $State -Confirm:$false; $entry.Detail = 'cleared build cache' }
                    if (Get-Command Sync-CacheRemote -ErrorAction SilentlyContinue) { Sync-CacheRemote -State $State; $entry.Remediation = $true; $entry.Detail = 'synchronized remote cache' }
                    if (-not $entry.Detail) { $entry.Detail = 'cache provider is not loaded' }
                }
                'sdk.dotnet' {
                    if (Get-Command Get-SmartSdk -ErrorAction SilentlyContinue) {
                        $resolved = Get-SmartSdk -State $State -ToolType 'Dotnet'
                        if ($resolved -and (Test-Path -LiteralPath ([string]$resolved) -PathType Leaf)) {
                            $State | Add-Member -MemberType NoteProperty -Name 'DotnetCmd' -Value ([string]$resolved) -Force
                            $entry.Remediation = $true; $entry.Detail = 're-resolved dotnet SDK'
                        } else { $entry.Detail = 'no usable dotnet SDK was found' }
                    } else { $entry.Detail = 'SDK resolver is not loaded' }
                }
                default { $entry.Detail = 'no guarded remediation is available' }
            }
        } catch { $entry.Detail = Protect-InfraText -Text $_.Exception.Message -State $State }
        $actions.Add([PSCustomObject]$entry)
    }
    return [PSCustomObject]@{ Attempted = $true; Actions = @($actions); RemediatedCount = @($actions | Where-Object { $_.Remediated }).Count }
}

function Invoke-InfraVerification {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [switch]$Force,
        [switch]$Remediate,
        [switch]$AutoRemediate
    )
    $cfg = Get-VerificationConfig -State $State
    if (-not $cfg.Enabled -and -not $Force) { return $null }
    if ($cfg.ConnectTimeout -le 0) { $cfg.ConnectTimeout = [int](Get-BuildConstant -Key 'VerificationConnectTimeoutSec' -Fallback 10) }
    if ($cfg.RequestTimeout -le 0) { $cfg.RequestTimeout = [int](Get-BuildConstant -Key 'VerificationRequestTimeoutSec' -Fallback 5) }
    if ([string]::IsNullOrWhiteSpace($cfg.OutputDir)) { $cfg.OutputDir = [string](Get-BuildConstant -Key 'ReportOutputDir' -Fallback 'build-reports') }
    $checks = [System.Collections.Generic.List[object]]::new()
    $startAll = Get-Date
    $doRemediate = [bool]($Remediate -or $AutoRemediate -or $cfg.Remediate)
    if ($cfg.Sdk) { $checks.Add((Invoke-VerifySdk -State $State -RequestTimeout $cfg.RequestTimeout)) }
    if ($cfg.Ssh) {
        $hosts = @()
        if (Get-Command Get-DistributedConfig -ErrorAction SilentlyContinue) { $hosts = @((Get-DistributedConfig -State $State).hosts) }
        # NOT $host: read-only automatic variable. `foreach ($host in $hosts)` was an
        # Error-severity defect on PowerShell 6+ - the loop variable could never
        # be assigned, so every configured distributed host went unverified.
        if ($hosts.Count -gt 0) { foreach ($hostEntry in $hosts) { $checks.Add((Invoke-VerifySshHost -HostObj $hostEntry -State $State -ConnectTimeout $cfg.ConnectTimeout -RequestTimeout $cfg.RequestTimeout)) } }
        else { $checks.Add((New-VerificationCheck -Name 'distributed.ssh' -Status 'skipped' -Detail 'No distributed.hosts configured' -State $State)) }
    }
    if ($cfg.RemoteCache) { $checks.Add((Invoke-VerifyRemoteCache -State $State -RequestTimeout $cfg.RequestTimeout)) }
    if ($cfg.Otel) { $checks.Add((Invoke-VerifyOtel -State $State -RequestTimeout $cfg.RequestTimeout -SendTest $cfg.OtelSendTest)) }
    if ($cfg.Webhook) { $checks.Add((Invoke-VerifyWebhook -State $State -SendTest $cfg.WebhookSendTest -RequestTimeout $cfg.RequestTimeout)) }
    $allChecks = @($checks)
    $remediation = $null
    if ($doRemediate) { $remediation = Invoke-InfraRemediate -State $State -Checks $allChecks -Config $cfg }
    $passed = @($allChecks | Where-Object { $_.Status -eq 'passed' }).Count
    $failed = @($allChecks | Where-Object { $_.Status -eq 'failed' }).Count
    $skipped = @($allChecks | Where-Object { $_.Status -eq 'skipped' }).Count
    $externalSendAttempted = $cfg.WebhookSendTest -or $cfg.OtelSendTest
    $overall = if ($failed -gt 0) { 'degraded' } elseif ($passed -eq 0) { 'skipped' } else { 'ok' }
    $summary = [PSCustomObject]@{
        Tool = 'gbuild'
        GeneratedAt = (Get-Date).ToString('o')
        Total = $allChecks.Count
        Passed = $passed
        Failed = $failed
        Skipped = $skipped
        Overall = $overall
        ReadOnly = (-not $doRemediate -and -not $externalSendAttempted)
        ExternalSendAttempted = $externalSendAttempted
        Mode = if ($doRemediate) { 'Remediate' } else { 'Verify' }
        MutationRequested = $doRemediate
        RemediationAttempted = $doRemediate
        Remediation = $remediation
        DurationSec = Get-ElapsedSeconds $startAll -Decimals 2
        Checks = $allChecks
    }
    if (Get-Command Resolve-BuildRootedPath -ErrorAction SilentlyContinue) { $absDir = Resolve-BuildRootedPath -RelativePath $cfg.OutputDir -State $State }
    else {
        $root = if (($State.PSObject.Properties.Name -contains 'ProjectRoot') -and $State.ProjectRoot) { [string]$State.ProjectRoot } elseif (($State.PSObject.Properties.Name -contains 'ScriptRoot') -and $State.ScriptRoot) { [string]$State.ScriptRoot } else { (Get-Location).ProviderPath }
        $absDir = if ([System.IO.Path]::IsPathRooted($cfg.OutputDir)) { $cfg.OutputDir } else { Join-Path $root $cfg.OutputDir }
    }
    $jsonPath = Join-Path $absDir 'infra-verification.json'
    if (Write-BuildJsonFile -Path $jsonPath -Data $summary) { $summary | Add-Member -MemberType NoteProperty -Name ReportPath -Value $jsonPath -Force }
    return $summary
}

<#
.SYNOPSIS
    The single infra-verification entry point.
.DESCRIPTION
    Invoke-InfraVerify and Invoke-InfraAutoRemediate were REMOVED. Both were
    pure one-line pass-throughs to Invoke-InfraVerification / Invoke-InfraRemediate
    respectively, exported, and had zero production callers (only the module's
    own test file touched them). They doubled the public surface and the set of
    names a caller had to choose between, with no behavioural difference.
    Keep the -Remediate / -AutoRemediate switches on Invoke-InfraVerification
    instead, which cover both cases.
#>
Export-ModuleMember -Function @('Get-VerificationConfig', 'Invoke-InfraVerification', 'Invoke-InfraRemediate')
