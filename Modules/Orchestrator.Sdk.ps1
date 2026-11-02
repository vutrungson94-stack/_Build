# ============================================================================
# Orchestrator.Sdk.ps1 - SDK helpers extracted from Orchestrator.psm1
# Dot-sourced by Orchestrator.psm1; shares module scope.
# ============================================================================

function Invoke-SdkDetection {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectType, [string[]]$Tfms)
    $isMaui = ($ProjectType -eq 'MAUI')
    $hasAndroid = @($Tfms | Where-Object { $_ -match 'android' }).Count -gt 0
    # StrictMode-safe: PSCustomObject assignment to non-existent property throws
    # under Set-StrictMode. Use Add-Member helper (Set-BuildStateProperty when available)
    # and guard reads with property existence check so orphan/mock states also work.
    $hasJava = $State.PSObject.Properties.Name -contains 'JavaSdk' -and $State.JavaSdk
    $hasAndroidSdk = $State.PSObject.Properties.Name -contains 'AndroidSdk' -and $State.AndroidSdk
    if (($isMaui -or $hasAndroid) -and -not $hasJava -and (Get-Command Get-SmartSdk -ErrorAction SilentlyContinue)) {
        Write-Log (Get-LocaleMessage -Key 'log.sdk.javaSearching') 'Cyan' $State
        $jdk = Get-SmartSdk -State $State -ToolType 'JDK'
        if (Get-Command Set-BuildStateProperty -ErrorAction SilentlyContinue) {
            Set-BuildStateProperty -State $State -Name 'JavaSdk' -Value $jdk -Force
        } else {
            $State | Add-Member -MemberType NoteProperty -Name 'JavaSdk' -Value $jdk -Force -ErrorAction SilentlyContinue
        }
        if (-not $jdk) { Write-Log (Get-LocaleMessage -Key 'log.sdk.javaNotFound') 'Warn' $State }
    }
    if ($hasAndroid -and -not $hasAndroidSdk -and (Get-Command Get-SmartSdk -ErrorAction SilentlyContinue)) {
        Write-Log (Get-LocaleMessage -Key 'log.sdk.androidSearching') 'Cyan' $State
        $adk = Get-SmartSdk -State $State -ToolType 'Android'
        if (Get-Command Set-BuildStateProperty -ErrorAction SilentlyContinue) {
            Set-BuildStateProperty -State $State -Name 'AndroidSdk' -Value $adk -Force
        } else {
            $State | Add-Member -MemberType NoteProperty -Name 'AndroidSdk' -Value $adk -Force -ErrorAction SilentlyContinue
        }
        if (-not $adk) { Write-Log (Get-LocaleMessage -Key 'log.sdk.androidNotFound') 'Warn' $State }
    }
}

<#
    .SYNOPSIS
        Extracts platform-specific TFMs from the target frameworks array.
    .DESCRIPTION
        Returns Windows, Android, iOS, and Mac Catalyst TFMs from a list.
        For Windows-only project types, synthesizes a Windows TFM if missing.
    .PARAMETER Tfms
        Array of target framework monikers from the project.
    .PARAMETER ProjectType
        The detected project type (WinForms, WPF, WinExe).
    .PARAMETER DefaultTfm
        Fallback TFM to derive Windows TFM from.
    #>

function Resolve-BuildSdk {
    [CmdletBinding()]
    param([PSCustomObject]$State)
    # Level 5 health gate (PS 5.1 orphan): plugin-contract validation runs
    # before this point and may have orphaned PathUtils — heal loudly here so
    # Save-BuildState below can never hit a mystery CommandNotFound.
    if (Get-Command Assert-CoreCommands -ErrorAction SilentlyContinue) {
        if (-not (Assert-CoreCommands -State $State -Repair)) {
            Write-Log (Get-LocaleMessage -Key 'log.system.coreCommandsUnavailable') 'Err' $State
            return $false
        }
    }
    if (Get-Command Get-SmartSdk -ErrorAction SilentlyContinue) {
        $dotnetExe = Get-SmartSdk -State $State -ToolType 'Dotnet'
        if ($dotnetExe) {
            Set-BuildStateProperty -State $State -Name 'DotnetCmd' -Value ([string]$dotnetExe) -Force
            Write-Log "[SDK] $(Get-LocaleMessage -Key 'log.sdk.dotnetResolved' -MessageArgs @($dotnetExe))" 'Succ' $State
        } else {
            $dotnetBin = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'DotnetToolName' -Fallback 'dotnet') } else { 'dotnet' }
            $anyDotnet = Get-Command $dotnetBin -ErrorAction SilentlyContinue
            if ($anyDotnet) {
                Write-Log "[FATAL] $(Get-LocaleMessage -Key 'log.sdk.dotnetNoSdk')" 'Err' $State
            } else {
                Write-Log "[FATAL] $(Get-LocaleMessage -Key 'log.sdk.dotnetNotFound')" 'Err' $State
            }
            Write-Log "[ABORT] $(Get-LocaleMessage -Key 'log.sdk.dotnetRequired')" 'Err' $State
            return $false
        }
        # Auto-provisioning printed a manual-install diagram and asked us to stop.
        if ($State.PSObject.Properties.Name -contains 'BuildAborted' -and $State.BuildAborted) {
            Write-Log "[ABORT] $(Get-LocaleMessage -Key 'log.sdk.manualRequired')" 'Err' $State
            return $false
        }
    }
    foreach ($prop in @('DotnetCmd','JavaSdk','AndroidSdk','CurrentTfm')) { if ($State.$prop) { Write-Log (Get-LocaleMessage -Key 'log.system.sdkState' -MessageArgs @($prop, $State.$prop)) 'Gray' $State } }
    # Keep the DI BuildContext singleton in sync with the live state (re-seed after
    # late mutations such as DotnetCmd / CurrentTfm so it is never a stale snapshot).
    if (Get-Command Set-ServiceInstance -ErrorAction SilentlyContinue -and (Test-ServiceRegistered -Name 'BuildContext')) {
        Set-ServiceInstance -Name 'BuildContext' -Instance (New-BuildContext -Seed $State)
    }
    # RESUME CHECKPOINT, not a completion record. Marked incomplete so a run that
    # dies after this point is detectable on the next invocation.
    if (Get-Command Save-BuildState -ErrorAction SilentlyContinue) { Save-BuildState -State $State -Completed:$false | Out-Null }
    return $true
}

<#
.SYNOPSIS
    Returns the built-in build pipeline as an ordered step list.
.DESCRIPTION
    Extracted from Start-GBuild so the pipeline is DEFINED in one place and
    can be exercised directly. It used to be an inline literal inside
    Start-GBuild, which meant no test could reach it: Pipeline.E2E hand-built a
    4-element stub array reusing production step NAMES, so every gate step,
    its config gate and its When condition were untested, and a regression in
    the real pipeline could not fail a single test.
    Step scripts close over $State and $resolvedCfg from this function's scope,
    exactly as they did when the literal was inline.
.OUTPUTS
    Array of step hashtables: @{ Name = <string>; Script = <scriptblock> }.
#>

