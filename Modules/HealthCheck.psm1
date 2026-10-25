
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
$healthLogPath = Join-Path $PSScriptRoot 'Logging.psm1'
if (Test-Path $healthLogPath) { $null = Import-Module $healthLogPath -DisableNameChecking -ErrorAction SilentlyContinue }
Import-GBuildModule -Names @('Environment', 'Project', 'SharedUtils', 'PathUtils', 'BuildConstants') -Force
Import-GBuildModuleIfMissing -Name 'ConfigProvider' -SentinelCommand 'Get-SectionValue'

$script:HealthResults = @()

function Get-HealthConfigValue {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Key, $DefaultValue)

Set-StrictMode -Version 1.0
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) { return Get-ConfigValue -Path "health.$Key" -State $State -Default $DefaultValue }
    $health = Get-SectionValue -Section (Get-SectionValue -Section $State -Key 'BuildConfig' -Default $null) -Key 'health' -Default $null
    return Get-SectionValue -Section $health -Key $Key -Default $DefaultValue
}

function Get-HealthRoot {
    param([PSCustomObject]$State)
    foreach ($name in @('WorkingDir', 'ProjectRoot', 'ScriptRoot')) {
        $value = Get-SectionValue -Section $State -Key $name -Default ''
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
    }
    return (Get-Location).ProviderPath
}

function Get-HealthOsName {
    param([PSCustomObject]$State)
    $configured = [string](Get-SectionValue -Section $State -Key 'OS' -Default '')
    if ($configured) { return $configured }
    return (Get-CanonicalOSName)
}

function Get-HealthStatusIcon {
    param([string]$Status)
    switch ($Status) { 'Pass' { return '[OK]' } 'Warn' { return '[!!]' } 'Fail' { return '[X]' } default { return '[?]' } }
}

function Get-HealthStatusColor {
    param([string]$Status)
    switch ($Status) { 'Pass' { return 'Succ' } 'Warn' { return 'Warn' } 'Fail' { return 'Err' } default { return 'Gray' } }
}

function New-HealthResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Pass', 'Warn', 'Fail')][string]$Status = 'Pass',
        [string]$Message = '',
        [string]$Suggestion = '',
        [string]$Details = '',
        [int[]]$CheckedPorts = @(),
        [int[]]$InUsePorts = @()
    )
    return [PSCustomObject]@{
        Name = $Name
        Status = $Status
        Message = $Message
        Suggestion = $Suggestion
        Details = $Details
        CheckedPorts = @($CheckedPorts)
        InUsePorts = @($InUsePorts)
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
}

function Test-DotnetSdk {
    param([PSCustomObject]$State)
    $minMajor = [int](Get-BuildConstant -Key 'SdkMajorMin' -State $State -Fallback 8)
    $dotnet = [string](Get-SectionValue -Section $State -Key 'DotnetCmd' -Default '')
    if (-not $dotnet) { return New-HealthResult -Name '.NET SDK' -Status 'Fail' -Message 'dotnet CLI not found' -Suggestion ("Install .NET SDK {0}+" -f $minMajor) }
    try {
        $version = ((& $dotnet --version 2>&1) | Select-Object -First 1).ToString().Trim()
        $major = [int]($version.Split('.')[0])
        if ($major -lt $minMajor) { return New-HealthResult -Name '.NET SDK' -Status 'Warn' -Message "Version $version (minimum ${minMajor}.0 required)" -Suggestion "Upgrade to .NET ${minMajor} or higher" -Details "Path: $dotnet" }
        return New-HealthResult -Name '.NET SDK' -Status 'Pass' -Message "Version $version" -Details "Path: $dotnet"
    } catch { return New-HealthResult -Name '.NET SDK' -Status 'Fail' -Message 'Could not retrieve dotnet version' -Suggestion 'Check that dotnet is working normally' }
}

