# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================



# ModuleBootstrap.ps1 self-loads BuildImport.psm1 (defines Import-GBuildModule /
# Import-BuildDependencies) before resolving -Dependencies.

. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()
Import-GBuildModuleIfMissing -Name 'BuildConstants' -SentinelCommand 'Get-BuildTimestamp'

# ==================================================================================================
# Modules/DeployTargets.psm1 (Deployment targets: Azure / AWS / Vercel)
# ==================================================================================================
#
# Provides publish-artifacts to cloud targets. All of them:
#   - Guarded by Get-Command (CLI must be installed & logged in beforehand)
#   - Read endpoint/name from $State.BuildConfig.deploy.* (no hardcoded secret)
#   - Only run when the corresponding publish-output exists
# ==================================================================================================
Import-BuildModule -Dependencies @('Project', 'Deploy', 'EventBus', 'SharedUtils')
# Locale for i18n log messages (log.dt.*) — sentinel keeps standalone imports safe
Import-GBuildModuleIfMissing -Name 'Locale' -SentinelCommand 'Get-LocaleMessage'

# ── Deploy-target plugin registry (extensibility) ─────────────────────────────
# Each deploy target self-registers with: name, the invoke function, its config
# section key, and required fields. New targets can be added via Register-DeployTarget
# without editing the core dispatch (Invoke-DeployTarget resolves by name).
$script:DeployTargetRegistry = [System.Collections.Hashtable]::Synchronized(@{})

<#
.SYNOPSIS
    Resolves a deploy-target path, refusing escapes, junctions and (optionally) non-directories.
.DESCRIPTION
    Delegates containment to PathUtils.Test-PathUnderRoots and the reparse/junction
    walk to PathUtils.Test-NoReparsePointInPath. The private copies this replaced
    drifted: their reparse walk stopped BEFORE the volume root (a SUBST drive or a
    mapped network share passed) and they used Get-Item -ErrorAction Stop, so an
    unreadable intermediate directory turned a valid path into ''. This function
    sits on the deploy/publish path, where that inconsistency matters most.
#>
function Resolve-DeployContainedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State, [string]$Path, [switch]$RequireDirectory)

Set-StrictMode -Version 1.0
    # Delegates to PathUtils.Resolve-BuildContainedPath. This was the third
    # copy of the wrapper (with Deploy.Resolve-DeployStatePath and
    # Android.Resolve-AndroidContainedPath); all three already delegated the
    # containment and reparse guards to PathUtils, so what differed between them
    # was only the fail-closed plumbing - exactly the part that had drifted once.
    if (-not (Get-Command Resolve-BuildContainedPath -ErrorAction SilentlyContinue)) {
        $pathUtilsPath = Join-Path $PSScriptRoot 'PathUtils.psm1'
        if (Test-Path -LiteralPath $pathUtilsPath -PathType Leaf) {
            $null = Import-Module $pathUtilsPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    return (Resolve-BuildContainedPath -Path $Path -State $State -RequireDirectory:$RequireDirectory)
}

function Test-DeployToken {
    param([string]$Value, [int]$MaxLength = 128)
    return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value.Length -le $MaxLength -and $Value -notmatch '[\x00-\x1f\x7f;|]')
}

function Invoke-DeployTool {
    [CmdletBinding()]
    param([string]$Name, [string[]]$Arguments)
    $result = [PSCustomObject]@{ Output = ''; ExitCode = 127; Success = $false }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { return $result }
    try {
        $before = $null
        $variable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
        if ($variable) { $before = $variable.Value }
        if ($command.CommandType -eq 'Application') {
            $toolPath = if ($command.Path) { [string]$command.Path } else { [string]$command.Source }
            if (-not $toolPath) { return $result }
            $output = & $toolPath @Arguments 2>&1
        } else {
            $output = & $Name @Arguments 2>&1
        }
        $after = $null
        $variable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
        if ($variable) { $after = $variable.Value }
        $exit = if ($null -ne $after -and ($after -is [int])) { [int]$after } else { 0 }
        if ($command.CommandType -ne 'Application' -and $null -ne $before -and $exit -eq [int]$before -and $null -eq $output) { $exit = 0 }
        $result.Output = ($output | Out-String)
        $result.ExitCode = [int]$exit
        $result.Success = ([int]$exit -eq 0)
        return $result
    } catch {
        $result.Output = $_.Exception.Message
        return $result
    }
}

function Register-DeployTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [Parameter(Mandatory=$true)] [string]$Function,
        [string]$ConfigKey,
        [string[]]$RequiredFields = @()
    )
    $script:DeployTargetRegistry[$Name] = [PSCustomObject]@{
        Name           = $Name
        Function       = $Function
        ConfigKey      = if ($ConfigKey) { $ConfigKey } else { $Name }
        RequiredFields = $RequiredFields
    }
}

function Get-DeployTarget {
    [CmdletBinding()]
    param([string]$Name)
    if ($Name) { return $script:DeployTargetRegistry[$Name] }
    return @($script:DeployTargetRegistry.Values)
}

# ── Deploy Lock (serialize concurrent deploys of same target) ───────────────────
# Named-semaphore based on Windows (not Monitor): same-thread re-entry must
# BLOCK so the DeployOrchestration.Tests concurrent-acquisition contract holds,
# and the lock also serializes across processes (parallel pwsh hosts deploying
# the same target). POSIX uses SharedUtils.Enter-BuildFileLock because named
# semaphores are unsupported there; flock gives the same cross-process
# exclusion.
$script:DeployLocks = [System.Collections.Hashtable]::Synchronized(@{})

<#
.SYNOPSIS
    Acquires a named deploy lock (one deploy per target at a time).
.PARAMETER LockName
    Target name (e.g. 'azure').
.PARAMETER TimeoutMs
    Wait budget in milliseconds. Returns $false on timeout instead of throwing.
.PARAMETER TimeoutSec
    Alias-style alternative (seconds). Used only when TimeoutMs is not bound.
#>
function Enter-DeployLock {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory=$true)] [string]$LockName,
        [int]$TimeoutMs = 30000,
        [int]$TimeoutSec = -1
    )
    if ($PSBoundParameters.ContainsKey('TimeoutSec') -and -not $PSBoundParameters.ContainsKey('TimeoutMs')) {
        $TimeoutMs = $TimeoutSec * 1000
    } elseif (-not $PSBoundParameters.ContainsKey('TimeoutMs') -and -not $PSBoundParameters.ContainsKey('TimeoutSec')) {
        try {
            if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                $TimeoutMs = [int](Get-BuildConstant -Key 'DeployTimeoutMs' -Fallback 30000)
            }
        } catch { $TimeoutMs = 30000 }
    }
    # Named semaphores are Windows-only: on Linux/macOS the 4-arg Semaphore
    # constructor throws PlatformNotSupportedException, so every deploy lock
    # acquisition returned $false and Invoke-DeployTarget failed closed before
    # ever invoking a target. POSIX hosts get the same cross-process guarantee
    # from SharedUtils.Enter-BuildFileLock (FileShare.None -> flock), which is
    # the single file-lock primitive in the tree. Both handles implement
    # Dispose(); only the semaphore needs an explicit Release().
    if ([System.IO.Path]::DirectorySeparatorChar -ne '\') {
        Initialize-BuildSharedUtils -SentinelCommand 'Enter-BuildFileLock'
        if (-not (Get-Command Enter-BuildFileLock -ErrorAction SilentlyContinue)) { return $false }
        $safeName = [regex]::Replace($LockName, '[^A-Za-z0-9._-]', '_')
        if ($safeName.Length -gt 80) { $safeName = $safeName.Substring(0, 80) }
        $lockDir = Join-Path ([System.IO.Path]::GetTempPath()) 'gbuild-deploy-locks'
        $lock = Enter-BuildFileLock -Path (Join-Path $lockDir ('deploy-' + $safeName)) -TimeoutMs $TimeoutMs
        if ($lock) {
            $script:DeployLocks[$LockName] = $lock
            return $true
        }
        return $false
    }
    $semName = "gbuild_deploy_$LockName"
    try {
        # OpenExisting first so a second acquisition on the SAME host blocks
        # instead of creating an independent semaphore.
        $sem = $null
        try { $sem = [System.Threading.Semaphore]::OpenExisting($semName) }
        catch { $sem = $null }
        if (-not $sem) {
            $created = $false
            $sem = New-Object System.Threading.Semaphore(1, 1, $semName, ([ref]$created))
        }
        $acquired = $sem.WaitOne($TimeoutMs)
        if ($acquired) {
            $script:DeployLocks[$LockName] = $sem
            return $true
        }
        try { $sem.Dispose() } catch { }
        return $false
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Releases a named deploy lock acquired by Enter-DeployLock.
#>
function Exit-DeployLock {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)] [string]$LockName)
    if ($script:DeployLocks.ContainsKey($LockName)) {
        $lock = $script:DeployLocks[$LockName]
        try {
            if ($lock -is [System.Threading.Semaphore]) { $lock.Release() | Out-Null }
        } catch { # benign - already released
        }
        try { $lock.Dispose() } catch { }
        $script:DeployLocks.Remove($LockName) | Out-Null
    }
}

