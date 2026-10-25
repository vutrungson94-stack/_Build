# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# ==================================================================================================
# Modules/Distributed.psm1 (Multi-Host Distributed Build Execution)
# ==================================================================================================
#
# Provides:
#   - SSH-based execution of build tasks across multiple remote hosts
#   - Round-robin and tag-based task distribution strategies
#   - Per-host concurrency throttling (maxConcurrent)
#   - Connectivity probing before dispatch
#   - Unified result aggregation (compatible with Invoke-ParallelBuild output)
#
# Design notes:
#   - Cross-platform: uses the `ssh` CLI directly (no WinRM / no PS remoting).
#   - PS 5.1 safe: function-based, no classes, no ForEach-Object -Parallel.
#   - NO file sync: remote hosts must already have the repo cloned at `repoRoot`
#     and the required SDKs installed. Only build commands are executed remotely.
#   - SSH key auth: each host supplies an `identityFile` (path may start with ~).
# ==================================================================================================


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# Ensure Get-ElapsedSeconds (from BuildConstants) is available session-wide.
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-ElapsedSeconds'


# -- Resolve ${env:VAR} placeholders (shared helper) ---------------------------
# Imported from SharedUtils.psm1 to avoid duplicate definitions across modules.
Import-GBuildModule -Names @('SharedUtils') -Force
Import-GBuildModuleIfMissing -Name 'Locale' -SentinelCommand 'Get-LocaleMessage'

# On-demand import of ErrorHandling for Invoke-WithCircuitBreaker.
# ALWAYS -Global: a nested `-Force` re-import WITHOUT -Global orphans the
# global ErrorHandling module on PS 5.1 (same incident family as the PathUtils
# orphan via Plugins/PowerShell.psm1 — see ModuleHygiene tripwire test).
if (-not (Get-Command Invoke-WithCircuitBreaker -ErrorAction SilentlyContinue)) {
    $ehPath = Join-Path $PSScriptRoot 'ErrorHandling.psm1'
    if (Test-Path $ehPath) {
        $null = Import-Module $ehPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
}

# -- Resolve distributed config from State --------------------------------------
<#
.SYNOPSIS
    Resolves distributed build configuration from state with fallback defaults.
.DESCRIPTION
    Reads the distributed config section from State.BuildConfig.distributed and
    fills in default values for enabled, strategy, repoRoot, hosts, and timeouts.
.PARAMETER State
    The build state object.
.OUTPUTS
    PSCustomObject
#>
function Get-DistributedConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    # Single-sourced via BuildConstants.ConfigKeyMap (distributed.*).
    # Previously this function had local hardcoded fallbacks, bypassing the
    # central config system. Now it uses Get-BuildSetting so gbuild.config.json
    # overrides flow through uniformly.
    $defaults = [PSCustomObject]@{
        enabled  = [bool](Get-BuildSetting -Key 'DistributedEnabled' -State $State -Fallback $false)
        strategy = [string](Get-BuildSetting -Key 'DistributedStrategy' -State $State -Fallback 'round-robin')
        repoRoot = $null
        hosts    = @()
        timeout  = [PSCustomObject]@{
            connect   = [int](Get-BuildSetting -Key 'DistributedConnectTimeout' -State $State -Fallback 30)
            execution = [int](Get-BuildSetting -Key 'DistributedExecTimeout' -State $State -Fallback 600)
        }
        strictHostKeyChecking = [string](Get-BuildSetting -Key 'DistributedStrictHostKey' -State $State -Fallback 'accept-new')
        # Single owner Get-DistributedSshPort (config -> BuildConstants -> 22).
        # This key was MISSING here while :98 and :107 read $defaults.sshPort:
        # under Set-StrictMode a missing property is $null, [int]$null is 0, so
        # every host without an explicit port - and every out-of-range config
        # value - resolved to SSH port 0.
        sshPort  = [int](Get-DistributedSshPort -State $State)
        reportPath = [string](Get-BuildSetting -Key 'DistributedReportPath' -State $State -Fallback 'distributed-report')
        # Level 5 scale guards (single source, config-overridable).
        maxTotalConcurrency = [int](Get-BuildSetting -Key 'DistributedMaxTotalConcurrency' -State $State -Fallback 64)
        probeBatchSize = [int](Get-BuildSetting -Key 'DistributedProbeBatchSize' -State $State -Fallback 8)
        taskMaxRetries = [int](Get-BuildSetting -Key 'DistributedTaskMaxRetries' -State $State -Fallback 2)
    }

    $d = Get-ConfigSection -State $State -Path 'distributed'
    if ($d) {
        $cfg = [PSCustomObject]@{
            enabled  = if ($null -ne $d.enabled) { $d.enabled } else { $defaults.enabled }
            strategy = if ($d.strategy) { $d.strategy } else { $defaults.strategy }
            repoRoot = if ($d.repoRoot) { (Resolve-EnvPlaceholder $d.repoRoot) } else { $defaults.repoRoot }
            hosts    = @(if ($d.hosts) { $d.hosts } else { $defaults.hosts })
            timeout  = [PSCustomObject]@{
                connect   = if ($d.timeout -and $d.timeout.connect) { $d.timeout.connect } else { $defaults.timeout.connect }
                execution = if ($d.timeout -and $d.timeout.execution) { $d.timeout.execution } else { $defaults.timeout.execution }
            }
            strictHostKeyChecking = if ($d.strictHostKeyChecking) { $d.strictHostKeyChecking } else { $defaults.strictHostKeyChecking }
            sshPort = if ($d.PSObject.Properties.Name -contains 'sshPort' -and $null -ne $d.sshPort) { [int]$d.sshPort } else { [int]$defaults.sshPort }
            reportPath = if ($d.PSObject.Properties.Name -contains 'reportPath' -and $d.reportPath) { (Resolve-EnvPlaceholder $d.reportPath) } else { $defaults.reportPath }
            maxTotalConcurrency = if ($d.PSObject.Properties.Name -contains 'maxTotalConcurrency' -and $d.maxTotalConcurrency) { [int]$d.maxTotalConcurrency } else { [int]$defaults.maxTotalConcurrency }
            probeBatchSize = if ($d.PSObject.Properties.Name -contains 'probeBatchSize' -and $d.probeBatchSize) { [int]$d.probeBatchSize } else { [int]$defaults.probeBatchSize }
            taskMaxRetries = if ($d.PSObject.Properties.Name -contains 'taskMaxRetries' -and $null -ne $d.taskMaxRetries) { [int]$d.taskMaxRetries } else { [int]$defaults.taskMaxRetries }
        }
        if ($cfg.maxTotalConcurrency -lt 1) { $cfg.maxTotalConcurrency = 1 }
        if ($cfg.probeBatchSize -lt 1) { $cfg.probeBatchSize = 1 }
        if ($cfg.taskMaxRetries -lt 0) { $cfg.taskMaxRetries = 0 }
        if ($cfg.sshPort -lt 1 -or $cfg.sshPort -gt 65535) { $cfg.sshPort = [int]$defaults.sshPort }
        return $cfg
    }

    return $defaults
}

