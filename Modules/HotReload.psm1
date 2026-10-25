# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# HotReload.psm1 - dotnet watch orchestration


# BuildConstants loaded via deps (PsBinaryFallbackPaths — single source for ps binary
# fallback locations on non-Windows, replacing the previous '/bin/ps','/usr/bin/ps' literals).
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Environment', 'Clean', 'Build', 'SharedUtils', 'BuildConstants')
# Unix process introspection (Get-PsBinary / Get-UnixProcessCommandLine /
# Get-UnixProcessTreeMap / Get-UnixProcessDescendants) is single-sourced in
# Environment.psm1 (canonical home, Tier-0) and resolves here through the
# Environment dependency above — no local copies.
Import-GBuildModuleIfMissing -Name 'Environment' -SentinelCommand 'Get-UnixProcessTreeMap'

<#
.SYNOPSIS
    Starts dotnet watch hot reload for the project.
.DESCRIPTION
    Cleans the publish output directory, kills any processes holding the port,
    then launches `dotnet watch run` as a background job. Monitors output until
    the user presses Ctrl+C, then cleans up the watch process.
.PARAMETER State
    The build state object.
.PARAMETER ProjPath
    Full path to the project file (.csproj).
.PARAMETER ProjectDir
    The project directory.
.PARAMETER ProjectType
    The project type (Web, WinForms, Console, etc.).