function Test-JavaJdk {
    param([PSCustomObject]$State)
    $java = [string](Get-SectionValue -Section $State -Key 'JavaSdk' -Default '')
    if (-not $java) { return New-HealthResult -Name 'Java JDK' -Status 'Warn' -Message 'JDK not found' -Suggestion 'Install JDK 17+ for Android/MAUI builds' }
    # Single owner: BuildConstants JdkJavacRelativeWin/Unix (config-mapped to
    # sdk.jdkJavacRelativeWin/Unix, read by SDK.psm1). A hardcoded
    # 'bin/javac.exe' here disagreed with an operator override, so health said
    # Pass while the build resolved a different path (or Fail on a valid one).
    $relative = ''
    # Stated ONCE per platform. The survival guard below used to repeat the
    # same OS ternary that the try block just computed, so the default existed
    # twice in one function and a fix applied to only one copy left health
    # resolving a path the build never used.
    $javacRelativeFallback = if ((Get-HealthOsName $State) -eq 'Windows') { 'bin/javac.exe' } else { 'bin/javac' }
    try {
        if ((Get-HealthOsName $State) -eq 'Windows') { $relative = [string](Get-BuildConstant -Key 'JdkJavacRelativeWin' -State $State -Fallback $javacRelativeFallback) }
        else { $relative = [string](Get-BuildConstant -Key 'JdkJavacRelativeUnix' -State $State -Fallback $javacRelativeFallback) }
    } catch { $relative = '' }
    if ([string]::IsNullOrWhiteSpace($relative)) { $relative = $javacRelativeFallback }
    $javac = Join-Path $java $relative
    if (-not (Test-Path -LiteralPath $javac -PathType Leaf)) { return New-HealthResult -Name 'Java JDK' -Status 'Fail' -Message "javac does not exist at $javac" -Suggestion 'Install a full JDK' }
    try { $version = ((& $javac -version 2>&1) | Select-Object -First 1).ToString(); return New-HealthResult -Name 'Java JDK' -Status 'Pass' -Message $version -Details "JAVA_HOME: $java" }
    catch { return New-HealthResult -Name 'Java JDK' -Status 'Warn' -Message 'javac exists but cannot run' }
}

function Test-AndroidSdk {
    param([PSCustomObject]$State)
    $android = [string](Get-SectionValue -Section $State -Key 'AndroidSdk' -Default '')
    if (-not $android) { return New-HealthResult -Name 'Android SDK' -Status 'Warn' -Message 'Android SDK not found' -Suggestion 'Install the Android SDK' }
    # Single owner: BuildConstants AndroidAdbRelativeWin/Unix (config-mapped to
    # sdk.androidAdbRelativeWin/Unix). Same disagreement class as Test-JavaJdk
    # above: health and SDK resolution must read the same constant.
    $relative = ''
    # Stated ONCE per platform, same reason as Test-JavaJdk above.
    $adbRelativeFallback = if ((Get-HealthOsName $State) -eq 'Windows') { 'platform-tools/adb.exe' } else { 'platform-tools/adb' }
    try {
        if ((Get-HealthOsName $State) -eq 'Windows') { $relative = [string](Get-BuildConstant -Key 'AndroidAdbRelativeWin' -State $State -Fallback $adbRelativeFallback) }
        else { $relative = [string](Get-BuildConstant -Key 'AndroidAdbRelativeUnix' -State $State -Fallback $adbRelativeFallback) }
    } catch { $relative = '' }
    if ([string]::IsNullOrWhiteSpace($relative)) { $relative = $adbRelativeFallback }
    $adb = Join-Path $android $relative
    if (-not (Test-Path -LiteralPath $adb -PathType Leaf)) { return New-HealthResult -Name 'Android SDK' -Status 'Fail' -Message "adb does not exist: $adb" -Suggestion 'Install Android platform-tools' }
    return New-HealthResult -Name 'Android SDK' -Status 'Pass' -Message "Found at $android" -Details "adb: $adb"
}

function Get-HealthFreeBytes {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { throw (Resolve-LogMessage -Key 'log.healthcheck.line130' -Fallback 'Unable to determine filesystem root') }
    try {
        $drive = New-Object System.IO.DriveInfo($root)
        if ($drive.IsReady) { return [long]$drive.AvailableFreeSpace }
    } catch { }
    $dfOutput = @(& df -Pk $full 2>$null)
    if ($dfOutput.Count -gt 0) {
        $line = [string]$dfOutput[$dfOutput.Count - 1]
        $fields = @($line -split '\s+' | Where-Object { $_ })
        if ($fields.Count -ge 4) { return [long]$fields[3] * 1024 }
    }
    throw (Resolve-LogMessage -Key 'log.healthcheck.line141' -Fallback 'Unable to determine free disk space')
}