<#
.SYNOPSIS
    Resolves the default SSH port for remote build hosts.
.DESCRIPTION
    Single owner of `distributed.sshPort`. The key was previously declared in
    BuildConstants and ConfigKeyMap but had NO consumer - both call sites
    hardcoded `-Default 22`, so an operator setting e.g. sshPort: 2222 was
    silently ignored and every host without an explicit `port` connected to 22.
    Resolution order: config (distributed.sshPort) -> BuildConstants
    (SshDefaultPort) -> 22. An out-of-range value falls back to 22 rather than
    producing an invalid ssh argument.
#>
function Get-DistributedSshPort {
    [CmdletBinding()]
    [OutputType([int])]
    param([PSCustomObject]$State)
    $port = 22
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $port = [int](Get-BuildConstant -Key 'SshDefaultPort' -State $State -Fallback 22)
        }
    } catch { $port = 22 }
    if ($port -lt 1 -or $port -gt 65535) { return 22 }
    return $port
}

<#
.SYNOPSIS
    Executes a single command on a remote host over SSH (synchronous).
.DESCRIPTION
    Single-shot counterpart of the runspace-pool worker inside
    Invoke-DistributedBuild (same ssh argument construction, same result
    shape with Output/Success/Error/Duration/ExitCode). Used by
    Test-RemoteHost for connectivity probing and for one-off remote commands.
    Transport failures yield Success=$false (never throw); only parameter
    binding errors throw.
#>
function Invoke-RemoteCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$TargetHost,
        [Parameter(Mandatory)][string]$Command,
        [string]$RepoRoot = '/',
        [int]$ConnectTimeout = 0,
        [PSCustomObject]$State = $null,
        [string]$StrictHostKeyChecking = 'accept-new',
        [int]$ExecutionTimeout = 0
    )
    $started = Get-Date
    $fail = {
        param([int]$Code, [string]$Message)
        [PSCustomObject]@{ Output = $Message; Success = $false; Error = $Message; Duration = [math]::Round(((Get-Date) - $started).TotalSeconds, 3); ExitCode = $Code; TimedOut = ($Code -eq 124) }
    }
    if (-not (Test-DistributedHostIdentity -TargetHost $TargetHost)) { return (& $fail 2 'Invalid distributed host identity') }
    if ([string]::IsNullOrWhiteSpace($Command) -or $Command -match '[\x00-\x1f\x7f]') { return (& $fail 2 'Invalid remote command') }
    if ([string]::IsNullOrWhiteSpace($RepoRoot) -or $RepoRoot -match '[\x00-\x1f\x7f]' -or $RepoRoot -match '\$\{env:' -or -not ($RepoRoot.StartsWith('/') -or $RepoRoot -match '^[A-Za-z]:[\\/]' -or $RepoRoot.StartsWith('\\\\'))) { return (& $fail 2 'Invalid remote repository root') }
    if ($StrictHostKeyChecking -notin @('yes','accept-new')) { return (& $fail 2 'Unsafe SSH host key policy') }
    if ($ConnectTimeout -le 0) { $ConnectTimeout = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'ConnectTimeoutSec' -State $State -Fallback 30) } else { 30 } }
    if ($ExecutionTimeout -le 0) { $ExecutionTimeout = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [int](Get-BuildConstant -Key 'ExecutionTimeoutSec' -State $State -Fallback 600) } else { 600 } }
    $identity = Resolve-DistributedIdentityPath -Path ([string](Get-DistributedField -Object $TargetHost -Name 'identityFile'))
    if ((Get-DistributedField -Object $TargetHost -Name 'identityFile') -and -not $identity) { return (& $fail 2 'Invalid SSH identity path') }
    $port = [int](Get-DistributedField -Object $TargetHost -Name 'port' -Default (Get-DistributedSshPort -State $State))
    $user = [string](Get-DistributedField -Object $TargetHost -Name 'user')
    $hostname = [string](Get-DistributedField -Object $TargetHost -Name 'hostname')
    $remoteCommand = 'cd ' + (ConvertTo-DistributedShellQuote -Value $RepoRoot) + ' && ' + $Command
    $sshArgs = @()
    if ($identity) { $sshArgs += @('-i',$identity) }
    $sshArgs += @('-p',[string]$port,'-o',('ConnectTimeout=' + $ConnectTimeout),'-o',('StrictHostKeyChecking=' + $StrictHostKeyChecking),'-o','BatchMode=yes',($user + '@' + $hostname),$remoteCommand)
    $processResult = Invoke-DistributedSshProcess -SshArguments $sshArgs -TimeoutSec $ExecutionTimeout
    $message = [string]$processResult.Output
    return [PSCustomObject]@{
        Output   = $processResult.Output
        Success  = [bool]$processResult.Success
        Error    = if ($processResult.Success) { $null } else { $message }
        Duration = [math]::Round(((Get-Date) - $started).TotalSeconds, 3)
        ExitCode = [int]$processResult.ExitCode
        TimedOut = [bool]$processResult.TimedOut
    }
}

function Test-RemoteHost {
    [CmdletBinding()]
    param(
        [PSCustomObject]$TargetHost,
        [int]$ConnectTimeout = 0,
        [PSCustomObject]$State,
        [string]$StrictHostKeyChecking = 'accept-new'
    )
    if ($ConnectTimeout -le 0) { $ConnectTimeout = (Get-BuildConstant -Key 'ConnectTimeoutSec' -Fallback 30) }
    if (-not (Test-DistributedHostIdentity -TargetHost $TargetHost)) { return $false }
    if ($StrictHostKeyChecking -notin @('yes','accept-new')) { return $false }
    $result = Invoke-RemoteCommand -TargetHost $TargetHost -Command 'echo ok' -RepoRoot '/' -ConnectTimeout $ConnectTimeout -State $State -StrictHostKeyChecking $StrictHostKeyChecking -ExecutionTimeout $ConnectTimeout
    return $result.Success
}