#>
function Invoke-HotReload {
    [CmdletBinding()]
    param($State, $ProjPath, $ProjectDir, [string]$ProjectType = "")

Set-StrictMode -Version 1.0
    # L5: non-dotnet languages delegate to their plugin's CustomRun via
    # Invoke-PluginRunFor (was orphan). dotnet watch flow below is unchanged.
    $isDotnetProj = (-not [string]::IsNullOrWhiteSpace($ProjPath)) -and ($ProjPath -match '\.(csproj|fsproj|vbproj|sln)$')
    if (-not $isDotnetProj -and -not [string]::IsNullOrWhiteSpace($ProjectType)) {
        if (Get-Command Invoke-PluginRunFor -ErrorAction SilentlyContinue) {
            try {
                $runOk = Invoke-PluginRunFor -State $State -Language $ProjectType -ProjectDir $ProjectDir
                if ($runOk) { return }
                Write-Log (Resolve-LogMessage -Key 'log.hotreload.pluginUnavailable' -MessageArgs @([string]$ProjectType) -Fallback '[HOTRELOAD] Plugin run not available for {0}, falling back to dotnet watch.') 'Warn' $State
            } catch { }
        }
    }
    $exeBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ProjPath)
    $publishSubDir = if ($ProjectType) { $ProjectType.ToLower() } else { 'unknown' }
    $projectRoot = if (Get-Command Get-BuildRootDirectory -ErrorAction SilentlyContinue) { Get-BuildRootDirectory -State $State } elseif ($State.ProjectRoot) { $State.ProjectRoot } else { $State.ScriptRoot }
    $publishOutput = Resolve-PublishOutputDir -State $State
    $publishOutDir = Join-Path (Join-Path $projectRoot $publishOutput) $publishSubDir
    if ($publishOutDir -and (Test-Path -LiteralPath $publishOutDir -ErrorAction SilentlyContinue)) {
        Invoke-SafeRemove -Path $publishOutDir -AllowedRoots @($projectRoot) -Recurse -Force
    }
    if (Get-Command Invoke-SmartClean -ErrorAction SilentlyContinue) { Invoke-SmartClean -State $State -ProjectDir $ProjectDir -CsprojPath $ProjPath -ProjectType $ProjectType }
    if (Get-Command Stop-ProcessByPort -ErrorAction SilentlyContinue) { Stop-ProcessByPort -State $State -ProjectDir $ProjectDir -ProjectType $ProjectType -ExeName $exeBaseName }
    Write-Log (Resolve-LogMessage -Key 'log.hotreload.started' -Fallback 'Hot Reload started. Press Ctrl+C to stop.') "Succ" $State
    $safePath = Get-SafePath -Path $ProjPath
    $dotnetCmdSafe = $State.DotnetCmd
    $watchJob = Start-Job -Name "GbuildWatch" -ScriptBlock { param($DotnetCmd, $ProjPath2) & $DotnetCmd watch run --project $ProjPath2 } -ArgumentList $dotnetCmdSafe, $safePath
    try {
        while ($watchJob.State -eq 'Running') {
            $output = Receive-Job -Job $watchJob
            if ($output) {
                # Skip blank lines rather than forwarding them. Write-Log and
                # Write-LogSafe BOTH declare [Parameter(Mandatory)][string]$Message
                # and PowerShell rejects an empty string for a mandatory string
                # parameter, so forwarding a blank line threw
                # "Cannot bind argument to parameter 'Message' because it is an
                # empty string" out of the poll loop. `dotnet watch` emits blank
                # lines routinely, so `-Target W` died on essentially every run -
                # and it died AFTER printing "Hot Reload started.", which is why
                # it read as a working feature. A blank line carries no
                # information, so dropping it is also the correct behaviour
                # rather than only the non-throwing one.
                foreach ($line in $output) {
                    $text = if ($null -eq $line) { '' } else { [string]$line }
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }
                    Write-Log $text -State $State
                }
            }
            Start-Sleep -Milliseconds (Get-BuildConstant -Key 'HotReloadPollMs' -Fallback 200)
        }
    } finally {
        Stop-Job -Job $watchJob -ErrorAction SilentlyContinue
        Remove-Job -Job $watchJob -Force -ErrorAction SilentlyContinue
        # Only kill THIS project's dotnet watch process tree, not every dotnet on the host.
        # Cross-platform: CIM (Windows) vs ps/kill (Linux/macOS).
        if ($State -and $State.OS -eq 'Windows') {
            $watchProcs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'dotnet.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like '*watch*' -and $_.CommandLine -like "*$safePath*" }
            foreach ($wp in $watchProcs) {
                Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $($wp.ProcessId)" -ErrorAction SilentlyContinue |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                Stop-Process -Id $wp.ProcessId -Force -ErrorAction SilentlyContinue
            }
        } else {
            # Linux/macOS: command line via Environment.Get-UnixProcessCommandLine
            # (/proc/<pid>/cmdline on Linux, `ps -o command=` elsewhere) and the
            # process tree from Environment.Get-UnixProcessTreeMap (single
            # `ps -o pid=,ppid=` call) — does not rely on Get-Process ParentProcessId
            # (unavailable on .NET Core/non-Windows).
            $tree = Get-UnixProcessTreeMap
            $watchProcName = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { [string](Get-BuildConstant -Key 'HotReloadProcessName' -Fallback 'dotnet') } else { 'dotnet' }
            $watchPids = Get-Process -Name $watchProcName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }
            foreach ($procId in $watchPids) {
                $cmdline = Get-UnixProcessCommandLine -ProcessId $procId
                if ($cmdline -like '*watch*' -and $cmdline -like "*$safePath*") {
                    $descendants = Get-UnixProcessDescendants -Tree $tree -RootId $procId
                    foreach ($childId in $descendants) { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue }
                    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                }
            }
        }
        Write-Log (Resolve-LogMessage -Key 'log.hotreload.stopped' -Fallback 'Hot Reload stopped.') 'Yellow' $State
    }
}

# -- Non-Windows process helpers -------------------------------------------------
# Canonical implementations live in Environment.psm1 (Get-PsBinary,
# Get-UnixProcessCommandLine, Get-UnixProcessTreeMap, Get-UnixProcessDescendants).
# They are imported here through the Environment module dependency above, so the
# Invoke-HotReload cleanup below calls the single shared copy. (A previous revision
# kept private duplicates of all four in this file, invisible to other modules.)

Export-ModuleMember -Function @('Invoke-HotReload')






