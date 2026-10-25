
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
Import-BuildModule -Dependencies @('BuildConstants', 'SharedUtils', 'PathUtils', 'Alerting')
Import-GBuildModuleIfMissing -Name 'Locale' -SentinelCommand 'Get-LocaleMessage'
Import-GBuildModuleIfMissing -Name 'ConfigProvider' -SentinelCommand 'Get-SectionValue'

function Get-SiemConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    $security = Get-ConfigSection -State $State -Path 'security'
    $siem = Get-SectionValue -Section $security -Key 'siem' -Default $null
    if ($null -eq $siem) { return $null }
    return $siem
}

function Get-SiemReportDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    if (Get-Command Get-ReportDirectory -ErrorAction SilentlyContinue) { return [string](Get-ReportDirectory -State $State) }
    # Directory NAME single-sourced (see Metrics.Get-MetricReportDirectory): a
    # deployment overriding report.outputDir must not get a second writer.
    $leaf = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'ReportOutputDir' -State $State -Fallback 'build-reports') } else { 'build-reports' }
    $root = if ($State -and ($State.PSObject.Properties.Name -contains 'ProjectRoot') -and $State.ProjectRoot) { [string]$State.ProjectRoot } elseif ($State -and ($State.PSObject.Properties.Name -contains 'WorkingDir') -and $State.WorkingDir) { [string]$State.WorkingDir } else { (Get-Location).ProviderPath }
    return Join-Path $root $leaf
}