function Invoke-DeployTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [PSCustomObject]$State,
        [switch]$DryRun,
        [string]$ProjectDir = '',
        [string]$ProjectType = '',
        [switch]$Detailed
    )
    $operation = "deploy:$Name"
    $t = $script:DeployTargetRegistry[$Name]
    if (-not $t) {
        $message = "[DEPLOY] Unknown deploy target '$Name' (not registered)"
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Get-LocaleMessage -Key 'log.dt.unknown' -MessageArgs @([string]$Name) -Fallback $message) 'Err' $State
        }
        if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
            Write-AuditLog -Action "deploy:$Name" -Outcome 'Failed' -State $State -Detail $message | Out-Null
        }
        $result = New-OperationResult -Status Blocked -Operation $operation -ReasonCode 'TargetNotFound' -Message $message -ExitCode 127
        if ($Detailed) { return $result }
        return $false
    }
    $fn = Get-Command $t.Function -ErrorAction SilentlyContinue
    if (-not $fn) {
        $message = "[DEPLOY] Deploy target '$Name' function '$($t.Function)' not found"
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Get-LocaleMessage -Key 'log.dt.fnNotFound' -MessageArgs @([string]$Name, [string]$t.Function) -Fallback $message) 'Err' $State
        }
        if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
            Write-AuditLog -Action "deploy:$Name" -Outcome 'Failed' -State $State -Detail $message | Out-Null
        }
        $result = New-OperationResult -Status Blocked -Operation $operation -ReasonCode 'CommandNotFound' -Message $message -ExitCode 127
        if ($Detailed) { return $result }
        return $false
    }
    $cfg = Get-DeployConfig -State $State -Target $t.ConfigKey
    if ($t.RequiredFields -and $t.RequiredFields.Count -gt 0) {
        $missing = @($t.RequiredFields | Where-Object { -not ($cfg -and $cfg.$_) })
        if ($missing.Count -gt 0) {
            $message = "[DEPLOY] Target '$Name' missing required config: $($missing -join ', ')"
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Get-LocaleMessage -Key 'log.dt.cfgMissing' -MessageArgs @([string]$Name, ($missing -join ', ')) -Fallback $message) 'Err' $State
            }
            if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
                Write-AuditLog -Action "deploy:$Name" -Outcome 'Failed' -State $State -Detail $message | Out-Null
            }
            $result = New-OperationResult -Status Blocked -Operation $operation -ReasonCode 'ConfigMissing' -Message $message -ExitCode 2
            if ($Detailed) { return $result }
            return $false
        }
    }
    if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
        Send-BuildEvent -EventName $EVT_DEPLOY_START -Source $State -Data @{ Target = $Name; DryRun = $DryRun.IsPresent } | Out-Null
    }
    if ($DryRun) {
        $message = "[DEPLOY] DRY-RUN target '$Name' validated (function '$($t.Function)' would run)"
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Get-LocaleMessage -Key 'log.dt.dryRun' -MessageArgs @([string]$Name, [string]$t.Function) -Fallback $message) 'Info' $State
        }
        if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
            Write-AuditLog -Action "deploy:$Name" -Outcome 'DryRun' -State $State | Out-Null
        }
        $result = New-OperationResult -Status Succeeded -Operation $operation -ReasonCode 'DryRun' -Message $message
        if ($Detailed) { return $result }
        return $true
    }
    try {
        $lockAcquired = $true
        if (Get-Command Enter-DeployLock -ErrorAction SilentlyContinue) {
            $lockAcquired = Enter-DeployLock -LockName $Name
        }
        if (-not $lockAcquired) {
            $message = Get-LocaleMessage -Key 'log.dt.lockHeld' -MessageArgs $Name
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log $message 'Warn' $State
            }
            if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
                Write-AuditLog -Action "deploy:$Name" -Outcome 'Failed' -State $State -Detail $message | Out-Null
            }
            $result = New-OperationResult -Status Blocked -Operation $operation -ReasonCode 'LockUnavailable' -Message $message -ExitCode 75
            if ($Detailed) { return $result }
            return $false
        }
        try {
            $invokeParams = @{}
            if ($fn.Parameters.ContainsKey('State')) { $invokeParams['State'] = $State }
            if ($fn.Parameters.ContainsKey('ProjectDir')) { $invokeParams['ProjectDir'] = $ProjectDir }
            if ($fn.Parameters.ContainsKey('ProjectType')) { $invokeParams['ProjectType'] = $ProjectType }
            $rawResult = & $fn @invokeParams
            $result = ConvertTo-OperationResult -Value $rawResult -Operation $operation
            if ($result.Status -ne 'Succeeded') {
                $failureMessage = if ($result.Message) { $result.Message } else { "Deploy target '$Name' failed" }
                if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                    Send-BuildEvent -EventName $EVT_DEPLOY_ERROR -Source $State -Data @{ Target = $Name; Error = $failureMessage } | Out-Null
                }
                if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
                    Write-AuditLog -Action "deploy:$Name" -Outcome 'Failed' -State $State -Detail $failureMessage | Out-Null
                }
                if ($Detailed) { return $result }
                return $false
            }
            if (Get-Command Invoke-GpgSign -ErrorAction SilentlyContinue) {
                $signResult = Invoke-GpgSign -State $State
                if (-not $signResult) {
                    $result = New-OperationResult -Status Failed -Operation $operation -ReasonCode 'SigningFailed' -Message 'Artifact signing failed' -ExitCode 1
                    if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) { Write-AuditLog -Action "deploy:$Name" -Outcome 'Failed' -State $State -Detail 'Artifact signing failed' | Out-Null }
                    if ($Detailed) { return $result }
                    return $false
                }
            }
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                Send-BuildEvent -EventName $EVT_DEPLOY_COMPLETE -Source $State -Data @{ Target = $Name; Success = $true } | Out-Null
            }
            if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
                Write-AuditLog -Action "deploy:$Name" -Outcome 'Completed' -State $State | Out-Null
            }
            if ($Detailed) { return $result }
            return $true
        }
        finally {
            if (Get-Command Exit-DeployLock -ErrorAction SilentlyContinue) { Exit-DeployLock -LockName $Name }
        }
    }
    catch {
        $message = $_.Exception.Message
        if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
            Send-BuildEvent -EventName $EVT_DEPLOY_ERROR -Source $State -Data @{ Target = $Name; Error = $message } | Out-Null
        }
        if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
            Write-AuditLog -Action "deploy:$Name" -Outcome 'Failed' -State $State -Detail $message | Out-Null
        }
        $result = New-OperationResult -Status Failed -Operation $operation -ReasonCode 'Exception' -Message $message -ExitCode 1
        if ($Detailed) { return $result }
        return $false
    }
}

# Register built-in deploy targets (config-key + required fields kept in sync
# with the built-in map used by Test-DeployTargets).
Register-DeployTarget -Name 'azure'          -Function 'Invoke-DeployAzure'          -ConfigKey 'azure'          -RequiredFields @('resourceGroup','appName')
Register-DeployTarget -Name 'aws'            -Function 'Invoke-DeployAws'            -ConfigKey 'aws'            -RequiredFields @('bucket')
Register-DeployTarget -Name 'vercel'         -Function 'Invoke-DeployVercel'         -ConfigKey 'vercel'         -RequiredFields @('project')
Register-DeployTarget -Name 'gcp'            -Function 'Invoke-DeployGcp'            -ConfigKey 'gcp'            -RequiredFields @('project','service')
Register-DeployTarget -Name 'kubernetes'     -Function 'Invoke-DeployK8s'            -ConfigKey 'kubernetes'     -RequiredFields @('manifest')
Register-DeployTarget -Name 'azureFunctions' -Function 'Invoke-DeployAzureFunctions' -ConfigKey 'azureFunctions' -RequiredFields @('resourceGroup','appName')
# awsLambda: zipFile is intentionally NOT a config requirement — the zip is
# generated from the publish output at deploy time (Invoke-DeployAwsLambda).
Register-DeployTarget -Name 'awsLambda'      -Function 'Invoke-DeployAwsLambda'      -ConfigKey 'awsLambda'      -RequiredFields @('functionName')
Register-DeployTarget -Name 'dockerCi'       -Function 'Invoke-DockerCiDeploy'       -ConfigKey 'docker'         -RequiredFields @()
Register-DeployTarget -Name 'azurePipeline'  -Function 'Invoke-AzurePipelineTrigger' -ConfigKey 'azurePipeline'  -RequiredFields @()

function Get-DeployConfig {
    param([PSCustomObject]$State, [string]$Target)
    $tenant = if ($State -and $State.PSObject.Properties.Name -contains 'TenantId' -and $State.TenantId) { [string]$State.TenantId } else { 'default' }
    if ($tenant -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $tenant -eq '.' -or $tenant -eq '..') { return $null }
    if ($State -and $State.BuildConfig -and $State.BuildConfig.deploy) {
        $deploy = $State.BuildConfig.deploy
        if ($tenant -ne 'default' -and $deploy.PSObject.Properties.Name -contains 'tenants' -and $deploy.tenants.PSObject.Properties.Name -contains $tenant -and $deploy.tenants.$($tenant).PSObject.Properties.Name -contains $Target) {
            return $deploy.tenants.$($tenant).$Target
        }
        if ($deploy.PSObject.Properties.Name -contains $Target) {
            return $deploy.$Target
        }
    }
    return $null
}

<#
.SYNOPSIS
    Shared deploy-target preflight: CLI present + required config keys + optional
    publish/working-directory existence. Returns $true when ready, $false otherwise.