function Test-DiskSpace {
    [CmdletBinding()]
    param([PSCustomObject]$State, [int]$MinMB = 0)
    if ($MinMB -le 0) { $MinMB = [int](Get-HealthConfigValue -State $State -Key 'minDiskSpaceMB' -DefaultValue (Get-BuildConstant -Key 'MinDiskMB' -State $State -Fallback 2048)) }
    $target = Get-HealthRoot $State
    try {
        $freeBytes = Get-HealthFreeBytes -Path $target
        $freeMB = [math]::Round($freeBytes / 1MB, 0)
        if ($State -and ($State.PSObject.Properties.Name -contains 'ChaosDiskSpaceMB') -and $State.ChaosDiskSpaceMB) { $freeMB = [long]$MinMB - 1 }
        if ($freeMB -lt $MinMB) { return New-HealthResult -Name 'Disk Space' -Status 'Fail' -Message "Only $freeMB MB remaining (minimum $MinMB MB required)" -Suggestion 'Clean build artifacts or expand storage' }
        if ($freeMB -lt ($MinMB * 2)) { return New-HealthResult -Name 'Disk Space' -Status 'Warn' -Message "$freeMB MB (approaching minimum $MinMB MB)" -Details "Path: $target" }
        return New-HealthResult -Name 'Disk Space' -Status 'Pass' -Message "$freeMB MB available" -Details "Path: $target"
    } catch { return New-HealthResult -Name 'Disk Space' -Status 'Warn' -Message 'Could not determine free disk space' }
}

function Get-HealthEndpointValue {
    param($Endpoint, [string]$Name, $Default = $null)
    return Get-SectionValue -Section $Endpoint -Key $Name -Default $Default
}

function Get-HealthRedactedUrl {
    param([string]$Url)
    if (Get-Command Get-AlertRedactedUrl -ErrorAction SilentlyContinue) { try { return [string](Get-AlertRedactedUrl $Url) } catch { } }
    try { $uri = [System.Uri]::new($Url); return ('{0}://{1}/[redacted]' -f $uri.Scheme, $uri.Host) } catch { return '[redacted-url]' }
}

function Protect-HealthText {
    param([AllowNull()][object]$Text, [PSCustomObject]$State = $null)
    if ($null -eq $Text) { return '' }
    # Canonical routine, same shape as Security/Sast. The local assignment regex
    # this replaces was one of FOUR divergent copies; it happened to be the
    # broadest of them, which is exactly why the drift was invisible - the two
    # narrower copies in RootCause and AnomalyDetector silently under-redacted.
    # The URL redactor below is passed through so the host-stripping behaviour of
    # this module's own Get-HealthRedactedUrl is preserved.
    #
    # -State is FORWARDED. It was not accepted at all here, so this sink ran the
    # redaction ruleset with no project context: Get-BuildSecretRedactPatterns
    # treats security.redactPatterns from gbuild.config.json as tier 1, and an
    # operator who added a project-specific secret pattern got health output
    # that was NOT scrubbed by it, while log/security/sast/alert/infra output
    # was. A redaction gap created purely by a wrapper dropping one parameter.
    $urlRedactor = { param($candidate) Get-HealthRedactedUrl $candidate }
    return (Invoke-BuildSecretProtect -Text ([string]$Text) -State $State -RedactUrls -UrlRedactor $urlRedactor)
}