function Get-SiemHash {
    param([hashtable]$Entry)
    $copy = [ordered]@{}
    foreach ($key in @($Entry.Keys | Sort-Object { [string]$_ })) {
        if ([string]$key -in @('Sequence', 'EventId')) { continue }
        $copy[[string]$key] = $Entry[$key]
    }
    $canonical = $copy | ConvertTo-Json -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonHealthDepth' -Fallback 8) } else { 8 }) -Compress
    [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildStringHash')
    $hashed = Get-BuildStringHash -Text $canonical -OnFailure ''
    if ($hashed) { return $hashed }
    return [guid]::NewGuid().ToString('N')
}

function Format-SiemHeader {
    param([AllowNull()][object]$Value)
    return ([string]$Value).Replace('\', '\\').Replace('|', '\|').Replace("`r", '\r').Replace("`n", '\n')
}

function Format-SiemExtension {
    param([AllowNull()][object]$Value)
    return ([string]$Value).Replace('\', '\\').Replace('=', '\=').Replace("`r", '\r').Replace("`n", '\n')
}

function Format-SiemStructuredValue {
    param([AllowNull()][object]$Value)
    return ([string]$Value).Replace('\', '\\').Replace('"', '\"').Replace(']', '\]').Replace("`r", '\r').Replace("`n", '\n')
}

function ConvertTo-CefEvent {
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable]$Entry, [string]$Vendor = 'gbuild', [string]$Product = 'gbuild-build-system', [int]$Sequence = 0, [string]$EventId = '')
    $action = [string](Get-SectionValue -Section $Entry -Key 'Action' -Default '')
    $outcome = [string](Get-SectionValue -Section $Entry -Key 'Outcome' -Default '')
    $rank = if (Get-Command Get-SeverityRank -ErrorAction SilentlyContinue) { Get-SeverityRank -Severity $outcome -Fallback -1 } else { -1 }
    $severity = switch ($rank) { 0 { 0 } 1 { 5 } 2 { 7 } default { 3 } }
    $timestamp = Get-SectionValue -Section $Entry -Key 'Timestamp' -Default $null
    if ($timestamp) { try { $timestamp = ([datetime]$timestamp).ToString('yyyy-MM-dd HH:mm:ss.fff') } catch { $timestamp = '' } }
    $extensions = [System.Collections.Generic.List[string]]::new()
    if ($timestamp) { $extensions.Add("rt=$(Format-SiemExtension $timestamp)") | Out-Null }
    $user = [string](Get-SectionValue -Section $Entry -Key 'User' -Default ''); if ($user) { $extensions.Add("suser=$(Format-SiemExtension $user)") | Out-Null }
    $hostName = [string](Get-SectionValue -Section $Entry -Key 'Host' -Default ''); if ($hostName) { $extensions.Add("shost=$(Format-SiemExtension $hostName)") | Out-Null }
    $tenant = [string](Get-SectionValue -Section $Entry -Key 'TenantId' -Default ''); if ($tenant) { $extensions.Add("cs1=$(Format-SiemExtension $tenant)") | Out-Null; $extensions.Add('cs1Label=tenant') | Out-Null }
    $correlation = [string](Get-SectionValue -Section $Entry -Key 'CorrelationId' -Default ''); if ($correlation) { $extensions.Add("cs2=$(Format-SiemExtension $correlation)") | Out-Null; $extensions.Add('cs2Label=correlationId') | Out-Null }
    $extensions.Add("cs3=$(Format-SiemExtension $outcome)") | Out-Null; $extensions.Add('cs3Label=outcome') | Out-Null
    $detail = [string](Get-SectionValue -Section $Entry -Key 'Detail' -Default ''); if ($detail) { $extensions.Add("cs4=$(Format-SiemExtension $detail)") | Out-Null; $extensions.Add('cs4Label=detail') | Out-Null }
    if ($Sequence -gt 0) { $extensions.Add("cs5=$Sequence") | Out-Null; $extensions.Add('cs5Label=sequence') | Out-Null }
    if ($EventId) { $extensions.Add("cs6=$(Format-SiemExtension $EventId)") | Out-Null; $extensions.Add('cs6Label=eventId') | Out-Null }
    $header = "CEF:0|$(Format-SiemHeader $Vendor)|$(Format-SiemHeader $Product)|1.0|$(Format-SiemHeader $action)|$(Format-SiemHeader $action)|$severity"
    return $header + '|' + ($extensions -join ' ')
}

function ConvertTo-SyslogEvent {
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable]$Entry, [string]$HostName = '', [int]$Sequence = 0, [string]$EventId = '')
    $rank = if (Get-Command Get-SeverityRank -ErrorAction SilentlyContinue) { Get-SeverityRank -Severity ([string](Get-SectionValue -Section $Entry -Key 'Outcome' -Default '')) -Fallback -1 } else { -1 }
    $severity = switch ($rank) { 0 { 6 } 1 { 4 } 2 { 3 } default { 5 } }
    $pri = 8 + $severity
    $timestamp = Get-SectionValue -Section $Entry -Key 'Timestamp' -Default $null
    if ($timestamp) { try { $dt = [datetime]$timestamp; if ($dt.Kind -eq [System.DateTimeKind]::Local) { $dt = $dt.ToUniversalTime() }; $timestamp = $dt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } catch { $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } } else { $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    if (-not $HostName) { $HostName = if (Get-Command Get-BuildIdentity -ErrorAction SilentlyContinue) { [string](Get-BuildIdentity).Host } else { if ($env:COMPUTERNAME) { $env:COMPUTERNAME } elseif ($env:HOSTNAME) { $env:HOSTNAME } else { '-' } } }
    $HostName = ($HostName -replace '[\s\[\]\\]+', '-')
    $enterprise = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'SiemEnterpriseId' -Fallback 32473 } else { 32473 }
    $action = Format-SiemStructuredValue ([string](Get-SectionValue -Section $Entry -Key 'Action' -Default ''))
    $outcome = Format-SiemStructuredValue ([string](Get-SectionValue -Section $Entry -Key 'Outcome' -Default ''))
    $sd = " [gbuild@$enterprise action=`"$action`" outcome=`"$outcome`""
    $correlation = [string](Get-SectionValue -Section $Entry -Key 'CorrelationId' -Default ''); if ($correlation) { $sd += " correlationId=`"$(Format-SiemStructuredValue $correlation)`"" }
    $tenant = [string](Get-SectionValue -Section $Entry -Key 'TenantId' -Default ''); if ($tenant) { $sd += " tenant=`"$(Format-SiemStructuredValue $tenant)`"" }
    if ($Sequence -gt 0) { $sd += " sequence=`"$Sequence`"" }
    if ($EventId) { $sd += " eventId=`"$(Format-SiemStructuredValue $EventId)`"" }
    $sd += ']'
    $msg = "$action - $(Format-SiemStructuredValue ([string](Get-SectionValue -Section $Entry -Key 'Detail' -Default '')))"; if ($msg -eq "$action - ") { $msg = $action }; if (-not $msg) { $msg = '-' }
    $msgid = ([string]$correlation) -replace '[\s\[\]\\]+', '_'
    return "<$pri>1 $timestamp $HostName gbuild 1 $msgid$sd $msg"
}

function Get-AuditEntries {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$AuditLogPath)
    $entries = [System.Collections.Generic.List[object]]::new()
    if (-not $AuditLogPath -or -not (Test-Path -LiteralPath $AuditLogPath -PathType Leaf)) { return @($entries) }
    foreach ($line in @(Get-Content -LiteralPath $AuditLogPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop; $entry = @{}; foreach ($property in $obj.PSObject.Properties) { $entry[$property.Name] = $property.Value }; $entries.Add($entry) | Out-Null } catch { }
    }
    return @($entries)
}

function Write-SiemFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$OutputPath, [string[]]$Lines)
    if (-not $OutputPath -or @($Lines).Count -eq 0) { return $false }
    try {
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $stream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try { foreach ($line in $Lines) { $bytes = $utf8.GetBytes([string]$line + "`r`n"); $stream.Write($bytes, 0, $bytes.Length) }; $stream.Flush() } finally { $stream.Dispose() }
        return $true
    } catch { return $false }
}