.DESCRIPTION
    Single implementation of the 3-guard skeleton that was duplicated across the
    Invoke-Deploy* functions. All messages route through the localized log.dt.*
    keys (fixes the drift where only the az targets used log.dt.toolMissing while
    aws/gcloud/kubectl/vercel used raw English strings).
#>
function Assert-DeployPrerequisite {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$ToolLabel,
        # Config section name used in the missing-key message (e.g. 'azure', 'ci.azure').
        [Parameter(Mandatory)][string]$Target,
        # Config section object (PSCustomObject or hashtable); $null allowed (fail on keys).
        [AllowNull()][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RequiredKeys,
        # Optional directory existence check (publish/working dir).
        [string]$WorkDir = '',
        # Custom message when WorkDir is missing (defaults to a generic one).
        [string]$WorkDirMissingMessage = ''
    )
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        Write-Log (Get-LocaleMessage -Key 'log.dt.toolMissing' -MessageArgs @($ToolLabel) -Fallback "$ToolLabel not found. Install + authenticate first.") 'Warn' $State
        return $false
    }
    $missing = @()
    foreach ($k in $RequiredKeys) {
        $v = Get-SectionValue -Section $Config -Key $k -Default $null
        if (-not $v) { $missing += $k }
    }
    if ($missing.Count -gt 0) {
        Write-Log (Get-LocaleMessage -Key 'log.dt.cfgMissing' -MessageArgs @($Target, ($missing -join ' & ')) -Fallback "deploy.$Target requires $($missing -join ' & ') in gbuild.config.json") 'Warn' $State
        return $false
    }
    if ($WorkDir -and -not (Test-Path $WorkDir)) {
        $msg = if ($WorkDirMissingMessage) { $WorkDirMissingMessage } else { Get-LocaleMessage -Key 'log.dt.publishDirNotFound' -MessageArgs $WorkDir }
        Write-Log $msg 'Warn' $State
        return $false
    }
    return $true
}

<#
.SYNOPSIS
    Asserts the Web publish output exists (Level 5 DRY).
.DESCRIPTION
    Single implementation of the `noWebOutput` guard that was inlined in
    Invoke-DeployAzure/Aws/Vercel (100% identical). Returns the publish dir
    when present, '' otherwise (already logged).
#>
function Assert-WebPublishOutput {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][PSCustomObject]$State)
    $root = Get-DeployPublishOutputDir -State $State
    if (-not $root) { return '' }
    $publishOut = Resolve-DeployContainedPath -State $State -Path ((Join-Path $root 'web'))
    if (-not $publishOut -or -not (Test-Path -LiteralPath $publishOut -PathType Container)) {
        Write-Log (Get-LocaleMessage -Key 'log.dt.noWebOutput' -Fallback 'No Web publish output. Build Web (choice 7) first.') 'Warn' $State
        return ''
    }
    return $publishOut
}

function Invoke-DeployAzure {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectType)
    $cfg = Get-DeployConfig -State $State -Target 'azure'
    if (-not (Test-DeployToken -Value ([string]$cfg.resourceGroup) -MaxLength 128) -or -not (Test-DeployToken -Value ([string]$cfg.appName) -MaxLength 128) -or [string]$cfg.resourceGroup -notmatch '^[A-Za-z0-9._-]+$' -or [string]$cfg.appName -notmatch '^[A-Za-z0-9._-]+$') { return $false }
    if (-not (Assert-DeployPrerequisite -State $State -Tool 'az' -ToolLabel 'Azure CLI (az)' -Target 'azure' -Config $cfg -RequiredKeys @('resourceGroup','appName'))) { return $false }
    $publishOut = Assert-WebPublishOutput -State $State
    if (-not $publishOut) { return $false }

    Write-Log (Get-LocaleMessage -Key 'log.dt.deployingTo' -MessageArgs @("Azure App Service $($cfg.appName)") -Fallback "Deploying to Azure App Service $($cfg.appName)...") 'Info' $State
    $zip = Join-Path $publishOut 'deploy.zip'
    if (Get-Command Compress-Archive -ErrorAction SilentlyContinue) {
        Compress-Archive -Path (Join-Path $publishOut '*') -DestinationPath $zip -Force
    }
    if (Test-Path $zip) {
        & az webapp deployment source config-zip -g $cfg.resourceGroup -n $cfg.appName --src $zip 2>&1 | Out-Host
    } else {
        & az webapp up -g $cfg.resourceGroup -n $cfg.appName --plan $cfg.plan --location $cfg.location 2>&1 | Out-Host
    }
    return ($LASTEXITCODE -eq 0)
}

function Invoke-DeployAws {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectType)
    $cfg = Get-DeployConfig -State $State -Target 'aws'
    $bucketName = [string]$cfg.bucket
    $prefixName = [string]$cfg.prefix
    if ($bucketName -notmatch '^[a-z0-9][a-z0-9.-]{0,62}$' -or ($prefixName -and ($prefixName -match '[\x00-\x1f\x7f\s;|]' -or $prefixName -match '(^|/)\.\.(/|$)'))) { return $false }
    if (-not (Assert-DeployPrerequisite -State $State -Tool 'aws' -ToolLabel 'AWS CLI (aws)' -Target 'aws' -Config $cfg -RequiredKeys @('bucket'))) { return $false }
    $publishOut = Assert-WebPublishOutput -State $State
    if (-not $publishOut) { return $false }

    Write-Log (Get-LocaleMessage -Key 'log.dt.deployingTo' -MessageArgs @("AWS S3 s3://$($cfg.bucket)") -Fallback "Deploying to AWS S3 s3://$($cfg.bucket)...") 'Info' $State
    & aws s3 sync $publishOut ("s3://" + $cfg.bucket + $(if ($cfg.prefix) { '/' + $cfg.prefix } else { '' })) --delete 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0 -and $cfg.distributionId) {
        & aws cloudfront create-invalidation --distribution-id $cfg.distributionId --paths '/*' 2>&1 | Out-Host
    }
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
    Digitally signs published artifacts with GPG (detached .asc signatures).
.DESCRIPTION
    Config-driven (`security.gpgSign.enabled`). Invokes the standalone
    `Steps/sign-gpg.ps1` helper to produce detached armored signatures for the
    build outputs (exe/dll/zip). Fails silently when gnupg is not installed so it
    never breaks a build. Wire this after a successful publish/deploy.
.PARAMETER State
    The build state (reads BuildConfig.security.gpgSign).
.PARAMETER Path
    File or directory of artifacts to sign. Defaults to the publish-output dir.
#>
function Invoke-GpgSign {
    # Signs published/deploy artifacts with GPG (detached .asc signatures).
    # Config-driven: security.gpgSign may be a boolean (enabled flag) or an
    # object ({ enabled, keyId }). Invokes the standalone Steps/sign-gpg.ps1
    # helper to produce detached armored signatures for the build outputs
    # (exe/dll/zip). Fails silently when gnupg is not installed so it never
    # breaks a build. Called after deploy (see Invoke-DeployTarget) and after a
    # successful build (see Orchestrator Start-GBuild finally block).
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Path)
    $raw = if ($State -and $State.BuildConfig -and $State.BuildConfig.security -and $State.BuildConfig.security.gpgSign) { $State.BuildConfig.security.gpgSign } else { $null }
    if ($null -eq $raw) { return $true }
    # Tolerate both shapes: boolean shorthand and object ({ enabled, keyId }).
    $enabled = $false; $keyId = ''
    if ($raw -is [bool]) { $enabled = $raw }
    elseif ($raw -is [System.Management.Automation.PSCustomObject] -or $raw -is [hashtable]) { $enabled = [bool]$raw.enabled; $keyId = [string]$raw.keyId }
    else { $enabled = $true }
    if (-not $enabled) { return $true }
    if (-not $Path) { $Path = Get-DeployPublishOutputDir -State $State }
    if (-not (Test-Path $Path)) { Write-Log (Resolve-LogMessage -Key 'log.sign.noArtifacts' -Fallback '[SIGN] No artifacts to sign.') 'Warn' $State; return $true }
    $step = Join-Path $PSScriptRoot '../Steps/sign-gpg.ps1'
    if (-not (Test-Path -LiteralPath $step -PathType Leaf)) { Write-Log (Resolve-LogMessage -Key 'log.sign.stepNotFound' -Fallback '[SIGN] sign-gpg.ps1 step not found.') 'Err' $State; return $false }
    if ($keyId) { $keyArg = @('-KeyId', $keyId) } else { $keyArg = @() }
    # Resolve the signer host dynamically via SharedUtils.Resolve-PowerShellHost
    # (pwsh-first, powershell legacy fallback). Verified: Steps/sign-gpg.ps1
    # contains no pwsh-only syntax, so either host can run it. With NO host at
    # all, fail loudly ($false) instead of silently reporting success.
    $signer = $null
    # SharedUtils.Resolve-PowerShellHost is the single source for the
    # pwsh-then-powershell preference order. This block used to re-probe the
    # same candidate list a third time, so the preference order existed in two
    # places and could disagree.
    if (Get-Command Resolve-PowerShellHost -ErrorAction SilentlyContinue) {
        try {
            $signerName = Resolve-PowerShellHost
            if ($signerName) { $signer = Get-Command $signerName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
        } catch { $signer = $null }
    }
    if (-not $signer) { $signer = Get-Command 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $signer) {
        Write-Log (Get-LocaleMessage -Key 'log.deploy.signNoHost') 'Err' $State
        return $false
    }
    try {
        & $signer.Source -NoProfile -File $step -Path $Path -DetachSign @keyArg 2>&1 | Out-Host
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
            Write-Log (Get-LocaleMessage -Key 'log.deploy.signExitCode' -MessageArgs @([string]$exit, [string]$Path)) 'Err' $State
            if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) { Write-AuditLog -Action 'gpg-sign' -Outcome 'Failed' -State $State -Detail $Path | Out-Null }
            return $false
        }
        if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) { Write-AuditLog -Action 'gpg-sign' -Outcome 'Completed' -State $State -Detail $Path | Out-Null }
        return $true
    } catch {
        Write-Log (Get-LocaleMessage -Key 'log.deploy.signFailed' -MessageArgs @([string]$_.Exception.Message)) 'Err' $State
        if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) { Write-AuditLog -Action 'gpg-sign' -Outcome 'Failed' -State $State -Detail $Path | Out-Null }
        return $false
    }
}

