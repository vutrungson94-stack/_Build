Set-StrictMode -Version 1.0
# ============================================================================
# Orchestrator.Deploy.ps1 - deploy helpers extracted from Orchestrator.psm1
# Dot-sourced by Orchestrator.psm1; shares module scope.
# ============================================================================

function Invoke-RegisteredDeploy {
    [CmdletBinding()]
    param([string]$Choice, [PSCustomObject]$State, [string]$ProjectDir = '', [string]$ProjectType = '')
    $map = @{
        'A' = 'azure'; 'B' = 'aws'; 'V' = 'vercel'; 'G' = 'gcp'
        'P' = 'kubernetes'; 'F' = 'azureFunctions'; 'E' = 'awsLambda'
        'K' = 'dockerCi'; 'Y' = 'azurePipeline'
    }
    $name = $map[$Choice]
    if (-not $name) { Write-Fail (Resolve-LogMessage -Key 'log.deploy.unknownChoice' -MessageArgs @([string]$Choice) -Fallback 'Unknown deploy choice: {0}') -State $State; return $false }
    if (-not (Get-Command Invoke-DeployTarget -ErrorAction SilentlyContinue)) {
        Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('DeployTargets') -Fallback 'DeployTargets module not loaded.') -State $State
        return $false
    }
    # SURFACE MISCONFIGURATION BEFORE THE DEPLOY. Test-DeployTargets shipped fully
    # implemented but was reachable only from the test suite, so no deploy verb and
    # no CI job ever ran it: a target enabled with a missing required field was
    # discovered only after the CLI had already been invoked against the cloud
    # provider. Report the specific missing keys first; the deploy itself still
    # re-validates authoritatively inside Invoke-DeployTarget.
    try {
        if (Get-Command Test-DeployTargets -ErrorAction SilentlyContinue) {
            $cfgReport = Test-DeployTargets -State $State
            $entry = @($cfgReport.Targets) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($entry -and $entry.Enabled -and -not $entry.Valid) {
                $missingList = (@($entry.Missing) -join ', ')
                $msg = (Get-LocaleMessage -Key 'log.dt.misconfigured' -MessageArgs @($name, $missingList))
                Write-Fail $msg -State $State
                if (Get-Command Write-AuditLog -ErrorAction SilentlyContinue) {
                    try { Write-AuditLog -Action "deploy:$name" -Outcome 'Denied' -State $State -Detail $msg } catch { }
                }
                return $false
            }
        }
    } catch { }
    try {
        $result = Invoke-DeployTarget -Name $name -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType
        return (Test-RequiredResult -Result $result -Operation "deploy:$name")
    } catch {
        Write-Fail (Resolve-LogMessage -Key 'log.deploy.failed' -MessageArgs @([string]$name, [string]$_) -Fallback 'Deploy ''{0}'' failed: {1}') -State $State
        return $false
    }
}

function Get-DeployChoiceArgs {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][ValidateSet('Apk','Ios','WinMsix','Aot')][string]$Kind,
        [PSCustomObject]$State
    )
    # Explicit key mapping, not `"DeployChoiceArgs$Kind"`. The string-built key
    # meant the four constants (DeployChoiceArgsApk / Ios / WinMsix / Aot) never
    # appeared at any call site, so each was declared, mapped to config and read
    # by nothing while still looking wired - and no static check could tell.
    $key = ''
    switch ($Kind) {
        'Apk'     { $key = 'DeployChoiceArgsApk' }
        'Ios'     { $key = 'DeployChoiceArgsIos' }
        'WinMsix' { $key = 'DeployChoiceArgsWinMsix' }
        'Aot'     { $key = 'DeployChoiceArgsAot' }
    }
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $v = Get-BuildConstant -Key $key -State $State -Fallback $null
            if ($v) { return @($v) }
        }
    } catch { }
    return @()
}

function Get-DeployDefaultRid {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $v = Get-BuildConstant -Key 'DeployDefaultRid' -State $State -Fallback 'win-x64'
            if ($v) { return [string]$v }
        }
    } catch { }
    return 'win-x64'
}

<#
.SYNOPSIS
    Builds the -Target catalog: every menu ID with purpose + engines (L5).
.DESCRIPTION
    Single source for `-Target list` and the invalid-target hint. Labels come
    from the neutral menu config (locale-aware), engine modules from
    Get-ModuleMapFromConfig (config-driven), project defaults from
    Get-DefaultActionsFromConfig. Availability (Supported) is intentionally
    NOT filtered here — it depends on the detected project type and OS at
    build time; the interactive menu shows the supported subset per project.
    Returns an ordered array of @{ Key; Label; Title; Modules; DefaultFor }.
#>