function Get-DistributedField {
    param([object]$Object, [string]$Name, [object]$Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function Test-DistributedHostIdentity {
    param([object]$TargetHost)
    $name = [string](Get-DistributedField -Object $TargetHost -Name 'name')
    $hostname = [string](Get-DistributedField -Object $TargetHost -Name 'hostname')
    $user = [string](Get-DistributedField -Object $TargetHost -Name 'user')
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { return $false }
    if ($hostname -notmatch '^[A-Za-z0-9][A-Za-z0-9.:_-]{0,252}$' -or $hostname.StartsWith('-') -or $hostname.StartsWith('.') -or $hostname -match '(^|\.)\.\.($|\.)') { return $false }
    if ($user -notmatch '^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$' -or $user.StartsWith('-') -or $user.StartsWith('.')) { return $false }
    $port = Get-DistributedField -Object $TargetHost -Name 'port' -Default (Get-DistributedSshPort -State $State)
    try { if ([int]$port -lt 1 -or [int]$port -gt 65535) { return $false } } catch { return $false }
    $identity = [string](Get-DistributedField -Object $TargetHost -Name 'identityFile')
    if ($identity -and ($identity -match '[\x00-\x1f\x7f;|]' -or $identity -match '(^|[\\/])\.\.([\\/]|$)')) { return $false }
    return $true
}

function Resolve-DistributedIdentityPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    if ($Path.StartsWith('~')) {
        if ($Path.Length -gt 1 -and $Path[1] -ne '/' -and $Path[1] -ne '\') { return '' }
        # NOT $home: read-only automatic variable on PowerShell 6+, where the
        # assignment was a silent no-op and the HOST's home expanded the path.
        $userHome = [Environment]::GetFolderPath('UserProfile')
        if (-not $userHome) { $userHome = $env:HOME }
        if (-not $userHome) { return '' }
        $Path = $userHome + $Path.Substring(1)
    }
    if ($Path -match '[\x00-\x1f\x7f;|]') { return '' }
    try { return [System.IO.Path]::GetFullPath($Path) } catch { return '' }
}

function ConvertTo-DistributedShellQuote {
    param([string]$Value)
    return (ConvertTo-BuildArgument -Value $Value)
}

function ConvertTo-DistributedProcessArgument {
    param([string]$Value)
    return (ConvertTo-BuildArgument -Value $Value)
}

function Invoke-DistributedSshProcess {
    param(
        [string[]]$SshArguments,
        [int]$TimeoutSec
    )
    $result = [PSCustomObject]@{ Output = ''; ExitCode = -1; Success = $false; TimedOut = $false }
    if ($TimeoutSec -le 0) { $TimeoutSec = 600; if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { try { $TimeoutSec = [int](Get-BuildConstant -Key 'ExecutionTimeoutSec' -Fallback 600) } catch { $TimeoutSec = 600 } }; if ($TimeoutSec -le 0) { $TimeoutSec = 600 } }
    $ssh = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $ssh) { return $result }
    $source = if ($ssh.Source) { [string]$ssh.Source } elseif ($ssh.Path) { [string]$ssh.Path } else { 'ssh' }
    $psi = New-BuildProcessStartInfo -FilePath $source -Arguments ((@($SshArguments) | ForEach-Object { ConvertTo-DistributedProcessArgument -Value $_ }) -join ' ')
    if ($null -eq $psi) { return $result }
    $process = $null
    try {
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $waitMs = if ($TimeoutSec -gt 0) { $TimeoutSec * 1000 } else { -1 }
        if ($waitMs -gt 0) { $completed = $process.WaitForExit($waitMs) } else { $process.WaitForExit(); $completed = $true }
        if (-not $completed) {
            $result.TimedOut = $true
            $result.ExitCode = 124
            # Teardown is owned by SharedUtils.Stop-BuildProcess, including the
            # whole-tree-first, process-only-fallback kill used here before. The
            # local fallback preserves that shape only when the owner is absent.
            if (Get-Command Stop-BuildProcess -ErrorAction SilentlyContinue) {
                Stop-BuildProcess -Process $process -WaitMs 2000 -EntireTree
            } else {
                try { $process.Kill($true) } catch { try { $process.Kill() } catch { } }
                try { [void]$process.WaitForExit(2000) } catch { }
            }
        } else {
            $result.ExitCode = [int]$process.ExitCode
        }
        $outText = ''
        $errText = ''
        # Killing the process TREE does not close a redirected pipe that a
        # SURVIVING grandchild still holds. The unconditional
        # `$stdout.GetAwaiter().GetResult()` that used to sit here therefore
        # blocked until that grandchild exited - so a command whose child hung
        # (tail -f, a stuck reader) overran ExecutionTimeout by however long the
        # child lived, and the timeout contract was quietly unenforceable.
        # Drain with a bounded wait instead, and report the loss of the tail.
        $drain = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
        if ($stdout) { $drain.Add($stdout) }
        if ($stderr) { $drain.Add($stderr) }
        if ($drain.Count -gt 0) {
            # A timed-out process gets a short grace window for the pipes it was
            # writing; a normal exit still waits properly for EOF.
            $drainMs = if ($result.TimedOut) { 2000 } else { 120000 }
            $drained = $false
            try {
                $all = [System.Threading.Tasks.Task]::WhenAll($drain.ToArray())
                $drained = $all.Wait([int]$drainMs)
            } catch { }
            if ($drained) {
                try { $outText = $stdout.GetAwaiter().GetResult() } catch { }
                try { $errText = $stderr.GetAwaiter().GetResult() } catch { }
            } else {
                $result['OutputDrainTimedOut'] = $true
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log (Resolve-LogMessage -Key 'log.distributed.outputDrainTimedOut' -Fallback '[DISTRIBUTED] A surviving child process still holds the output pipe; the timed-out command output was truncated.') 'Warn' $State
                }
            }
        }
        $result.Output = (($outText + $errText).Trim())
        $result.Success = (-not $result.TimedOut -and $result.ExitCode -eq 0)
        return $result
    } catch {
        $result.Output = $_.Exception.Message
        return $result
    } finally {
        if ($process) {
            if (Get-Command Stop-BuildProcess -ErrorAction SilentlyContinue) {
                Stop-BuildProcess -Process $process -WaitMs 0
            } else {
                try { if (-not $process.HasExited) { $process.Kill() } } catch { }
            }
            try { $process.Dispose() } catch { }
        }
    }
}
<#
.SYNOPSIS
    Validates optional certificate-based authentication configuration for a host.
.DESCRIPTION
    When a host declares certificateThumbprint (Windows/macOS cert store) or
    certificatePath (PEM file, e.g. Linux), this performs a pre-flight validation
    of the certificate material BEFORE dispatch. It is a soft check: an invalid
    certificate logs a warning but does not by itself exclude the host (SSH key
    auth may still succeed). Returns a result object describing the outcome.
.PARAMETER TargetHost
    A distributed host object.
.PARAMETER State
    The build state object (used for logging only).
.OUTPUTS
    PSCustomObject with HasCertConfig, Valid, Message.