function Invoke-DeployVercel {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectType)
    $cfg = Get-DeployConfig -State $State -Target 'vercel'
    if (-not (Test-DeployToken -Value ([string]$cfg.project) -MaxLength 128) -or [string]$cfg.project -notmatch '^[A-Za-z0-9._-]+$') { return $false }
    if (-not (Assert-DeployPrerequisite -State $State -Tool 'vercel' -ToolLabel 'Vercel CLI (vercel)' -Target 'vercel' -Config $cfg -RequiredKeys @('project'))) { return $false }
    $publishOut = Assert-WebPublishOutput -State $State
    if (-not $publishOut) { return $false }

    Write-Log (Get-LocaleMessage -Key 'log.deploy.vercelStarting' -MessageArgs @([string]$cfg.project)) 'Info' $State
    Push-Location $publishOut
    try {
        & vercel deploy --prod --yes --name $cfg.project 2>&1 | Out-Host
        return ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }
}

<#
.SYNOPSIS
    Build + push + deploy container image via Docker.
.DESCRIPTION
    Reads ci.docker config from gbuild.config.json, builds the image (multi-arch
    linux/amd64,linux/arm64 by default), optionally pushes to the configured
    registry, and runs docker compose up -d for local/remote deployment.
.PARAMETER State
    Build state object.
.PARAMETER ProjectDir
    Project directory containing the Dockerfile.
#>
function Invoke-DockerCiDeploy {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir)
    $cfg = if ($State -and $State.BuildConfig -and $State.BuildConfig.ci -and $State.BuildConfig.ci.docker) { $State.BuildConfig.ci.docker } else { $null }
    if (-not $cfg -or -not $cfg.enabled) {
        Write-Log (Get-LocaleMessage -Key 'log.deploy.dockerCiDisabled') 'Warn' $State
        return $false
    }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Log (Get-LocaleMessage -Key 'log.deploy.dockerCliMissing') 'Warn' $State
        return $false
    }
    $requestedProject = if ($ProjectDir) { [string]$ProjectDir } else { [string]$State.ProjectRoot }
    $projDir = Resolve-DeployContainedPath -State $State -Path $requestedProject -RequireDirectory
    if (-not $projDir) { return $false }
    # Resolve ${env:VAR} image settings; an UNRESOLVED placeholder is not a
    # registry/owner — fall back to local naming instead of tagging literal
    # '${env:...}' strings into docker image refs.
    $imagePrefixVal = [string]$cfg.imagePrefix
    $ghcrOwnerVal = [string]$cfg.ghcrOwner
    if (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue) {
        if ($imagePrefixVal) { $imagePrefixVal = Resolve-EnvPlaceholder -Text $imagePrefixVal }
        if ($ghcrOwnerVal) { $ghcrOwnerVal = Resolve-EnvPlaceholder -Text $ghcrOwnerVal }
    }
    if (Get-Command Test-UnresolvedEnvPlaceholder -ErrorAction SilentlyContinue) {
        if ($imagePrefixVal -and (Test-UnresolvedEnvPlaceholder -Text $imagePrefixVal)) { $imagePrefixVal = '' }
        if ($ghcrOwnerVal -and (Test-UnresolvedEnvPlaceholder -Text $ghcrOwnerVal)) { $ghcrOwnerVal = '' }
    } else {
        if ($imagePrefixVal -and ($imagePrefixVal -match '\$\{env:[A-Za-z_][A-Za-z0-9_]*\}')) { $imagePrefixVal = '' }
        if ($ghcrOwnerVal -and ($ghcrOwnerVal -match '\$\{env:[A-Za-z_][A-Za-z0-9_]*\}')) { $ghcrOwnerVal = '' }
    }
    $imageName = if ($imagePrefixVal) { "$imagePrefixVal/$(Split-Path $projDir -Leaf)" } else { (Split-Path $projDir -Leaf) }
    $tag = if ($cfg.autoTag) { (Get-BuildTimestamp -Kind ImageTag) } else { 'latest' }
    $registry = if ($cfg.useGhcr -and $ghcrOwnerVal) { "ghcr.io/$ghcrOwnerVal" } else { $cfg.registry }
    $imageRef = if ($registry -and $registry -ne 'docker.io') { "${registry}/${imageName}:${tag}" } else { "${imageName}:${tag}" }

    Write-Log (Get-LocaleMessage -Key 'log.deploy.dockerBuilding' -MessageArgs @([string]$imageRef)) 'Info' $State
    $dockerfile = Join-Path $projDir 'Dockerfile'
    if (-not (Test-Path $dockerfile)) {
        Write-Log (Get-LocaleMessage -Key 'log.deploy.dockerNoDockerfile' -MessageArgs @([string]$projDir)) 'Warn' $State
        return $false
    }
    & docker build -t $imageRef -f $dockerfile $projDir 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Log (Resolve-LogMessage -Key 'log.docker.buildFailed' -Fallback '[DOCKER] Build failed') 'Err' $State; return $false }

    if ($registry -and $registry -ne 'docker.io') {
        Write-Log (Get-LocaleMessage -Key 'log.deploy.dockerPushing' -MessageArgs @([string]$imageRef)) 'Info' $State
        & docker push $imageRef 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Log (Resolve-LogMessage -Key 'log.docker.pushFailed' -Fallback '[DOCKER] Push failed') 'Err' $State; return $false }
    }

    $compose = Join-Path $projDir 'docker-compose.yml'
    if (-not (Test-Path -LiteralPath $compose)) {
        $composeYaml = Join-Path $projDir 'docker-compose.yaml'
        if (Test-Path -LiteralPath $composeYaml) { $compose = $composeYaml }
    }
    if (Test-Path -LiteralPath $compose) {
    Write-Log (Get-LocaleMessage -Key 'log.deploy.dockerComposeDeploying') 'Info' $State
        # L5: ci.docker.composeServices (was orphan key) selects services to
        # start; empty = whole stack (up -d with no service args).
        $svcList = @()
        try {
            if ($State -and $State.BuildConfig -and $State.BuildConfig.ci -and $State.BuildConfig.ci.docker -and $State.BuildConfig.ci.docker.composeServices) {
                $svcList = @($State.BuildConfig.ci.docker.composeServices | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
        } catch { $svcList = @() }
        if ($svcList.Count -gt 0) {
            Write-Log (Get-LocaleMessage -Key 'log.deploy.dockerComposeServices' -MessageArgs @(,([string]($svcList -join ', ')))) 'Gray' $State
            & docker compose -f $compose up -d @svcList 2>&1 | Out-Host
        } else {
            & docker compose -f $compose up -d 2>&1 | Out-Host
        }
        return ($LASTEXITCODE -eq 0)
    }
    Write-Log (Get-LocaleMessage -Key 'log.deploy.dockerBuildComplete' -MessageArgs @([string]$imageRef)) 'Succ' $State
    return $true
}

<#
.SYNOPSIS
    Deploy a web/container build to Google Cloud Run.
.DESCRIPTION
    Reads deploy.gcp config and runs `gcloud run deploy` against the built image.
.PARAMETER State
    Build state object.
.PARAMETER ProjectDir
    Project directory.
.PARAMETER ProjectType
    Detected project type.
#>
function Invoke-DeployGcp {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectType)
    $cfg = Get-DeployConfig -State $State -Target 'gcp'
    if (-not (Test-DeployToken -Value ([string]$cfg.project) -MaxLength 128) -or -not (Test-DeployToken -Value ([string]$cfg.service) -MaxLength 128) -or [string]$cfg.project -notmatch '^[A-Za-z0-9._-]+$' -or [string]$cfg.service -notmatch '^[A-Za-z0-9._-]+$') { return $false }
    if (-not (Assert-DeployPrerequisite -State $State -Tool 'gcloud' -ToolLabel 'Google Cloud CLI (gcloud)' -Target 'gcp' -Config $cfg -RequiredKeys @('project','service'))) { return $false }
    $image = if ($cfg.image) {
        $cfg.image
    } else {
        # NOTE: no $((if ...)) here — PS 5.1 throws "term 'if' not recognized"
        # inside expandable strings just like parenthesized (if) in code.
        $gcrProj = if (Get-Command Get-ProjectShortName -ErrorAction SilentlyContinue) { Get-ProjectShortName -State $State } else { Split-Path $State.ProjectRoot -Leaf }
        "gcr.io/$($cfg.project)/$gcrProj:latest"
    }
    Write-Log (Get-LocaleMessage -Key 'log.deploy.cloudRunStarting' -MessageArgs @([string]$cfg.service)) 'Info' $State
    $gcloudArgs = @('run', 'deploy', $cfg.service, '--image', $image, '--region', $cfg.region, '--project', $cfg.project)
    if ($cfg.allowUnauthenticated) { $gcloudArgs += @('--allow-unauthenticated') }
    & gcloud @gcloudArgs 2>&1 | Out-Host
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
    Deploy to a Kubernetes cluster via kubectl.
.DESCRIPTION
    Reads deploy.kubernetes config, replaces the image in the manifest, and
    applies it via kubectl against the configured (or current) context.
.PARAMETER State
    Build state object.
.PARAMETER ProjectDir
    Project directory.
.PARAMETER ProjectType
    Detected project type.
#>
function Resolve-K8sDeploymentName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ManifestPath)
    $text = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 -ErrorAction Stop
    $documents = @([regex]::Split($text, '(?m)^[ \t]*---[ \t]*$'))
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($document in $documents) {
        $kind = [regex]::Match($document, '(?m)^[ \t]*kind[ \t]*:[ \t]*([^ \t#\r\n]+)').Groups[1].Value.Trim().Trim('"', "'")
        if ($kind -cne 'Deployment') { continue }
        $lines = @($document -split "`r?`n")
        $metadataIndent = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^[ \t]*#') { continue }
            $match = [regex]::Match($line, '^([ \t]*)[^ \t#]')
            $indent = if ($match.Success) { $match.Groups[1].Value.Length } else { 0 }
            if ($metadataIndent -lt 0) {
                if ($line -match '^[ \t]*metadata[ \t]*:[ \t]*(#.*)?$') { $metadataIndent = $indent }
                continue
            }
            if ($indent -le $metadataIndent) { break }
            $nameMatch = [regex]::Match($line, '^[ \t]*name[ \t]*:[ \t]*(.+?)[ \t]*(#.*)?$')
            if ($nameMatch.Success) {
                $name = $nameMatch.Groups[1].Value.Trim().Trim('"', "'")
                if ($name -and (Test-DeployToken -Value $name -MaxLength 253) -and $name -notmatch '[\s/\\]') { $names.Add($name) }
                break
            }
        }
    }
    $unique = @($names | Sort-Object -Unique)
    if ($unique.Count -ne 1) { return '' }
    return $unique[0]
}