function Test-NetworkConnectivity {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $endpoints = @(Get-HealthConfigValue -State $State -Key 'endpoints' -DefaultValue @())
    if ($endpoints.Count -eq 0) { return New-HealthResult -Name 'Network' -Status 'Warn' -Message 'No network endpoints configured' }
    $timeoutSec = [double](Get-HealthConfigValue -State $State -Key 'networkTimeout' -DefaultValue (Get-BuildConstant -Key 'NetworkTimeout' -State $State -Fallback 15))
    if ($State -and ($State.PSObject.Properties.Name -contains 'ChaosNetworkTimeout') -and $null -ne $State.ChaosNetworkTimeout) { $timeoutSec = [double]$State.ChaosNetworkTimeout }
    $timeoutMs = [int][math]::Max(1, $timeoutSec * 1000)
    $results = [System.Collections.Generic.List[string]]::new()
    $hasFailure = $false
    foreach ($endpoint in $endpoints) {
        if ($endpoint -is [string]) {
            try { $name = ([System.Uri]$endpoint).Host } catch { $name = 'endpoint' }
            $url = [string]$endpoint
        } else {
            $name = [string](Get-HealthEndpointValue $endpoint 'Name' (Get-HealthEndpointValue $endpoint 'name' 'endpoint'))
            $url = [string](Get-HealthEndpointValue $endpoint 'URL' (Get-HealthEndpointValue $endpoint 'url' ''))
        }
        try {
            if ([string]::IsNullOrWhiteSpace($url)) { throw (Resolve-LogMessage -Key 'log.healthcheck.line209' -Fallback 'endpoint URL is empty') }
            $request = [System.Net.HttpWebRequest]::Create($url)
            $request.Method = 'HEAD'
            $request.Timeout = $timeoutMs
            $request.ReadWriteTimeout = $timeoutMs
            $request.UserAgent = 'gbuild-health/2.0'
            $request.AllowAutoRedirect = $true
            $response = $request.GetResponse()
            try { $status = [int]$response.StatusCode } finally { $response.Close() }
            $results.Add("OK $name ($status)") | Out-Null
        } catch {
            $hasFailure = $true
            $safe = Protect-HealthText $_.Exception.Message -State $State
            $results.Add("FAIL $name ($safe)") | Out-Null
        }
    }
    $status = if ($hasFailure) { 'Warn' } else { 'Pass' }
    return New-HealthResult -Name 'Network' -Status $status -Message ($results -join ' | ') -Suggestion $(if ($hasFailure) { 'Check internet connection or firewall' } else { '' })
}

function Test-RequiredTools {
    param([PSCustomObject]$State)
    $required = @(Get-HealthConfigValue -State $State -Key 'requiredTools' -DefaultValue @('dotnet', 'git'))
    $optional = @(Get-HealthConfigValue -State $State -Key 'optionalTools' -DefaultValue @('node', 'npm', 'java', 'javac', 'adb', 'gh', 'docker', 'keytool'))
    $missing = @()
    $present = @()
    foreach ($tool in @($required + $optional)) {
        $name = [string]$tool
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $command = Get-Command $name -ErrorAction SilentlyContinue
        $chaos = $State -and ($State.PSObject.Properties.Name -contains 'ChaosMissingTool') -and [string]$State.ChaosMissingTool -eq $name
        if ($command -and -not $chaos) { if ($required -contains $name) { $present += $name } } elseif ($required -contains $name) { $missing += $name }
    }
    if ($missing.Count -gt 0) { return New-HealthResult -Name 'Required Tools' -Status 'Fail' -Message "Missing: $($missing -join ', ')" -Suggestion "Install missing tools: $($missing -join ', ')" -Details "Available: $($present -join ', ')" }
    return New-HealthResult -Name 'Required Tools' -Status 'Pass' -Message 'All required tools are available' -Details "Available: $($present -join ', ')"
}

function Get-HealthConfiguredPorts {
    param([PSCustomObject]$State)
    $configured = Get-HealthConfigValue -State $State -Key 'ports' -DefaultValue $null
    if ($null -ne $configured) { return @($configured | ForEach-Object { try { [int]$_ } catch { } } | Where-Object { $_ -gt 0 -and $_ -le 65535 }) }
    return @(Get-BuildConstant -Key 'DefaultPorts' -State $State -Fallback @(5000,5001,7000,7001,8080,8443) | ForEach-Object { [int]$_ })
}

function Test-PortAvailability {
    [CmdletBinding()]
    param([PSCustomObject]$State, [int[]]$Ports = @())
    $portsConfig = Get-HealthConfigValue -State $State -Key 'checkPorts' -DefaultValue $true
    if ($portsConfig -is [bool] -and -not $portsConfig) { return New-HealthResult -Name 'Ports' -Status 'Pass' -Message 'Port check disabled by config' }
    $effective = if ($PSBoundParameters.ContainsKey('Ports') -and $Ports.Count -gt 0) { @($Ports) } else { @(Get-HealthConfiguredPorts -State $State) }
    $effective = @($effective | ForEach-Object { try { [int]$_ } catch { } } | Where-Object { $_ -gt 0 -and $_ -le 65535 } | Select-Object -Unique)
    if ($effective.Count -eq 0) { return New-HealthResult -Name 'Ports' -Status 'Warn' -Message 'No valid ports configured' -CheckedPorts @() -InUsePorts @() }
    $inUse = @()
    foreach ($port in $effective) { if (Test-PortListening -Port $port) { $inUse += $port } }
    if ($inUse.Count -gt 0) { return New-HealthResult -Name 'Ports' -Status 'Warn' -Message "In use: $($inUse -join ', ')" -Suggestion 'Use different ports or free ports before building' -Details "Available: $(@($effective | Where-Object { $_ -notin $inUse }) -join ', ')" -CheckedPorts $effective -InUsePorts $inUse }
    return New-HealthResult -Name 'Ports' -Status 'Pass' -Message 'All configured ports are available' -Details "Checked: $($effective -join ', ')" -CheckedPorts $effective -InUsePorts @()
}