#>
function Test-RemoteHostCertificate {
    [CmdletBinding()]
    param(
        [PSCustomObject]$TargetHost,
        [PSCustomObject]$State
    )
    $result = [PSCustomObject]@{ HasCertConfig = $false; Valid = $false; Message = '' }
    $thumb = [string](Get-DistributedField -Object $TargetHost -Name 'certificateThumbprint')
    $path = [string](Get-DistributedField -Object $TargetHost -Name 'certificatePath')
    $password = [string](Get-DistributedField -Object $TargetHost -Name 'certificatePassword')
    if ($thumb) { $thumb = Resolve-EnvPlaceholder -Text $thumb }
    if ($password) { $password = Resolve-EnvPlaceholder -Text $password }
    if ([string]::IsNullOrWhiteSpace($thumb) -and [string]::IsNullOrWhiteSpace($path)) {
        $result.Message = 'No certificate configuration for host'
        return $result
    }
    $result.HasCertConfig = $true
    if ($thumb) {
        if ($thumb -match '\$\{env:' -or $thumb -notmatch '^[0-9A-Fa-f]{40,128}$') {
            $result.Message = 'Certificate thumbprint is invalid or unresolved'
            return $result
        }
        try {
            if (-not (Test-Path 'Cert:\')) {
                $result.Message = 'Certificate store (Cert:) not available on this platform'
                return $result
            }
            $found = @(Get-ChildItem -Path 'Cert:\LocalMachine\My','Cert:\CurrentUser\My' -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumb })
            if ($found.Count -eq 0) {
                $result.Message = 'Certificate thumbprint not found in store'
                return $result
            }
            $now = Get-Date
            $valid = @($found | Where-Object { $_.NotBefore -le $now -and $_.NotAfter -ge $now })
            if ($valid.Count -eq 0) { $result.Message = 'Certificate is outside its validity period'; return $result }
            $result.Valid = $true
            $result.Message = 'Certificate thumbprint found and currently valid'
            return $result
        } catch {
            $result.Message = 'Certificate store lookup failed'
            return $result
        }
    }
    if ($password -and $password -match '\$\{env:') {
        $result.Message = 'Certificate password placeholder unresolved'
        return $result
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { $result.Message = 'Certificate file not found'; return $result }
        $cert = $null
        try { $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($fullPath) } catch {
            if ($password) { $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($fullPath, $password) } else { throw }
        }
        $now = Get-Date
        if ($cert.NotBefore -gt $now -or $cert.NotAfter -lt $now) { $result.Message = 'Certificate is outside its validity period'; return $result }
        $result.Valid = $true
        $result.Message = 'Certificate file found and currently valid'
        $cert.Dispose()
        return $result
    } catch {
        $result.Message = 'Certificate file could not be parsed'
        return $result
    }
}

# -- Certificate gate decision (A2 hard-gate helper) -------------------------
<#
.SYNOPSIS
    Decides whether a host passes the certificate gate for inclusion in the pool.
.DESCRIPTION
    When a host declares a certificate configuration, runs Test-RemoteHostCertificate.
    If the certificate is invalid AND the host sets requireCert=$true, the host is
    GATED OUT (returns $false). In all other cases (no cert config, valid cert, or
    invalid cert without requireCert) the host passes the gate (returns $true).
.PARAMETER TargetHost
    A distributed host object.
.PARAMETER State
    The build state object (used for logging only).
.OUTPUTS
    System.Boolean
#>
function Test-HostCertGate {
    [CmdletBinding()]
    param(
        [PSCustomObject]$TargetHost,
        [PSCustomObject]$State
    )
    if (-not (Test-DistributedHostIdentity -TargetHost $TargetHost)) { return $false }
    $requireCert = [bool](Get-DistributedField -Object $TargetHost -Name 'requireCert' -Default $false)
    $cert = Test-RemoteHostCertificate -TargetHost $TargetHost -State $State
    if ($requireCert -and -not $cert.HasCertConfig) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.distributed.hostExcludedNoCert' -Fallback '[DISTRIBUTED] Host excluded: requireCert set but no certificate was configured') 'Err' $State }
        return $false
    }
    if ($cert.HasCertConfig -and -not $cert.Valid) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log (Resolve-LogMessage -Key 'log.distributed.certCheckFailed' -MessageArgs @([string]$cert.Message) -Fallback '[DISTRIBUTED] Host certificate check failed: {0}') 'Warn' $State }
        if ($requireCert) { return $false }
    }
    return $true
}

# -- Select available hosts ---------------------------------------------------
<#
.SYNOPSIS
    Returns the subset of configured hosts that are currently reachable.
.DESCRIPTION
    Probes each configured host with Test-RemoteHost and logs unreachable ones.
.PARAMETER Config
    The distributed config object from Get-DistributedConfig.
.PARAMETER State
    The build state object (used for logging only).
.OUTPUTS
    PSCustomObject[] (available hosts)
#>
function Get-AvailableHosts {
    [CmdletBinding()]
    param(
        [PSCustomObject]$Config,
        [PSCustomObject]$State
    )
    $available = [System.Collections.ArrayList]@()
    $all = @($Config.hosts)
    if ($all.Count -eq 0) { return @() }
    # Level 5 batched probing: 10+ hosts are probed in bounded batches with
    # progress logging so a large fleet does not stall the pipeline on one
    # slow host. Sequential within a batch (SSH is connection-bound); batches
    # keep log output readable and allow early progress events.
    $batchSize = 8
    try {
        if ($Config.PSObject.Properties.Name -contains 'probeBatchSize' -and [int]$Config.probeBatchSize -gt 0) { $batchSize = [int]$Config.probeBatchSize }
        elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { $batchSize = [int](Get-BuildConstant -Key 'DistributedProbeBatchSize' -State $State -Fallback 8) }
    } catch { $batchSize = 8 }
    if ($batchSize -lt 1) { $batchSize = 1 }
    $total = $all.Count
    for ($i = 0; $i -lt $total; $i += $batchSize) {
        $end = [Math]::Min($i + $batchSize - 1, $total - 1)
        if (($total -gt $batchSize) -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
            Write-Log (Resolve-LogMessage -Key 'log.dist.probingHosts' -MessageArgs @([string]($i + 1), ($end + 1), $total) -Fallback '[DISTRIBUTED] Probing hosts {0}-{1}/{2}...') 'Gray' $State
        }
        for ($j = $i; $j -le $end; $j++) {
            $h = $all[$j]
            if (-not (Test-RemoteHost -TargetHost $h -ConnectTimeout $Config.timeout.connect -State $State -StrictHostKeyChecking $Config.strictHostKeyChecking)) {
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                     Write-Log (Get-LocaleMessage -Key 'log.distributed.hostUnreachable' -MessageArgs $h.name, $h.hostname) 'Warn' $State
                }
                continue
            }
            # A2: certificate gate (soft warning, or hard exclusion when requireCert)
            if (-not (Test-HostCertGate -TargetHost $h -State $State)) {
                continue
            }
            $available.Add($h) | Out-Null
        }
    }
    return @($available)
}