function Invoke-DeployK8s {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectType)
    $cfg = Get-DeployConfig -State $State -Target 'kubernetes'
    if (-not (Assert-DeployPrerequisite -State $State -Tool 'kubectl' -ToolLabel 'kubectl' -Target 'kubernetes' -Config $cfg -RequiredKeys @('manifest'))) { return $false }
    $manifest = Resolve-DeployContainedPath -State $State -Path ([string]$cfg.manifest)
    if (-not $manifest -or -not (Test-Path -LiteralPath $manifest -PathType Leaf)) { Write-Log (Resolve-LogMessage -Key 'log.deploy.k8sManifestContainmentFailed' -Fallback 'Kubernetes manifest failed containment validation.') 'Warn' $State; return $false }
    if (Test-ReparsePointItem -Path $manifest) { return $false }
    $context = [string]$cfg.context
    $namespace = [string]$cfg.namespace
    if ($context -and ($context -match '[\x00-\x1f\x7f\s;|=\\/]' -or $context.StartsWith('-'))) { return $false }
    if (-not $namespace -or $namespace -notmatch '^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$') { return $false }
    $imageRepo = [string]$cfg.imageRepo
    $registry = [string]$cfg.registry
    if (-not (Test-DeployToken -Value $imageRepo -MaxLength 255) -or $imageRepo -match '[\s;|]') { return $false }
    if ($registry -and $registry -notmatch '^[A-Za-z0-9._:/-]+$') { return $false }
    $tag = (Get-BuildTimestamp -Kind ImageTag)
    $image = if ($registry -and $registry -ne 'docker.io') { "$registry/$imageRepo`:$tag" } else { "$imageRepo`:$tag" }
    $outputRoot = Get-DeployPublishOutputDir -State $State
    if (-not $outputRoot) { return $false }
    if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) { New-Item -ItemType Directory -Path $outputRoot -Force -ErrorAction SilentlyContinue | Out-Null }
    $tmpManifest = Join-Path $outputRoot ('.k8s-manifest-' + [guid]::NewGuid().ToString('N') + '.yaml')
    try {
        $content = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8
        [System.IO.File]::WriteAllText($tmpManifest, $content.Replace('IMAGE_PLACEHOLDER', $image), (New-Object System.Text.UTF8Encoding($false)))
        $args = @()
        if ($context) { $args += @('--context',$context) }
        $args += @('apply','-f',$tmpManifest)
        if ($namespace) { $args += @('-n',$namespace) }
        $apply = Invoke-DeployTool -Name 'kubectl' -Arguments $args
        if (-not $apply.Success) { return $false }
        if ($namespace) {
            $deployName = Resolve-K8sDeploymentName -ManifestPath $manifest
            if (-not (Test-DeployToken -Value $deployName -MaxLength 253)) {
                # The apply ALREADY succeeded. Resolve-K8sDeploymentName returns
                # '' unless the manifest contains exactly one `kind: Deployment`
                # (0 for a bare image-only or multi-doc manifest), so treating an
                # unparseable name as a deploy failure reported a successful
                # `kubectl apply` as a failed deploy. The rollout wait is a
                # best-effort verification step, never the success criterion.
                Write-Log (Get-LocaleMessage -Key 'log.deploy.k8sNameUnresolved' -MessageArgs @([string]$tmpManifest)) 'Warn' $State
                return $true
            }
            $timeout = [int](Get-BuildConstant -Key 'KubectlRolloutTimeoutSec' -Fallback 120)
            if ($timeout -le 0) { $timeout = 120 }
            $rolloutArgs = @()
            if ($context) { $rolloutArgs += @('--context',$context) }
            $rolloutArgs += @('-n',$namespace,'rollout','status',('deployment/' + $deployName),('--timeout=' + $timeout + 's'))
            $rollout = Invoke-DeployTool -Name 'kubectl' -Arguments $rolloutArgs
            if (-not $rollout.Success) { return $false }
        }
        return $true
    } finally {
        if (Test-Path -LiteralPath $tmpManifest) { Remove-Item -LiteralPath $tmpManifest -Force -ErrorAction SilentlyContinue }
    }
}

<#
.SYNOPSIS
    Deploy a .NET project as an Azure Function App.
.DESCRIPTION
    Reads deploy.azureFunctions config and publishes via `func azure functionapp publish`.
.PARAMETER State
    Build state object.
.PARAMETER ProjectDir
    Project directory.
.PARAMETER ProjectType
    Detected project type.
#>
function Invoke-DeployAzureFunctions {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectType)
    $cfg = Get-DeployConfig -State $State -Target 'azureFunctions'
    if (-not (Test-DeployToken -Value ([string]$cfg.resourceGroup) -MaxLength 128) -or -not (Test-DeployToken -Value ([string]$cfg.appName) -MaxLength 128) -or [string]$cfg.resourceGroup -notmatch '^[A-Za-z0-9._-]+$' -or [string]$cfg.appName -notmatch '^[A-Za-z0-9._-]+$') { return $false }
    if (-not (Assert-DeployPrerequisite -State $State -Tool 'az' -ToolLabel 'Azure CLI (az)' -Target 'azureFunctions' -Config $cfg -RequiredKeys @('resourceGroup','appName'))) { return $false }
    $workDir = if ($cfg.workingDirectory) { Resolve-DeployContainedPath -State $State -Path ([string]$cfg.workingDirectory) } else { Resolve-DeployContainedPath -State $State -Path $ProjectDir }
    if (-not (Assert-DeployPrerequisite -State $State -Tool 'func' -ToolLabel 'Azure Functions Core Tools (func)' -Target 'azureFunctions' -Config $cfg -RequiredKeys @() -WorkDir $workDir -WorkDirMissingMessage "Azure Functions publish dir not found: $workDir. Build first.")) { return $false }

    Write-Log (Get-LocaleMessage -Key 'log.deploy.azureFunctionsStarting' -MessageArgs @([string]$cfg.appName)) 'Info' $State
    Push-Location $workDir
    try {
        & func azure functionapp publish $cfg.appName 2>&1 | Out-Host
        return ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }
}

<#
.SYNOPSIS
    Deploy a .NET project as an AWS Lambda function.
.DESCRIPTION
    Reads deploy.awsLambda config, packages the build output as a zip, and
    updates the Lambda function code via `aws lambda update-function-code`.
.PARAMETER State
    Build state object.
.PARAMETER ProjectDir
    Project directory.
.PARAMETER ProjectType
    Detected project type.