function Send-SiemUdp {
    [CmdletBinding()]
    param([string]$Endpoint, [int]$Port, [string[]]$Lines)
    if (-not $Endpoint -or @($Lines).Count -eq 0) { return [PSCustomObject]@{ Status = 'Failed'; Sent = 0; Skipped = 0; Failed = @($Lines).Count } }
    $udp = $null; $sent = 0; $skipped = 0; $failed = 0; $maxBytes = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'SiemUdpMaxBytes' -Fallback 60000) } else { 60000 }
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        foreach ($line in $Lines) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$line)
            if ($bytes.Length -ge $maxBytes) { $skipped++; continue }
            try { $udp.Send($bytes, $bytes.Length, $Endpoint, $Port) | Out-Null; $sent++ } catch { $failed++ }
        }
    } catch { $failed += @($Lines).Count } finally { if ($udp) { $udp.Close() } }
    $status = if ($failed -gt 0 -and $sent -eq 0) { 'Failed' } elseif ($failed -gt 0 -or $skipped -gt 0) { 'Partial' } else { 'Sent' }
    return [PSCustomObject]@{ Status = $status; Sent = $sent; Skipped = $skipped; Failed = $failed }
}

function Send-SiemHttp {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Endpoint, [string[]]$Lines, [int]$TimeoutSec = 0)
    if (-not $Endpoint -or @($Lines).Count -eq 0) { return $false }
    return [bool](Invoke-WebhookPost -Url $Endpoint -Payload @{ events = @($Lines) } -Label 'SIEM' -State $null -TimeoutSec $TimeoutSec -MaxAttempts 1 -RetryDelayMs 0)
}

function Get-SiemSafeOutputPath {
    param([string]$Directory, [string]$FileName)
    $leaf = [System.IO.Path]::GetFileName(([string]$FileName).Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'siem-events.log' }
    # Resolve-BuildContainedPath owns containment plus reparse-point rejection.
    # Siem already force-imports PathUtils; the filename has already been
    # reduced to a leaf, so no legitimate caller loses a path here.
    if (Get-Command Resolve-BuildContainedPath -ErrorAction SilentlyContinue) {
        $contained = Resolve-BuildContainedPath -Path $leaf -Base $Directory
        if ($contained) { return $contained }
        return ''
    }
    return Join-Path $Directory $leaf
}

function Get-SiemRedactedEndpoint {
    param([string]$Endpoint)
    if (Get-Command Get-AlertRedactedUrl -ErrorAction SilentlyContinue) { try { return [string](Get-AlertRedactedUrl $Endpoint) } catch { } }
    return '[redacted-endpoint]'
}