# -- Resolve which host a task should run on -----------------------------------
<#
.SYNOPSIS
    Assigns a task to a host using the configured strategy.
.DESCRIPTION
    For tag-based strategy, matches task tags to host tags and round-robins among
    the matches; if no tag match exists, falls back to plain round-robin across
    all hosts. The round-robin cursor is advanced via the RoundRobinIndex ref.
.PARAMETER Task
    A task object with optional Tags property.
.PARAMETER Hosts
    The candidate host array (already filtered for availability).
.PARAMETER Strategy
    'round-robin' or 'tag-based'.
.PARAMETER RoundRobinIndex
    [ref] integer cursor shared across calls for round-robin rotation.
.OUTPUTS
    PSCustomObject (selected host)
#>
function Resolve-HostAssignment {
    [CmdletBinding()]
    param(
        [PSCustomObject]$Task,
        [PSCustomObject[]]$Hosts,
        [string]$Strategy = 'round-robin',
        [ref]$RoundRobinIndex
    )

    if ($Strategy -eq 'tag-based' -and $Task.Tags -and $Task.Tags.Count -gt 0) {
        $matched = @($Hosts | Where-Object { $_.tags -and ($_.tags | Where-Object { $_ -in $Task.Tags }) })
        if ($matched.Count -gt 0) {
            $idx = $RoundRobinIndex.Value % $matched.Count
            $RoundRobinIndex.Value++
            return $matched[$idx]
        }
    }

    # Fallback: round-robin across all hosts
    $idx = $RoundRobinIndex.Value % $Hosts.Count
    $RoundRobinIndex.Value++
    return $Hosts[$idx]
}

# -- Main: distribute tasks across hosts ---------------------------------------
<#
.SYNOPSIS
    Distributes build tasks across configured remote hosts.
.DESCRIPTION
    Reads distributed config, probes host connectivity, assigns each task to a
    host (round-robin or tag-based), executes them in parallel via a runspace
    pool honoring per-host maxConcurrent, and returns unified results compatible
    with Invoke-ParallelBuild.
.PARAMETER Tasks
    Array of task objects. Each must have Name and Command; Tags is optional.
.PARAMETER State
    The build state object.
.PARAMETER Strategy
    Override the config strategy ('round-robin' | 'tag-based').
.PARAMETER SkipConnectivityCheck
    Skip SSH reachability probing (assume all hosts available).
.OUTPUTS
    PSCustomObject[] (unified results) or $null when disabled.