#>
function Invoke-DeployAwsLambda {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectType)
    $cfg = Get-DeployConfig -State $State -Target 'awsLambda'
    $functionName = [string](Get-SectionValue -Section $cfg -Key 'functionName' -Default '')
    if (-not (Test-DeployToken -Value $functionName -MaxLength 128) -or $functionName -notmatch '^[A-Za-z0-9_-]+$') { return $false }
    $region = [string](Get-SectionValue -Section $cfg -Key 'region' -Default '')
    if ($region -and $region -notmatch '^[a-z]{2}(-[a-z0-9]+)+-[0-9]+$') { return $false }
    $workDir = if ($cfg -and $cfg.workingDirectory) { Resolve-DeployContainedPath -State $State -Path ([string]$cfg.workingDirectory) } else { Resolve-DeployContainedPath -State $State -Path $ProjectDir }
    if (-not $workDir -or -not (Test-Path -LiteralPath $workDir -PathType Container)) { return $false }
    if (Test-ReparsePointItem -Path $workDir) { return $false }
    if (-not (Assert-DeployPrerequisite -State $State -Tool 'aws' -ToolLabel 'AWS CLI (aws)' -Target 'awsLambda' -Config $cfg -RequiredKeys @('functionName') -WorkDir $workDir -WorkDirMissingMessage "AWS Lambda publish dir not found: $workDir. Build first.")) { return $false }
    $outputRoot = Get-DeployPublishOutputDir -State $State
    if (-not $outputRoot) { return $false }
    if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) { New-Item -ItemType Directory -Path $outputRoot -Force -ErrorAction SilentlyContinue | Out-Null }
    $zip = Join-Path $outputRoot ('lambda-' + $functionName + '.zip')
    $tempZip = Join-Path $outputRoot ('.lambda-' + [guid]::NewGuid().ToString('N') + '.zip')
    if (-not (Test-Path -LiteralPath $tempZip -PathType Leaf)) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue }
    try {
        if (-not (Get-Command Compress-Archive -ErrorAction SilentlyContinue)) { return $false }
        $filesToArchive = @(Get-ChildItem -LiteralPath $workDir -Recurse -File -ErrorAction Stop)
        $workFull = ([System.IO.Path]::GetFullPath($workDir)).TrimEnd('\', '/')

        foreach ($archiveFile in $filesToArchive) {
            $archiveFull = [System.IO.Path]::GetFullPath($archiveFile.FullName)
            # Archive membership uses the same containment owner as the work-dir
            # resolver. A PathUtils fallback remains for a stripped import, but
            # the normal path delegates every archive entry.
            $archiveOk = $false
            if (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) {
                try { $archiveOk = Test-PathUnderRoots -Path $archiveFull -AllowedRoots @($workFull) } catch { $archiveOk = $false }
            } else {
                try {
                    $cmp = Get-PathComparison
                    $archiveOk = $archiveFull.StartsWith($workFull + [System.IO.Path]::DirectorySeparatorChar, $cmp)
                } catch { $archiveOk = $false }
            }
            if (-not $archiveOk) { return $false }
            if (Test-ReparsePointItem -Path $archiveFile) { return $false }
        }
        Compress-Archive -Path (Join-Path $workDir '*') -DestinationPath $tempZip -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $tempZip -PathType Leaf)) { return $false }
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction Stop }
        [System.IO.File]::Move($tempZip, $zip)
        $args = @('lambda','update-function-code','--function-name',$functionName,'--zip-file',('file://' + $zip))
        if ($region) { $args += @('--region',$region) }
        $result = Invoke-DeployTool -Name 'aws' -Arguments $args
        return [bool]$result.Success
    } catch {
        Write-Log (Get-LocaleMessage -Key 'log.deploy.lambdaPackageFailed') 'Err' $State
        return $false
    } finally {
        if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue }
    }
}

<#
.SYNOPSIS
    Trigger an Azure DevOps Pipelines build.
.DESCRIPTION
    Reads ci.azure config and triggers a pipeline run via `az pipelines run`.
.PARAMETER State
    Build state object.
.PARAMETER ProjectDir
    Project directory.
.PARAMETER ProjectType
    Detected project type.
#>
function Invoke-AzurePipelineTrigger {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectType)
    $cfg = if ($State -and $State.BuildConfig -and $State.BuildConfig.ci -and $State.BuildConfig.ci.azure) { $State.BuildConfig.ci.azure } else { $null }
    if (-not (Test-DeployToken -Value ([string]$cfg.projectName) -MaxLength 128) -or [string]$cfg.projectName -notmatch '^[A-Za-z0-9._-]+$') { return $false }
    if (-not (Assert-DeployPrerequisite -State $State -Tool 'az' -ToolLabel 'Azure CLI (az)' -Target 'ci.azure' -Config $cfg -RequiredKeys @('projectName'))) { return $false }
    Write-Log (Get-LocaleMessage -Key 'log.deploy.azurePipelineTrigger' -MessageArgs @([string]$cfg.pipelineFile)) 'Info' $State
    $pipelineName = [System.IO.Path]::GetFileNameWithoutExtension($cfg.pipelineFile)
    $orgArgs = @()
    if ($cfg.orgUrl) { $orgArgs = @('--org', $cfg.orgUrl) }
    & az pipelines run --project $cfg.projectName $orgArgs --name $pipelineName 2>&1 | Out-Host
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
    Validates the configuration of all enabled deploy targets (non-fatal preflight).
.DESCRIPTION
    For each deploy target with enabled=$true, checks the required configuration
    fields are present. Returns a PSCustomObject summary (Targets array with
    Name/Enabled/Valid/Missing, plus Overall). Does not perform any network/deploy
    action — safe to run in CI as an end-to-end configuration check.
.PARAMETER State
    Build state object.
.OUTPUTS
    PSCustomObject { Targets, Overall }
#>
function Test-DeployTargets {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $deploy = if ($State -and $State.BuildConfig -and $State.BuildConfig.deploy) { $State.BuildConfig.deploy } else { $null }

    # SINGLE SOURCE. This used to carry its own $builtIn table of required fields,
    # separate from the Register-DeployTarget calls, and the two had already drifted:
    # the table listed 7 targets while the registry held 9, so `dockerCi` and
    # `azurePipeline` - both reachable from the menu - were invisible to validation.
    # The registry is authoritative for dispatch, so it is authoritative here too:
    # a newly registered target is validated the day it is added, and no second
    # list can rot. deploy.requiredFields in config still overrides, so an operator
    # can relax or tighten the contract without a core edit.
    $configured = $null
    try {
        if ($deploy -and ($deploy.PSObject.Properties.Name -contains 'requiredFields') -and $null -ne $deploy.requiredFields) {
            $configured = $deploy.requiredFields
        }
    } catch { $configured = $null }

    $targets = [System.Collections.ArrayList]@()
    # Walk the REGISTRY, not a hand-written list.
    foreach ($name in @($script:DeployTargetRegistry.Keys)) {
        $entry = $script:DeployTargetRegistry[$name]
        $configKey = [string]$entry.ConfigKey
        $requiredForTarget = if ($configured -and ($configured.PSObject.Properties.Name -contains $name)) { @($configured.$name) }
                             elseif ($entry.RequiredFields) { @($entry.RequiredFields) }
                             else { @() }
        # A target reads its settings from its own ConfigKey section, so validation
        # must look there too. `dockerCi` registers under 'docker' and
        # `azurePipeline` reads ci.azure; both resolve through ConfigKey, which is
        # why validating a hardcoded 'deploy.<name>' path found nothing for them.
        $section = $null
        if ($deploy -and ($deploy.PSObject.Properties.Name -contains $configKey)) { $section = $deploy.$configKey }
        $enabled = if ($section -and ($section.PSObject.Properties.Name -contains 'enabled')) { [bool]$section.enabled } else { $false }
        $missing = [System.Collections.ArrayList]@()
        if ($enabled -and $section) {
            foreach ($req in $requiredForTarget) {
                $has = ($section.PSObject.Properties.Name -contains $req) -and -not [string]::IsNullOrWhiteSpace([string]$section.$req)
                if (-not $has) { $missing.Add($req) | Out-Null }
            }
        }
        $null = $targets.Add([PSCustomObject]@{
            Name       = $name
            ConfigKey  = $configKey
            Enabled    = $enabled
            Valid      = if ($enabled) { $missing.Count -eq 0 } else { $true }
            Missing    = @($missing)
        })
    }
    $ordered = @($targets | Sort-Object Name)
    $enabledTargets = @($ordered | Where-Object { $_.Enabled })
    $overall = if ($enabledTargets.Count -eq 0) { $true } else { (@($enabledTargets | Where-Object { -not $_.Valid }).Count -eq 0) }
    return [PSCustomObject]@{ Targets = $ordered; Overall = $overall }
}

<#
.SYNOPSIS
    Parses deploy.environments config and returns environment definitions.
.DESCRIPTION
    Reads deploy.environments from gbuild.config.json. Each environment has
    name, branch, approval required, and optional deploy targets.
#>
function Get-DeployEnvironments {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    if (-not $State -or -not $State.BuildConfig -or -not $State.BuildConfig.deploy -or -not $State.BuildConfig.deploy.environments) {
        return @()
    }
    $envs = $State.BuildConfig.deploy.environments
    $results = [System.Collections.ArrayList]@()
    foreach ($e in $envs.PSObject.Properties) {
        if ($e.Value -is [PSCustomObject]) {
            $null = $results.Add([PSCustomObject]@{
                Name       = $e.Name
                Branch     = if ($e.Value.branch) { $e.Value.branch } else { $e.Name }
                RequiresApproval = if ($e.Value.PSObject.Properties.Name -contains 'requiresApproval') { [bool]$e.Value.requiresApproval } else { $false }
                Targets    = if ($e.Value.targets -is [array]) { @($e.Value.targets) } else { @() }
                AutoDeploy = if ($e.Value.PSObject.Properties.Name -contains 'autoDeploy') { [bool]$e.Value.autoDeploy } else { $false }
            })
        }
    }
    return $results.ToArray()
}