function Export-SiemEvents {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([PSCustomObject]$State, [string]$AuditLogPath = '')
    $cfg = Get-SiemConfig -State $State
    if (-not $cfg -or -not [bool](Get-SectionValue -Section $cfg -Key 'enabled' -Default $false)) { return @{ Status = 'Skipped'; Reason = 'security.siem.enabled is false'; Count = 0; OutputPath = ''; Sample = '' } }
    if (-not $AuditLogPath -and (Get-Command Get-AuditLogPath -ErrorAction SilentlyContinue)) { $AuditLogPath = Get-AuditLogPath -State $State }
    $entries = @(Get-AuditEntries -AuditLogPath $AuditLogPath)
    if ($entries.Count -eq 0) { return @{ Status = 'Skipped'; Reason = 'Audit log empty or not found'; Count = 0; OutputPath = $AuditLogPath; Sample = '' } }
    $stateTenant = [string](Get-SectionValue -Section $State -Key 'TenantId' -Default '')
    $seen = @{}; $unique = [System.Collections.Generic.List[hashtable]]::new(); $duplicates = 0
    foreach ($entry in $entries) {
        $entryTenant = [string](Get-SectionValue -Section $entry -Key 'TenantId' -Default '')
        if ($stateTenant -and $entryTenant -and $entryTenant -ne $stateTenant) { continue }
        $id = Get-SiemHash $entry
        if ($seen.ContainsKey($id)) { $duplicates++; continue }
        $seen[$id] = $true; $copy = @{}; foreach ($key in $entry.Keys) { $copy[[string]$key] = $entry[$key] }; $copy['EventId'] = $id; $unique.Add($copy) | Out-Null
    }
    if ($unique.Count -eq 0) { return [PSCustomObject]@{ Status = 'Skipped'; Reason = 'No entries for the selected tenant'; Count = 0; DuplicateCount = $duplicates; OutputPath = ''; Sample = '' } }
    $format = [string](Get-SectionValue -Section $cfg -Key 'format' -Default 'cef'); $transport = [string](Get-SectionValue -Section $cfg -Key 'transport' -Default 'file'); $endpoint = [string](Get-SectionValue -Section $cfg -Key 'endpoint' -Default ''); $port = [int](Get-SectionValue -Section $cfg -Key 'port' -Default (Get-BuildConstant -Key 'SyslogPort' -Fallback 514)); $outputFile = [string](Get-SectionValue -Section $cfg -Key 'outputFile' -Default 'siem-events.log')
    if ($endpoint -match '\$\{env:') { $endpoint = Resolve-EnvPlaceholder -Text $endpoint }; if ($endpoint -match '\$\{env:') { $endpoint = '' }
    $lines = [System.Collections.Generic.List[string]]::new(); $sequence = 0
    foreach ($entry in $unique) {
        $sequence++
        $id = [string]$entry.EventId
        if ($format -eq 'syslog') { $lines.Add((ConvertTo-SyslogEvent -Entry $entry -Sequence $sequence -EventId $id)) | Out-Null }
        elseif ($format -eq 'json') {
            $ordered = [ordered]@{}
            foreach ($key in @('EventId', 'Timestamp', 'Action', 'Outcome', 'Detail', 'User', 'Host', 'TenantId', 'CorrelationId')) { if ($entry.ContainsKey($key)) { $ordered[$key] = $entry[$key] } }
            $ordered['Sequence'] = $sequence
            $lines.Add(($ordered | ConvertTo-Json -Compress)) | Out-Null
        } else { $lines.Add((ConvertTo-CefEvent -Entry $entry -Sequence $sequence -EventId $id)) | Out-Null }
    }
    $outPath = ''; $status = 'Exported'; $transportStatus = 'Written'; $sent = $lines.Count; $skipped = 0; $failed = 0
    if ($transport -eq 'udp' -and $endpoint) { $result = Send-SiemUdp -Endpoint $endpoint -Port $port -Lines @($lines); $outPath = "udp://$(Get-SiemRedactedEndpoint $endpoint):$port"; $transportStatus = $result.Status; $sent = $result.Sent; $skipped = $result.Skipped; $failed = $result.Failed; if ($transportStatus -ne 'Sent') { $status = 'Partial' } }
    elseif ($transport -eq 'http' -and $endpoint) { $timeout = [int](Get-SectionValue -Section $cfg -Key 'timeoutSec' -Default 0); $ok = Send-SiemHttp -Endpoint $endpoint -Lines @($lines) -TimeoutSec $timeout; $outPath = Get-SiemRedactedEndpoint $endpoint; $transportStatus = if ($ok) { 'Sent' } else { 'Failed' }; $sent = if ($ok) { $lines.Count } else { 0 }; if (-not $ok) { $status = 'Failed' } }
    else { $dir = Get-SiemReportDir -State $State; $outPath = Get-SiemSafeOutputPath -Directory $dir -FileName $outputFile; $ok = Write-SiemFile -OutputPath $outPath -Lines @($lines); $transportStatus = if ($ok) { 'Written' } else { 'Failed' }; $sent = if ($ok) { $lines.Count } else { 0 }; if (-not $ok) { $status = 'Failed' } }
    $sample = if ($lines.Count -gt 0) { $lines[0] } else { '' }
    if ($status -eq 'Exported' -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) { Write-Log (Get-LocaleMessage -Key 'log.siem.exported' -MessageArgs @($lines.Count, $format, $outPath)) 'Info' $State }
    return @{ Status = $status; Transport = $transport; TransportStatus = $transportStatus; Reason = ''; Count = $lines.Count; DuplicateCount = $duplicates; SequenceCount = $sequence; SentCount = $sent; SkippedCount = $skipped; FailedCount = $failed; Format = $format; OutputPath = $outPath; Sample = $sample }
}

Export-ModuleMember -Function @('Get-SiemConfig', 'Get-SiemReportDir', 'ConvertTo-CefEvent', 'ConvertTo-SyslogEvent', 'Get-AuditEntries', 'Write-SiemFile', 'Send-SiemUdp', 'Send-SiemHttp', 'Export-SiemEvents')