#>
function Invoke-DistributedBuild {
    [CmdletBinding()]
    param(
        [PSCustomObject[]]$Tasks,
        [PSCustomObject]$State,
        [string]$Strategy,
        [switch]$SkipConnectivityCheck,
        [switch]$Simulation
    )

    $cfg = Get-DistributedConfig -State $State
    if ($Strategy) { $cfg.strategy = $Strategy }

    if (-not $cfg.enabled) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
             Write-Log (Get-LocaleMessage -Key 'log.distributed.disabled') 'Warn' $State
        }
        return $null
    }

    if ($null -eq $Tasks -or $Tasks.Count -eq 0) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
             Write-Log (Get-LocaleMessage -Key 'log.distributed.noTasks') 'Warn' $State
        }
        return @()
    }

    # Simulation mode: return deterministic success placeholders WITHOUT contacting
    # any remote host (docstring contract). Hosts are synthesized directly from the
    # configured entries — no SSH probing, so connectivity failures cannot occur.
    # Used by tests and dry-run CI validation. Must run BEFORE host probing.
    if ($Simulation) {
        $simHosts = @($cfg.hosts)
        if ($simHosts.Count -eq 0) {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                 Write-Log (Get-LocaleMessage -Key 'log.distributed.noHosts') 'Err' $State
            }
            return @()
        }
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.dist.simulationMode' -MessageArgs @([string]$Tasks.Count, $simHosts.Count) -Fallback '[DISTRIBUTED] Simulation mode: {0} tasks across {1} hosts') 'Info' $State
        }
        $sim = [System.Collections.ArrayList]@()
        $rrIdx = [ref]0
        foreach ($task in $Tasks) {
            $th = Resolve-HostAssignment -Task $task -Hosts $simHosts -Strategy $cfg.strategy -RoundRobinIndex $rrIdx
            $sim.Add([PSCustomObject]@{
                Task     = $task.Name
                Host     = $th.name
                Output   = 'SIMULATED'
                Success  = $true
                Error    = $null
                Duration = 0
                ExitCode = 0
            }) | Out-Null
        }
        # Preserve the PSCustomObject[] contract: a single task unrolls to a bare
        # object on return (whose .Count is $null), breaking callers.
        return ,@($sim)
    }

    # Resolve candidate hosts (real path only: probes each host over SSH)
    if ($SkipConnectivityCheck) {
        $hosts = @($cfg.hosts | Where-Object { Test-DistributedHostIdentity -TargetHost $_ })
    }
    else {
        $hosts = Get-AvailableHosts -Config $cfg -State $State
    }
    $hosts = @($hosts | Where-Object { Test-HostCertGate -TargetHost $_ -State $State })
    if ($null -eq $hosts -or $hosts.Count -eq 0) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
             Write-Log (Get-LocaleMessage -Key 'log.distributed.noHosts') 'Err' $State
        }
        return @()
    }

    # distributed.repoRoot had a BuildConstants entry that nothing read while
    # the raw sub-tree was read here, so the key was a mirror nobody used.
    $cfgRepoRoot = [string](Get-BuildConstant -Key 'DistributedRepoRoot' -State $State -Fallback ([string]$cfg.repoRoot))
    if ($cfgRepoRoot -and $cfgRepoRoot -ne [string]$cfg.repoRoot) { $cfg.repoRoot = $cfgRepoRoot }
    if ([string]::IsNullOrWhiteSpace($cfg.repoRoot)) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
             Write-Log (Get-LocaleMessage -Key 'log.distributed.repoRootRequired') 'Err' $State
        }
        return @()
    }

    $results = $null

    try {
        $results = Invoke-WithCircuitBreaker -OperationName 'DistributedBuild' -State $State -Action {
            $results = @()
            # Assign hosts to tasks
            $rrIndex = [ref]0
            $assignments = [System.Collections.ArrayList]@()
            foreach ($task in $Tasks) {
                $targetHost = Resolve-HostAssignment -Task $task -Hosts $hosts -Strategy $cfg.strategy -RoundRobinIndex $rrIndex
                $assignments.Add([PSCustomObject]@{ Task = $task; Host = $targetHost }) | Out-Null
            }

            # Total capacity = sum of per-host maxConcurrent (Level 5: DistributedMinConcurrent floor).
            # Backpressure: capped by DistributedMaxTotalConcurrency so a 10+ host
            # fleet (e.g. 20 x 4 = 80) cannot exhaust runspaces/handles.
            $minConc = 1
            if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                try { $minConc = [int](Get-BuildConstant -Key 'DistributedMinConcurrent' -State $State -Fallback 1) } catch { $minConc = 1 }
            }
            if ($minConc -lt 1) { $minConc = 1 }
            $totalCap = 0
            foreach ($h in $hosts) { $totalCap += if ($h.maxConcurrent) { [int]$h.maxConcurrent } else { $minConc } }
            $totalCap = [Math]::Max($minConc, $totalCap)
            $maxTotal = 64
            try {
                if ($cfg.PSObject.Properties.Name -contains 'maxTotalConcurrency' -and [int]$cfg.maxTotalConcurrency -gt 0) { $maxTotal = [int]$cfg.maxTotalConcurrency }
                elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { $maxTotal = [int](Get-BuildConstant -Key 'DistributedMaxTotalConcurrency' -State $State -Fallback 64) }
            } catch { $maxTotal = 64 }
            if ($maxTotal -lt 1) { $maxTotal = 1 }
            if ($totalCap -gt $maxTotal) {
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log (Resolve-LogMessage -Key 'log.dist.cappingConcurrency' -MessageArgs @([string]$totalCap, $maxTotal, $hosts.Count) -Fallback '[DISTRIBUTED] Capping total concurrency {0} -> {1} (backpressure for {2} hosts)') 'Warn' $State
                }
                $totalCap = $maxTotal
            }
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                try { Send-BuildEvent -EventName $EVT_DISTRIBUTED_DISPATCH -Source $State -Data @{ Tasks = $Tasks.Count; Hosts = $hosts.Count; Concurrency = $totalCap } | Out-Null } catch { }
            }

    # Build the remote execution scriptblock (runs inside the runspace pool).
    # HARD CONSTRAINT: worker runspaces use the DEFAULT session state — NO module
    # functions resolve there (a past revision called Get-ElapsedSeconds /
    # Get-BuildConstant inside this block, so EVERY remote task failed with
    # CommandNotFound even when ssh succeeded). Only language built-ins, static
    # .NET calls and explicitly passed parameters may be used below. Parents
    # resolve module-backed values (e.g. SshDefaultPort) BEFORE the pool.
    $modulePath = [string]$MyInvocation.MyCommand.Path
    $sb = {
        param($HostInfo, $Command, $RepoRoot, $ConnectTimeout, $ExecutionTimeout, $StrictHostKeyChecking, $ModulePath)
        try {
            Import-Module $ModulePath -Force -Global -DisableNameChecking -ErrorAction Stop
            Invoke-RemoteCommand -TargetHost $HostInfo -Command $Command -RepoRoot $RepoRoot -ConnectTimeout $ConnectTimeout -ExecutionTimeout $ExecutionTimeout -StrictHostKeyChecking $StrictHostKeyChecking
        } catch {
            [PSCustomObject]@{ Output = $null; Success = $false; Error = $_.Exception.Message; Duration = 0; ExitCode = -1; TimedOut = $false }
        }
    }

    # Runspace pool (self-contained scriptblock — default session state is enough)
    try {
        $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $totalCap)
        $runspacePool.Open()
    }
    catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.dist.poolFailed' -MessageArgs @([string]$_) -Fallback '[DISTRIBUTED] Failed to create runspace pool: {0}') 'Err' $State
        }
        return @()
    }

    # Per-host running counters
    $hostRunning = @{}
    foreach ($h in $hosts) { $hostRunning[$h.name] = 0 }

    $jobs = [System.Collections.ArrayList]@()
    $homeFallback = if ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }

    try {
        foreach ($a in $assignments) {
            # Level 5: DistributedMinConcurrent floor (distinct from generic MaxRetries).
            $capFloor = 1
            if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                try { $capFloor = [int](Get-BuildConstant -Key 'DistributedMinConcurrent' -State $State -Fallback 1) } catch { $capFloor = 1 }
            }
            if ($capFloor -lt 1) { $capFloor = 1 }
            $cap = if ($a.Host.maxConcurrent) { [int]$a.Host.maxConcurrent } else { $capFloor }

            # Throttle: wait if this host is at capacity
            while ($hostRunning[$a.Host.name] -ge $cap) {
                $pending = $jobs | Where-Object { -not $_.AsyncResult.IsCompleted }
                if ($pending.Count -eq 0) { break }
                $handles = $pending | ForEach-Object { $_.AsyncResult.AsyncWaitHandle }
                [System.Threading.WaitHandle]::WaitAny($handles)
                # Reap completed jobs and free host slots
                foreach ($j in $jobs) {
                    if ($j.AsyncResult.IsCompleted -and -not $j.Reaped) {
                        $j.Reaped = $true
                        $hostRunning[$j.HostName]--
                    }
                }
            }

            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            $null = $ps.AddScript($sb)
            $null = $ps.AddParameter('HostInfo', $a.Host)
            $null = $ps.AddParameter('Command', $a.Task.Command)
            $null = $ps.AddParameter('RepoRoot', $cfg.repoRoot)
            $null = $ps.AddParameter('ConnectTimeout', $cfg.timeout.connect)
            $null = $ps.AddParameter('ExecutionTimeout', $cfg.timeout.execution)
             $null = $ps.AddParameter('StrictHostKeyChecking', $cfg.strictHostKeyChecking)
             $null = $ps.AddParameter('ModulePath', $modulePath)

            $asyncResult = $ps.BeginInvoke()
            $hostRunning[$a.Host.name]++
            $jobs.Add([PSCustomObject]@{
                PowerShell   = $ps
                AsyncResult  = $asyncResult
                TaskName     = $a.Task.Name
                HostName     = $a.Host.name
                StartTime    = Get-Date
                Reaped       = $false
            }) | Out-Null
        }

        $results = [System.Collections.ArrayList]@()
        $waitDeadline = (Get-Date).AddSeconds([Math]::Max(1, [int]$cfg.timeout.execution + [int]$cfg.timeout.connect + 5))
        while ($true) {
            $allDone = $true
            foreach ($j in $jobs) {
                if (-not $j.AsyncResult.IsCompleted) { $allDone = $false; break }
            }
            if ($allDone) { break }
            if ((Get-Date) -ge $waitDeadline) {
                foreach ($j in $jobs) {
                    if (-not $j.AsyncResult.IsCompleted) {
                        $j.TimedOut = $true
                        try { $j.PowerShell.Stop() } catch { }
                    }
                }
                break
            }
            Start-Sleep -Milliseconds ([Math]::Max(20, [int](Get-BuildConstant -Key 'DistributedPollMs' -Fallback 100)))
        }

        # Collect results
        foreach ($j in $jobs) {
            try {
                $r = $j.PowerShell.EndInvoke($j.AsyncResult)
                $results.Add([PSCustomObject]@{
                    Task     = $j.TaskName
                    Host     = $j.HostName
                    Output   = $r.Output
                    Success  = $r.Success
                    Error    = $r.Error
                    Duration = $r.Duration
                    ExitCode = $r.ExitCode
                    TimedOut = [bool]$r.TimedOut
                }) | Out-Null
            }
            catch {
                $timedOut = [bool]$j.TimedOut
                $results.Add([PSCustomObject]@{
                    Task     = $j.TaskName
                    Host     = $j.HostName
                    Output   = $null
                    Success  = $false
                    Error    = if ($timedOut) { 'Remote execution timed out' } else { $_.Exception.Message }
                    Duration = Get-ElapsedSeconds $j.StartTime
                    ExitCode = if ($timedOut) { 124 } else { -1 }
                    TimedOut = $timedOut
                }) | Out-Null
            }
            finally {
                try { $j.PowerShell.Dispose() } catch { # benign — runspace cleanup
                    }
            }
        }

        # Level 5 per-task retry: transient SSH/remote failures (exit -1/255,
        # timeout, connection reset) are retried synchronously up to
        # taskMaxRetries. Large fleets (10+ hosts) see transient blips; without
        # retry a single blip fails the whole dispatch.
        $maxRetry = 2
        try {
            if ($cfg.PSObject.Properties.Name -contains 'taskMaxRetries') { $maxRetry = [int]$cfg.taskMaxRetries }
            elseif (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { $maxRetry = [int](Get-BuildConstant -Key 'DistributedTaskMaxRetries' -State $State -Fallback 2) }
        } catch { $maxRetry = 2 }
        if ($maxRetry -gt 0) {
            $byName = @{}
            foreach ($a in $assignments) { $byName[[string]$a.Task.Name] = $a }
            for ($attempt = 1; $attempt -le $maxRetry; $attempt++) {
                $failedIdx = @()
                for ($k = 0; $k -lt $results.Count; $k++) {
                    if (-not $results[$k].Success) {
                        $errTxt = [string]$results[$k].Error
                         $isTransient = ($results[$k].ExitCode -eq -1 -or $results[$k].ExitCode -eq 255 -or ($results[$k].ExitCode -ne 124 -and $errTxt -match '(?i)(timeout|timed out|connection reset|connection refused|temporarily|transient|broken pipe|no route to host)'))
                        if ($isTransient) { $failedIdx += $k }
                    }
                }
                if ($failedIdx.Count -eq 0) { break }
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log (Resolve-LogMessage -Key 'log.dist.retryingTransient' -MessageArgs @([string]$failedIdx.Count, $attempt, $maxRetry) -Fallback '[DISTRIBUTED] Retrying {0} transient failure(s) (attempt {1}/{2})...') 'Warn' $State
                }
                foreach ($k in $failedIdx) {
                    $tName = [string]$results[$k].Task
                    if (-not $byName.ContainsKey($tName)) { continue }
                    $a = $byName[$tName]
                    try {
                        $rr = Invoke-RemoteCommand -TargetHost $a.Host -Command $a.Task.Command -RepoRoot $cfg.repoRoot -ConnectTimeout $cfg.timeout.connect -State $State -StrictHostKeyChecking $cfg.strictHostKeyChecking -ExecutionTimeout $cfg.timeout.execution
                        $results[$k] = [PSCustomObject]@{
                            Task = $tName; Host = $a.Host.name
                            Output = $rr.Output; Success = [bool]$rr.Success
                             Error = $rr.Error; Duration = [double]$rr.Duration; ExitCode = [int]$rr.ExitCode; TimedOut = [bool]$rr.TimedOut
                        }
                    } catch { }
                }
            }
        }
    }
    finally {
        try { $runspacePool.Close() } catch { # benign — runspace pool cleanup
            }
        try { $runspacePool.Dispose() } catch { # benign — runspace pool cleanup
            }
    }

            # All-failed aggregation: result failures are returned as objects (not
            # exceptions), which the circuit breaker cannot see. When tasks executed
            # AND every one of them failed, raise an aggregated error so
            # Invoke-WithCircuitBreaker records it. Partial success never throws.
            $executed = @($results)
            $failed = @($executed | Where-Object { -not $_.Success })
            if ($executed.Count -gt 0 -and $failed.Count -eq $executed.Count) {
                $firstErrors = @($failed | Select-Object -First 3 | ForEach-Object { "$($_.Task) on $($_.Host): $($_.Error)" })
                throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.distributed.line910' -MessageArgs @([string]$executed.Count, [string]($firstErrors -join '; ')) -Fallback "All $($executed.Count) distributed task(s) failed. First failures: $($firstErrors -join '; ')"))
            }

            # Return collected results to the circuit-breaker caller
            return $results
        }   # end Invoke-WithCircuitBreaker -Action
    }
    catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
             Write-Log (Get-LocaleMessage -Key 'log.distributed.aborted' -MessageArgs $_.Exception.Message) 'Err' $State
        }
        return $null
    }

    # Report summary
    $successCount = @($results | Where-Object { $_.Success }).Count
    $failCount = @($results | Where-Object { -not $_.Success }).Count
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
         Write-Log (Get-LocaleMessage -Key 'log.distributed.completed' -MessageArgs $successCount, $failCount, $hosts.Count) 'Info' $State
    }

    # Result aggregation dashboard (Sprint 3-Q7): emit JSON + Markdown reports
    $report = New-DistributedReport -Results $results -State $State -Config $cfg
    if ($report) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.dist.reportWritten' -MessageArgs @([string]$report.MarkdownPath) -Fallback '[DISTRIBUTED] Report written: {0}') 'Info' $State
        }
    }

    # Preserve the PSCustomObject[] contract (see simulation path above).
    return ,@($results)
}
function Resolve-DistributedReportRoot {
    param([PSCustomObject]$State, [PSCustomObject]$Config)
    try {
        # Root precedence CORRECTED. This preferred ScriptRoot over ProjectRoot,
        # so a distributed run with both set wrote its report inside the _Build
        # tool directory instead of the user's project. PathUtils.Get-BuildRootDirectory
        # is the single source for that decision (ProjectRoot > ScriptRoot).
        $hasPathUtils = Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue
        $base = if ($hasPathUtils) { Get-BuildRootDirectory -State $State }
                elseif ($State -and $State.ProjectRoot) { [string]$State.ProjectRoot }
                elseif ($State -and $State.ScriptRoot) { [string]$State.ScriptRoot }
                else { (Get-Location).ProviderPath }
        $base = ([System.IO.Path]::GetFullPath($base)).TrimEnd('\', '/')
        $defaultReportLeaf = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { [string](Get-BuildConstant -Key 'DistributedReportPath' -State $State -Fallback 'distributed-report') } catch { 'distributed-report' }
        } else { 'distributed-report' }
        $relative = if ($Config -and $Config.reportPath) { [string]$Config.reportPath } else { $defaultReportLeaf }
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative -match '[\x00-\x1f\x7f]') { $relative = $defaultReportLeaf }
        $candidate = if ([System.IO.Path]::IsPathRooted($relative)) { [System.IO.Path]::GetFullPath($relative) } else { [System.IO.Path]::GetFullPath((Join-Path $base $relative)) }
        if ($hasPathUtils) {
            # Test-PathUnderRoots also accepts the base itself; the report must be
            # INSIDE it, so an exact match falls back to the default subdirectory.
            if (-not (Test-PathUnderRoots -Path $candidate -AllowedRoots @($base)) -or $candidate -eq $base) {
                $candidate = [System.IO.Path]::GetFullPath((Join-Path $base $defaultReportLeaf))
            }
            if (-not (Test-NoReparsePointInPath -Path $candidate)) { return '' }
            return $candidate
        }
        # Fail closed - see the note in Android.psm1. The canonical containment
        # + reparse rule lives in PathUtils only; this used to reimplement it.
        return ''
    } catch { return '' }
}