<#
.SYNOPSIS
    Returns the environment for a given branch name.
.DESCRIPTION
    Resolves the environment mapping: branch 'main' → 'production',
    'develop' → 'staging', etc. Falls back to a default if no match.
#>
function Resolve-EnvironmentForBranch {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Branch)
    if ([string]::IsNullOrWhiteSpace($Branch)) { return $null }
    $envs = Get-DeployEnvironments -State $State
    foreach ($e in $envs) {
        if ($Branch -like $e.Branch) { return $e }
    }
    return $null
}

<#
.SYNOPSIS
    Registers a new deploy environment at runtime.
.DESCRIPTION
    Adds an environment to the in-memory registry (not persisted to config).
#>
function Add-DeployEnvironment {
    [CmdletBinding()]
    param(
        [PSCustomObject]$State,
        [Parameter(Mandatory)] [string]$Name,
        [string]$Branch = $Name,
        [switch]$RequiresApproval,
        [string[]]$Targets = @(),
        [switch]$AutoDeploy
    )
    if (-not $State.BuildConfig) { return $null }
    if (-not $State.BuildConfig.deploy) {
        $State.BuildConfig | Add-Member -MemberType NoteProperty -Name deploy -Value ([PSCustomObject]@{}) -Force
    }
    if (-not $State.BuildConfig.deploy.environments) {
        $State.BuildConfig.deploy | Add-Member -MemberType NoteProperty -Name environments -Value ([PSCustomObject]@{}) -Force
    }
    $newEnv = [PSCustomObject]@{
        branch = $Branch
        requiresApproval = [bool]$RequiresApproval
        targets = $Targets
        autoDeploy = [bool]$AutoDeploy
    }
    $State.BuildConfig.deploy.environments | Add-Member -MemberType NoteProperty -Name $Name -Value $newEnv -Force
    return $newEnv
}

<#
.SYNOPSIS
    Tests whether the given environment requires manual approval before deploying.
.DESCRIPTION
    Checks the environment config's requiresApproval flag.
#>
function Test-ApprovalRequired {
    [CmdletBinding()]
    [OutputType([bool])]
    param([PSCustomObject]$State, [string]$EnvironmentName)
    if ([string]::IsNullOrWhiteSpace($EnvironmentName)) { return $false }
    $envs = Get-DeployEnvironments -State $State
    $match = $envs | Where-Object { $_.Name -eq $EnvironmentName } | Select-Object -First 1
    return ($match -and $match.RequiresApproval)
}

<#
.SYNOPSIS
    Promotes a deploy environment (copies artifacts from source to target).
.DESCRIPTION
    Approves and promotes artifacts from one environment (e.g. staging) to
    another (e.g. production). Runs the source environment's deploy targets
    against the target environment's config.
#>
function Publish-Environment {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [string]$From,
        [Parameter(Mandatory)] [string]$To
    )
    # Level 5: env-model helpers single-sourced (were test-only).
    # Branch auto-resolution + approval gate flow through shared helpers.
    try {
        if (Get-Command Resolve-EnvironmentForBranch -ErrorAction SilentlyContinue) {
            $branch = ''
            try { $branch = (git rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim() } catch { $branch = '' }
            if ($branch) { $autoEnv = Resolve-EnvironmentForBranch -State $State -Branch $branch }
        }
    } catch { }
    $fromEnv = Get-DeployEnvironments -State $State | Where-Object { $_.Name -eq $From } | Select-Object -First 1
    $toEnv = Get-DeployEnvironments -State $State | Where-Object { $_.Name -eq $To } | Select-Object -First 1
    if (-not $fromEnv -or -not $toEnv) {
        Write-Log (Get-LocaleMessage -Key 'log.deploy.envPromoteMissing' -MessageArgs @([string]$From, [string]$To)) 'Err' $State
        return $false
    }
    # Level 5: approval gate via Test-ApprovalRequired (was test-only).
    $needsApproval = $toEnv.RequiresApproval
    if (Get-Command Test-ApprovalRequired -ErrorAction SilentlyContinue) {
        try { $needsApproval = [bool](Test-ApprovalRequired -State $State -EnvironmentName $To) } catch { }
    }
    if ($needsApproval) {
        Write-Log (Get-LocaleMessage -Key 'log.deploy.envNeedsApproval' -MessageArgs @([string]$To)) 'Warn' $State
        if ($State.NonInteractive) {
            Write-Log (Get-LocaleMessage -Key 'log.deploy.envNonInteractive') 'Err' $State
            return $false
        }
        $answer = Read-Host "Approve promotion $From → $To? (y/N)"
        if ($answer -ne 'y' -and $answer -ne 'Y') {
            Write-Log (Get-LocaleMessage -Key 'log.deploy.envRejected') 'Warn' $State
            return $false
        }
    }
    Write-Log (Get-LocaleMessage -Key 'log.deploy.envPromoting' -MessageArgs @([string]$From, [string]$To)) 'Info' $State
    $allOk = $true
    $attempted = $false
    foreach ($targetName in $toEnv.Targets) {
        # Promotion used to call Invoke-DeployTarget DIRECTLY while the group
        # path called Invoke-DeployWithRollback, so the same target failed with
        # opposite semantics depending on which config key the operator used:
        # one registered a compensating action and probed the endpoint, the
        # other did neither. Route both through the rollback wrapper so a
        # promotion cannot ship a target the group path would have rolled back.
        if (Get-Command Invoke-DeployWithRollback -ErrorAction SilentlyContinue) {
            $attempted = $true
            try {
                if (-not (Invoke-DeployWithRollback -State $State -TargetName $targetName)) { $allOk = $false }
            } catch {
                Write-Log (Get-LocaleMessage -Key 'log.deploy.envTargetFailed' -MessageArgs @([string]$targetName, [string]$_)) 'Warn' $State
                $allOk = $false
            }
        } elseif (Get-Command Invoke-DeployTarget -ErrorAction SilentlyContinue) {
            $attempted = $true
            try {
                $result = Invoke-DeployTarget -Name $targetName -State $State
                if (-not (Test-RequiredResult -Result $result -Operation "deploy:$targetName")) { $allOk = $false }
            } catch {
                Write-Log (Get-LocaleMessage -Key 'log.deploy.envTargetFailed' -MessageArgs @([string]$targetName, [string]$_)) 'Warn' $State
                $allOk = $false
            }
        } else {
            $allOk = $false
        }
    }
    if ($attempted -and $allOk) {
        Write-Log (Get-LocaleMessage -Key 'log.deploy.envPromoteDone' -MessageArgs @([string]$From, [string]$To)) 'Succ' $State
    }
    return ($attempted -and $allOk)
}

<#
.SYNOPSIS
    Wraps a deploy target invocation with rollback support.
.DESCRIPTION
    Executes a deploy action and registers a compensating rollback action
    on failure. Uses the ErrorHandling rollback stack.
#>
function Invoke-DeployWithRollback {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$State,
        [Parameter(Mandatory)] [string]$TargetName,
        [scriptblock]$RollbackAction,
        [hashtable]$RollbackContext = @{}
    )
    $target = Get-DeployTarget -Name $TargetName
    if (-not $target) { Write-Log (Resolve-LogMessage -Key 'log.deploy.targetNotRegistered' -MessageArgs @([string]$TargetName) -Fallback '[DEPLOY] Target ''{0}'' not registered') 'Err' $State; return $false }

    Write-Log (Get-LocaleMessage -Key 'log.deploy.rollbackStarting' -MessageArgs @([string]$TargetName)) 'Info' $State
    try {
        $result = Invoke-DeployTarget -Name $TargetName -State $State
        if (-not (Test-RequiredResult -Result $result -Operation "deploy:$TargetName")) {
            Write-Log (Get-LocaleMessage -Key 'log.deploy.targetFailed' -MessageArgs @([string]$TargetName)) 'Err' $State
            if ($RollbackAction) { try { & $RollbackAction $RollbackContext } catch { Write-Log (Resolve-LogMessage -Key 'log.rollback.compensatingFailed' -Fallback '[ROLLBACK] Compensating action failed.') 'Err' $State } }
            return $false
        }

        # Exit code 0 is not proof the deployment serves. When the operator
        # enabled deploy.health, probe the endpoint and treat a failed probe as
        # a failed deploy - otherwise the rollback below is registered for a
        # release that is live and broken. Test-DeployHealth self-skips unless
        # deploy.health.enabled is true and a url is configured, so this call
        # is inert on the default config.
        if (Get-Command Test-DeployHealth -ErrorAction SilentlyContinue) {
            $healthOk = Test-DeployHealth -State $State
            if (-not $healthOk) {
                Write-Log (Get-LocaleMessage -Key 'log.deploy.targetFailed' -MessageArgs @([string]$TargetName)) 'Err' $State
                if ($RollbackAction) { try { & $RollbackAction $RollbackContext } catch { Write-Log (Resolve-LogMessage -Key 'log.rollback.compensatingFailed' -Fallback '[ROLLBACK] Compensating action failed.') 'Err' $State } }
                return $false
            }
        }

        if (Get-Command Register-RollbackAction -ErrorAction SilentlyContinue) {
            # .GetNewClosure() captures $RollbackAction/$TargetName/$State from THIS
            # scope: the action executes later inside ErrorHandling (Invoke-Rollback
            # calls it via &), where dynamic scoping would find none of these locals.
            Register-RollbackAction -Name "Deploy:$TargetName" -Context $RollbackContext -Action {
                param($ctx)
                if ($RollbackAction) { & $RollbackAction $ctx }
                Write-Log (Get-LocaleMessage -Key 'log.deploy.compensating' -MessageArgs @([string]$TargetName)) 'Warn' $State
            }.GetNewClosure()
        }
        return $true
    } catch {
        Write-Log (Get-LocaleMessage -Key 'log.deploy.targetFailedReason' -MessageArgs @([string]$TargetName, [string]$_)) 'Err' $State
        if ($RollbackAction) { try { & $RollbackAction $RollbackContext } catch { Write-Log (Resolve-LogMessage -Key 'log.rollback.compensatingFailed' -Fallback '[ROLLBACK] Compensating action failed.') 'Err' $State } }
        return $false
    }
}