function Test-ProjectFiles {
    param([PSCustomObject]$State)
    $root = Get-HealthRoot $State
    $projects = @(Get-AllProjects -SearchRoot $root)
    if ($projects.Count -eq 0) { return New-HealthResult -Name 'Project Files' -Status 'Warn' -Message 'No .csproj files found' -Suggestion 'Ensure the working directory contains a .NET project' }
    $invalid = @()
    foreach ($project in $projects) {
        try { [xml]$content = Get-Content -LiteralPath $project.FullName -Raw -Encoding UTF8 -ErrorAction Stop; if (-not $content.DocumentElement) { $invalid += $project.Name } }
        catch { $invalid += $project.Name }
    }
    if ($invalid.Count -gt 0) { return New-HealthResult -Name 'Project Files' -Status 'Fail' -Message "Invalid project: $($invalid -join ', ')" -Suggestion 'Check .csproj XML syntax' }
    return New-HealthResult -Name 'Project Files' -Status 'Pass' -Message "$($projects.Count) valid project(s)" -Details (($projects | ForEach-Object { $_.Name }) -join ', ')
}

function Test-GitStatus {
    param([PSCustomObject]$State)
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { return New-HealthResult -Name 'Git' -Status 'Warn' -Message 'git not available' -Suggestion 'Install git if versioning is required' }
    $workingDir = [string](Get-SectionValue -Section $State -Key 'WorkingDir' -Default '')
    if ([string]::IsNullOrWhiteSpace($workingDir) -or -not (Test-Path -LiteralPath $workingDir -PathType Container)) { return New-HealthResult -Name 'Git' -Status 'Warn' -Message 'State.WorkingDir is not available' -Suggestion 'Set WorkingDir before checking git status' }
    $isRepo = (& git '-C' $workingDir rev-parse '--is-inside-work-tree' 2>$null | Out-String).Trim()
    if ($isRepo -ne 'true') { return New-HealthResult -Name 'Git' -Status 'Warn' -Message 'Not a git repository' -Suggestion 'Initialize git repo to use versioning' }
    $branch = (& git '-C' $workingDir branch '--show-current' 2>$null | Out-String).Trim()
    if (-not $branch) { $branch = 'detached' }
    $commit = (& git '-C' $workingDir rev-parse '--short' 'HEAD' 2>$null | Out-String).Trim()
    $statusLines = @(& git '-C' $workingDir status '--porcelain' 2>$null)
    $uncommitted = @($statusLines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
    $status = if ($uncommitted -gt 0) { 'Warn' } else { 'Pass' }
    $message = if ($uncommitted -gt 0) { "Branch $branch, $uncommitted uncommitted changes" } else { "Branch $branch, clean" }
    return New-HealthResult -Name 'Git' -Status $status -Message $message -Details "Commit: $commit, Branch: $branch"
}

function Get-HealthLogLevel {
    param($State)
    $level = Get-SectionValue -Section $State -Key 'LogLevel' -Default 2
    if ($level -is [int]) { return $level }
    switch ("$level".Trim().ToLowerInvariant()) { 'debug' { return 3 } 'verbose' { return 3 } 'info' { return 2 } 'warn' { return 1 } 'warning' { return 1 } 'error' { return 0 } default { $n = 0; if ([int]::TryParse("$level", [ref]$n)) { return $n }; return 2 } }
}

function Invoke-HealthCheck {
    [CmdletBinding()]
    param([PSCustomObject]$State, [switch]$IncludeNetwork, [switch]$Quick)
    $script:HealthResults = @()
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.health.running' -Fallback '[HEALTH] Running health check') 'Info' $State }
    $checkDisk = [bool](Get-HealthConfigValue -State $State -Key 'checkDiskSpace' -DefaultValue $true)
    $checkSdk = [bool](Get-HealthConfigValue -State $State -Key 'checkSDKVersions' -DefaultValue $true)
    $checkPorts = [bool](Get-HealthConfigValue -State $State -Key 'checkPorts' -DefaultValue $true)
    $checkNetwork = [bool](Get-HealthConfigValue -State $State -Key 'checkNetwork' -DefaultValue $true)
    $checks = [System.Collections.Generic.List[object]]::new()
    $checks.Add((Test-DotnetSdk -State $State))
    if ($checkSdk) { $checks.Add((Test-JavaJdk -State $State)); $checks.Add((Test-AndroidSdk -State $State)) }
    $checks.Add((Test-RequiredTools -State $State))
    if ($checkDisk) { $checks.Add((Test-DiskSpace -State $State)) }
    if ($checkPorts) { $checks.Add((Test-PortAvailability -State $State)) }
    $checks.Add((Test-ProjectFiles -State $State))
    $checks.Add((Test-GitStatus -State $State))
    if ($IncludeNetwork -and -not $Quick -and $checkNetwork) { $checks.Add((Test-NetworkConnectivity -State $State)) }
    foreach ($check in $checks) { $script:HealthResults += $check }
    return $script:HealthResults
}

function Show-HealthReport {
    [CmdletBinding()]
    param([PSCustomObject]$State, [PSCustomObject[]]$Results = @())
    if (@($Results).Count -eq 0) { $Results = @($script:HealthResults) }
    if (@($Results).Count -eq 0) { if (Get-Command Write-Warn -ErrorAction SilentlyContinue) { Write-Warn (Resolve-LogMessage -Key 'log.health.noResults' -Fallback 'No health check results yet') }; return $false }
    $pass = @($Results | Where-Object { $_.Status -eq 'Pass' }).Count
    $warn = @($Results | Where-Object { $_.Status -eq 'Warn' }).Count
    $fail = @($Results | Where-Object { $_.Status -eq 'Fail' }).Count
    $color = if ($fail -gt 0) { 'Err' } elseif ($warn -gt 0) { 'Warn' } else { 'Succ' }
    if (Get-Command Write-SectionBox -ErrorAction SilentlyContinue) { Write-SectionBox '[HEALTH] HEALTH CHECK REPORT' -Color $color -State $State }
    foreach ($result in $Results) {
        $label = ("{0} {1}" -f (Get-HealthStatusIcon $result.Status), $result.Name).PadRight(25)
        $resultColor = Get-HealthStatusColor $result.Status
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log "  $label $($result.Message)" -Color $resultColor -State $State }
        if ($result.Suggestion -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) { Write-Log "     [TIP] $($result.Suggestion)" -Color DarkCyan -State $State }
        if ($result.Details -and (Get-HealthLogLevel $State) -ge 3 -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) { Write-Log "     [INFO] $($result.Details)" -Color DarkGray -State $State }
    }
    if (Get-Command Write-Sep -ErrorAction SilentlyContinue) { Write-Sep }
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.health.summary' -MessageArgs @([string]$pass, [string]$warn, [string]$fail) -Fallback '  Summary: {0} PASS | {1} WARN | {2} FAIL') -State $State }
    if ($fail -gt 0) { return $false }
    return $true
}