<#
.SYNOPSIS
    Aggregates distributed build results into a JSON + Markdown dashboard.
.DESCRIPTION
    Produces a unified summary across all hosts: per-task outcome, per-host
    rollup, totals, and durations. Writes report files under the configured
    distributed.reportPath (default: <ScriptRoot>/distributed-report) using only
    config-driven / relative paths (no hardcode). Returns a PSCustomObject with
    the aggregated data and the report file paths.
.PARAMETER Results
    The unified result array from Invoke-DistributedBuild.
.PARAMETER State
    The build state object (used for ScriptRoot + logging).
.PARAMETER Config
    The resolved distributed config (used for reportPath + repoRoot).
.OUTPUTS
    PSCustomObject with Summary, JsonPath, MarkdownPath.
#>
function New-DistributedReport {
    [CmdletBinding()]
    param(
        [PSCustomObject[]]$Results,
        [PSCustomObject]$State,
        [PSCustomObject]$Config
    )

    if ($null -eq $Results) { $Results = @() }

    $reportPath = Resolve-DistributedReportRoot -State $State -Config $Config
    if (-not $reportPath) { return $null }

    $success = @($Results | Where-Object { $_.Success }).Count
    $failed  = @($Results | Where-Object { -not $_.Success }).Count
    $totalDuration = [math]::Round((($Results | ForEach-Object { if ($_.Duration) { $_.Duration } else { 0 } } | Measure-Object -Sum).Sum), 2)

    # Per-host rollup (keyed by host name, aggregated dynamically)
    $byHost = @{}
    foreach ($r in $Results) {
        $h = if ($r.Host) { $r.Host } else { '(unknown)' }
        if (-not $byHost.ContainsKey($h)) {
            $byHost[$h] = [PSCustomObject]@{ Host = $h; Total = 0; Success = 0; Failed = 0; Duration = 0 }
        }
        $byHost[$h].Total++
        if ($r.Success) { $byHost[$h].Success++ } else { $byHost[$h].Failed++ }
        $byHost[$h].Duration = [math]::Round($byHost[$h].Duration + $(if ($r.Duration) { $r.Duration } else { 0 }), 2)
    }

    $summary = [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToString('o')
        Total       = $Results.Count
        Success     = $success
        Failed      = $failed
        TotalDurationSeconds = $totalDuration
        Hosts       = @($byHost.Values)
        Tasks       = @($Results | ForEach-Object {
            [PSCustomObject]@{
                Task     = $_.Task
                Host     = $_.Host
                Success  = $_.Success
                Duration = if ($_.Duration) { [math]::Round($_.Duration, 2) } else { 0 }
                Error    = if (-not $_.Success) { $_.Error } else { $null }
            }
        })
    }

    try {
        $jsonPath = Join-Path $reportPath 'distributed-report.json'
        $mdPath   = Join-Path $reportPath 'distributed-report.md'
        # JSON write single-sourced via SharedUtils.Write-BuildJsonFile.
        if (-not (Write-BuildJsonFile -Path $jsonPath -Data $summary -Depth 6)) { throw (Resolve-LogMessage -Key 'log.distributed.line1045' -MessageArgs @([string]$jsonPath) -Fallback "failed writing $jsonPath") }

        $sb = New-Object System.Text.StringBuilder
        $null = $sb.AppendLine('# Distributed Build Report')
        $null = $sb.AppendLine()
        $null = $sb.AppendLine("Generated: $($summary.GeneratedAt)")
        $null = $sb.AppendLine()
        $null = $sb.AppendLine("## Totals")
        $null = $sb.AppendLine()
        $null = $sb.AppendLine("- Tasks: $($summary.Total)")
        $null = $sb.AppendLine("- Success: $($summary.Success)")
        $null = $sb.AppendLine("- Failed: $($summary.Failed)")
        $null = $sb.AppendLine("- Total duration: $($summary.TotalDurationSeconds)s")
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('## By Host')
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('| Host | Total | Success | Failed | Duration (s) |')
        $null = $sb.AppendLine('|------|-------|---------|--------|-------------|')
        foreach ($h in $summary.Hosts) {
            $null = $sb.AppendLine("| $($h.Host) | $($h.Total) | $($h.Success) | $($h.Failed) | $($h.Duration) |")
        }
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('## Tasks')
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('| Task | Host | Success | Duration (s) | Error |')
        $null = $sb.AppendLine('|------|------|---------|-------------|-------|')
        foreach ($t in $summary.Tasks) {
            $err = if ($t.Error) { ($t.Error | Out-String).Trim().Replace("`n", ' ').Replace('|', '\|') } else { '' }
            $null = $sb.AppendLine("| $($t.Task) | $($t.Host) | $($t.Success) | $($t.Duration) | $err |")
        }
        [System.IO.File]::WriteAllText($mdPath, ($sb.ToString() + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))

        return [PSCustomObject]@{
            Summary     = $summary
            JsonPath    = $jsonPath
            MarkdownPath = $mdPath
        }
    }
    catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Resolve-LogMessage -Key 'log.dist.reportFailed' -MessageArgs @([string]$_) -Fallback '[DISTRIBUTED] Failed to write report: {0}') 'Warn' $State
        }
        return $null
    }
}

Export-ModuleMember -Function @(
    'Get-DistributedConfig',
    'Get-DistributedSshPort',
    'Test-RemoteHost',
    'Invoke-RemoteCommand',
    'Get-AvailableHosts',
    'Test-HostCertGate',
    'Resolve-HostAssignment',
    'Invoke-DistributedBuild',
    'Test-RemoteHostCertificate',
    'New-DistributedReport'
)