<#
.SYNOPSIS
    Performs an HTTP health check against a deployed endpoint.
.DESCRIPTION
    Level 5 layered probe: retry/status-code wrapper around the single-source
    single-GET probe (Environment.Test-HttpEndpoint). Kept separate from
    Deploy.Test-WebAppReady because this checks a REMOTE deployed URL with an
    expected status code, while WebAppReady checks a LOCAL launched process
    (port + process-liveness). Single GET lives in exactly one place.
    Sends HTTP GET requests to the given URL with configurable retry and
    expected status code. Returns $true if the probe succeeds.
#>
function Test-DeployHealth {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [PSCustomObject]$State,
        # Level 5 single-source: DeployBaseUrl/DeployHealth* live in BuildConstants.
        # Literals are emergency standalone fallbacks only (module absent).
        [string]$Url = (Get-BuildConstant -Key 'DeployBaseUrl' -Fallback 'http://localhost'),
        [int]$ExpectedStatus = 200,
        # -1 = sentinel "use default" (deploy.health.retries > BuildConstants > 3)
        [int]$Retries = -1,
        [int]$DelayMs = (Get-BuildConstant -Key 'DeployHealthRetryMs' -Fallback 2000)
    )
    if ($Retries -lt 0) {
        $Retries = Get-BuildConstant -Key 'DeployHealthRetries' -Fallback 3
    }
    # Read from config if available.
    # gbuild.config.schema.json already declares deploy.health.enabled and
    # deploy.health.url, but nothing read them and nothing ever CALLED this
    # function - so every deploy reported Success on exit code alone and a
    # target returning 0 while serving 5xx was recorded as Succeeded. An
    # unset/disabled health block must not change the existing deploy
    # behaviour, so this stays opt-in: no enabled flag or no url = no probe.
    $healthEnabled = $false
    if ($State -and $State.BuildConfig -and $State.BuildConfig.deploy -and $State.BuildConfig.deploy.health) {
        $healthCfg = $State.BuildConfig.deploy.health
        if ($null -ne $healthCfg.enabled) { $healthEnabled = [bool]$healthCfg.enabled }
        if ($null -ne $healthCfg.url) { $Url = [string]$healthCfg.url }
        if ($null -ne $healthCfg.retries) { $Retries = [int]$healthCfg.retries }
        if ($null -ne $healthCfg.delayMs) { $DelayMs = [int]$healthCfg.delayMs }
        if ($null -ne $healthCfg.expectedStatus) { $ExpectedStatus = [int]$healthCfg.expectedStatus }
    }
    # An operator who configured no endpoint gets no probe; the -Url parameter
    # default is only an emergency standalone fallback for a caller that passes
    # no config at all.
    if (-not $healthEnabled -or [string]::IsNullOrWhiteSpace($Url)) { return $true }
    Write-Log (Get-LocaleMessage -Key 'log.deploy.healthProbing' -MessageArgs @([string]$Url)) 'Info' $State
    for ($i = 1; $i -le $Retries; $i++) {
        # Invoke-WebRequest throws on any status >= 400 when -ErrorAction Stop,
        # so a 503 was previously reported as "connection failed" and
        # deploy.health.expectedStatus could never match a 4xx/5xx code. Read
        # the status out of the exception's response first, then decide; a real
        # transport failure is the only case that means "could not reach it".
        $statusCode = $null
        try {
            $response = Invoke-WebRequest -Uri $Url -TimeoutSec (Get-BuildConstant -Key 'DeployHealthTimeoutSec' -Fallback 10) -UseBasicParsing -ErrorAction Stop
            $statusCode = [int]$response.StatusCode
        } catch {
            # PowerShell 5.1 throws WebException (Response = HttpWebResponse)
            # while PowerShell 7 throws HttpResponseException (Response =
            # HttpResponseMessage). Both expose .StatusCode, and that is the
            # only field that matters here, so resolve it duck-typed instead of
            # catching per-type - a type-specific catch silently misses every
            # 4xx/5xx on the other host.
            $statusCode = $null
            try {
                $exResp = $null
                if ($_.Exception -and $_.Exception.PSObject.Properties.Name -contains 'Response') { $exResp = $_.Exception.Response }
                if ($exResp -and $exResp.PSObject.Properties.Name -contains 'StatusCode') { $statusCode = [int]$exResp.StatusCode }
            } catch { $statusCode = $null }
            if ($null -eq $statusCode) {
                Write-Log (Get-LocaleMessage -Key 'log.deploy.healthConnFailed' -MessageArgs @([string]$_.Exception.Message, [string]$i, [string]$Retries)) 'Warn' $State
            }
        }
        if ($null -ne $statusCode) {
            if ($statusCode -eq $ExpectedStatus) {
                Write-Log (Get-LocaleMessage -Key 'log.deploy.healthOk' -MessageArgs @([string]$ExpectedStatus)) 'Succ' $State
                return $true
            }
            Write-Log (Get-LocaleMessage -Key 'log.deploy.healthStatusMismatch' -MessageArgs @([string]$statusCode, [string]$ExpectedStatus, [string]$i, [string]$Retries)) 'Warn' $State
        }
        if ($i -lt $Retries) { Start-Sleep -Milliseconds $DelayMs }
    }
    Write-Log (Get-LocaleMessage -Key 'log.deploy.healthFailed' -MessageArgs @([string]$Retries)) 'Err' $State
    return $false
}

<#
.SYNOPSIS
    Runs deploy targets in ordered groups (sequential within group, parallel across groups).
.DESCRIPTION
    Reads deploy.order.groups config. Each group runs its targets sequentially;
    groups run in the specified order.
#>
function Invoke-DeployGroup {
    [CmdletBinding()]
    [OutputType([bool])]
    param([PSCustomObject]$State)
    $orderCfg = if ($State -and $State.BuildConfig -and $State.BuildConfig.deploy -and $State.BuildConfig.deploy.order) { $State.BuildConfig.deploy.order } else { $null }
    if (-not $orderCfg -or -not $orderCfg.groups) {
        Write-Log (Get-LocaleMessage -Key 'log.deploy.noOrderGroups') 'Gray' $State
        return $false
    }
    $allOk = $true
    $attempted = $false
    foreach ($group in $orderCfg.groups) {
        if ($group.targets -is [array]) {
            Write-Log (Get-LocaleMessage -Key 'log.deploy.groupStarting' -MessageArgs @([string]$group.name)) 'Info' $State
            foreach ($t in $group.targets) {
                $attempted = $true
                try {
                    $ok = Invoke-DeployWithRollback -State $State -TargetName $t
                    if (-not $ok) { $allOk = $false }
                } catch {
                    Write-Log (Get-LocaleMessage -Key 'log.deploy.groupTargetFailed' -MessageArgs @([string]$t, [string]$group.name, [string]$_)) 'Warn' $State
                    $allOk = $false
                    if ($group.failFast) { throw }
                }
            }
        }
    }
    return ($attempted -and $allOk)
}

<#
.SYNOPSIS
    Returns the absolute publish-output root directory shared by deploy targets.
.DESCRIPTION
    Resolves the configured publish-output folder name and anchors it under
    ProjectRoot so every deploy target (Azure/AWS/Vercel/Docker/K8s) zips or
    uploads from the same location the build pipeline wrote artifacts to.
#>
function Get-DeployPublishOutputDir {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    $publishOutput = Resolve-PublishOutputDir -State $State
    return (Resolve-DeployContainedPath -State $State -Path $publishOutput)
}

Export-ModuleMember -Function @(
    'Invoke-DeployAzure', 'Invoke-DeployAws', 'Invoke-DeployVercel', 'Invoke-DockerCiDeploy',
    'Invoke-DeployGcp', 'Invoke-DeployK8s', 'Invoke-DeployAzureFunctions', 'Invoke-DeployAwsLambda',
    'Invoke-AzurePipelineTrigger', 'Test-DeployTargets', 'Register-DeployTarget', 'Get-DeployTarget',
    'Invoke-DeployTarget', 'Get-DeployConfig', 'Get-DeployEnvironments', 'Resolve-EnvironmentForBranch',
    'Add-DeployEnvironment', 'Test-ApprovalRequired', 'Publish-Environment',
    'Invoke-DeployWithRollback', 'Test-DeployHealth', 'Invoke-DeployGroup',
    'Enter-DeployLock', 'Exit-DeployLock', 'Invoke-GpgSign', 'Assert-WebPublishOutput', 'Assert-DeployPrerequisite',
    'Resolve-K8sDeploymentName'
)