function Get-HealthBuildRoots {
    param([PSCustomObject]$State)
    $roots = @()
    foreach ($name in @('WorkingDir', 'ProjectRoot', 'ScriptRoot')) {
        $path = [string](Get-SectionValue -Section $State -Key $name -Default '')
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            try { $full = [System.IO.Path]::GetFullPath($path).TrimEnd('\', '/'); if ($roots -notcontains $full) { $roots += $full } } catch { }
        }
    }
    return @($roots)
}

function Test-HealthPathUnderRoot {
    param([string]$Path, [string]$Root)
    # PathUtils.Test-PathUnderRoots is the owner. HealthCheck force-imports
    # PathUtils at module load, so a local fallback here would only duplicate
    # live behavior without ever being the safer option.
    return Test-PathUnderRoots -Path $Path -AllowedRoots @($Root)
}

function Invoke-AutoFix {
    [CmdletBinding()]
    param([PSCustomObject]$State, [array]$Results)
    if (-not $State) { return [PSCustomObject]@{ Fixed = 0; Failed = 0 } }
    $fixed = 0
    $failed = 0
    $diskResults = @($Results | Where-Object { $_.Name -eq 'Disk Space' -and $_.Status -eq 'Fail' })
    if ($diskResults.Count -gt 0) {
        $roots = @(Get-HealthBuildRoots $State)
        if ($roots.Count -gt 1) { $roots = @($roots[0]) }
        foreach ($root in $roots) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'gbuild_*' -Force -ErrorAction SilentlyContinue)) {
                if (-not (Test-HealthPathUnderRoot $directory.FullName $root)) { continue }
                try { Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop; $fixed++ } catch { $failed++ }
            }
        }
    }
    $portResults = @($Results | Where-Object { $_.Name -eq 'Ports' -and $_.Status -ne 'Pass' })
    if ($portResults.Count -gt 0) {
        $kill = [bool](Get-HealthConfigValue -State $State -Key 'autoFixKillPorts' -DefaultValue $false)
        foreach ($result in $portResults) {
            $ports = @()
            if ($result.PSObject.Properties.Name -contains 'InUsePorts') { $ports = @($result.InUsePorts) }
            elseif ($result.PSObject.Properties.Name -contains 'CheckedPorts') { $ports = @($result.CheckedPorts) }
            if ($ports.Count -eq 0 -and $result.Message -match '^In use:\s*([0-9,\s]+)') { $ports = @($Matches[1] -split ',' | ForEach-Object { [int]$_.Trim() }) }
            elseif ($ports.Count -eq 0 -and $result.Message -match '^Checked:\s*([0-9,\s]+)') { $ports = @($Matches[1] -split ',' | ForEach-Object { [int]$_.Trim() }) }
            foreach ($port in @($ports | ForEach-Object { try { [int]$_ } catch { } } | Where-Object { $_ -gt 0 -and $_ -le 65535 } | Select-Object -Unique)) {
                if (-not (Get-Command Get-PortOwnerProcess -ErrorAction SilentlyContinue)) { $failed++; continue }
                $owners = @(Get-PortOwnerProcess -Port $port)
                foreach ($owner in $owners) {
                    if ($kill -and $owner -and ($owner.PSObject.Properties.Name -contains 'Id') -and [int]$owner.Id -gt 0) {
                        try { Stop-Process -Id ([int]$owner.Id) -Force -ErrorAction Stop; $fixed++ }
                        catch { $failed++ }
                    }
                }
            }
        }
    }
    foreach ($result in @($Results | Where-Object { $_.Status -eq 'Fail' -and $_.Name -notin @('Disk Space', 'Ports') })) { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.health.manualIntervention' -MessageArgs @([string]$result.Name) -Fallback '[FIX] {0} requires manual intervention') 'Warn' $State } }
    return [PSCustomObject]@{ Fixed = $fixed; Failed = $failed }
}

function Invoke-Doctor {
    [CmdletBinding()]
    param([PSCustomObject]$State, [switch]$Quick, [switch]$AsJson, [switch]$AutoFix)
    if (-not $State) { if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.health.stateUnavailable' -Fallback '[FAIL] State not available') 'Err' $null }; return $false }
    $results = @(Invoke-HealthCheck -State $State -Quick:$Quick)
    if ($AsJson) { $results | ConvertTo-Json -Depth $(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'JsonHealthDepth' -Fallback 8) } else { 8 }); return (@($results | Where-Object { $_.Status -eq 'Fail' }).Count -eq 0) }
    $passed = Show-HealthReport -State $State -Results $results
    $configured = [bool](Get-HealthConfigValue -State $State -Key 'autoFix' -DefaultValue $false)
    if ($AutoFix -or $configured) { [void](Invoke-AutoFix -State $State -Results $results) }
    return $passed
}

Export-ModuleMember -Function @('New-HealthResult', 'Test-DiskSpace', 'Test-NetworkConnectivity', 'Test-RequiredTools', 'Test-PortAvailability', 'Test-ProjectFiles', 'Test-GitStatus', 'Invoke-HealthCheck', 'Show-HealthReport', 'Invoke-Doctor', 'Invoke-AutoFix')
