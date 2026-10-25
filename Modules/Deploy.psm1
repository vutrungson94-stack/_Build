# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# Deploy.psm1 - web, desktop and Android publish orchestration


. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Environment','Project','Build','Android')
$null = Import-GBuildModule -Names @('BuildConstants') -Force
Import-GBuildModuleIfMissing -Name 'Locale' -SentinelCommand 'Get-LocaleMessage'

<#
.SYNOPSIS
    Resolves a deploy state path, refusing anything outside the build root or behind a reparse point.
.DESCRIPTION
    Delegates to the single-source guards in Modules\PathUtils.psm1:
      * Get-BuildRootDirectory  - root selection (ProjectRoot > ScriptRoot)
      * Test-PathUnderRoots     - containment
      * Test-NoReparsePointInPath - junction/symlink walk
    This function used to carry a private copy of all three, and the copy DRIFTED:
    its reparse walk stopped before the volume root (so a SUBST drive or a mapped
    network share passed), and it used Get-Item -ErrorAction Stop (so an unreadable
    intermediate directory made the whole check return '' - fail-closed but for the
    wrong reason). The canonical implementation checks the volume root and
    tolerates an unreadable segment, so behaviour is now consistent everywhere.
#>
function Resolve-DeployStatePath {
    param([PSCustomObject]$State, [string]$Path)

Set-StrictMode -Version 1.0
    # Delegates to PathUtils.Resolve-BuildContainedPath. This and
    # DeployTargets.Resolve-DeployContainedPath were byte-comparable copies of
    # the same wrapper (both doc-comments claimed the private copies were gone);
    # only the RequireDirectory switch differed.
    if (-not (Get-Command Resolve-BuildContainedPath -ErrorAction SilentlyContinue)) {
        $pathUtilsPath = Join-Path $PSScriptRoot 'PathUtils.psm1'
        if (Test-Path -LiteralPath $pathUtilsPath -PathType Leaf) {
            $null = Import-Module $pathUtilsPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
    return (Resolve-BuildContainedPath -Path $Path -State $State)
}

function Test-DeployValueSuccess {
    param([object]$Value)
    if ($null -eq $Value -or $Value -is [bool]) { return [bool]$Value }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains('Success')) { return [bool]$Value['Success'] }
        if ($Value.Contains('Status')) { return ([string]$Value['Status'] -eq 'Succeeded') }
    } else {
        if ($Value.PSObject.Properties.Name -contains 'Success') { return [bool]$Value.Success }
        if ($Value.PSObject.Properties.Name -contains 'Status') { return ([string]$Value.Status -eq 'Succeeded') }
    }
    return $true
}

<#
.SYNOPSIS
    Fast HTTP readiness probe: reports whether the target URL serves a response.
.DESCRIPTION
    Level 5 thin wrapper over Environment.Test-HttpEndpoint (single-source HTTP
    probe). Kept for backward compat — new code should call Test-HttpEndpoint
    directly. True readiness signal for Invoke-WebPublish. A response (any HTTP
    status) means Kestrel is up and serving, so the browser will actually load.
    Timeout-bounded so a refused/not-yet-ready app returns quickly instead of
    blocking the poll loop.
#>
function Test-UrlServing {
    [CmdletBinding()]
    param([Parameter()][AllowEmptyString()][string]$Url = '', [PSCustomObject]$State = $null)
    # Delegate to the single-source probe; inline HttpClient fallback below is
    # emergency standalone only (Environment module absent).
    if (Get-Command Test-HttpEndpoint -ErrorAction SilentlyContinue) {
        return (Test-HttpEndpoint -Url $Url -State $State)
    }
    # Resolve HTTP probe timeout from config; fallback to 700 ms if unset.
    $TimeoutMs = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        Get-BuildConstant -Key 'WebProbeTimeoutMs' -Fallback 700
    } else { 700 }
    # Ensure System.Net.Http is loaded so [System.Net.Http.HttpClient] resolves in
    # a bare Windows PowerShell 5.1 session (it is NOT pre-loaded there; without
    # this, constructing HttpClient throws "Unable to find type" which the swallow
    # below would turn into a false 'not serving' verdict).
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch { }
    try {
        if ([System.Net.Http.HttpClient] -as [type]) {
            $hc = [System.Net.Http.HttpClient]::new()
            $hc.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
            try {
                $msg = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
                $resp = $hc.SendAsync($msg, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $resp.Dispose()
                return $true
            } finally { $hc.Dispose() }
        }
    } catch { }
    # Fallback: HttpWebRequest is always present in Windows PowerShell 5.1 even when
    # System.Net.Http cannot be loaded. Any response (or a redirectable status)
    # means Kestrel is up and serving.
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.AllowAutoRedirect = $true
        $resp2 = $req.GetResponse()
        $resp2.Dispose()
        return $true
    } catch { return $false }
}

<#
.SYNOPSIS
    Orchestrates an Android AAB build with keystore resolution.
.DESCRIPTION
    Resolves the signing keystore from environment variables, project files, or
    auto-generation, then delegates to Build-AndroidAab for the actual build.
.PARAMETER State
    The build state object.
.PARAMETER ProjPath
    Full path to the project file (.csproj).
.PARAMETER AndroidTfm
    The Android target framework moniker.
.PARAMETER ProjectDir
    The project directory.
.PARAMETER ProjectType
    The project type.
.PARAMETER Incremental
    If specified, skips clean before build.
#>
function Invoke-AndroidAabBuild {
    [CmdletBinding()]
    param($State, $ProjPath, $AndroidTfm, $ProjectDir, [string]$ProjectType = "", [switch]$Incremental)
    $ks = $null
    if ($env:ANDROID_KEYSTORE_PATH -and $env:ANDROID_KEYSTORE_PASS) {
        $safeKeystore = Resolve-DeployStatePath -State $State -Path $env:ANDROID_KEYSTORE_PATH
        if ($safeKeystore -and (Test-Path -LiteralPath $safeKeystore -PathType Leaf)) {
            $ks = @{ Path = $safeKeystore; StorePass = $env:ANDROID_KEYSTORE_PASS; Alias = if ($env:ANDROID_KEY_ALIAS) { $env:ANDROID_KEY_ALIAS } else { $null }; KeyPass = if ($env:ANDROID_KEY_PASS) { $env:ANDROID_KEY_PASS } else { $env:ANDROID_KEYSTORE_PASS } }
        }
    }
    if (-not $ks -and (Get-Command Find-AndroidKeystore -ErrorAction SilentlyContinue)) { $ks = Find-AndroidKeystore -State $State -projectDir $ProjectDir }
    if (-not $ks -and (Get-Command New-DebugKeystore -ErrorAction SilentlyContinue)) { Write-Log (Get-LocaleMessage -Key 'log.deploy.keystoreMissing') "Warn" $State; $ks = New-DebugKeystore -State $State -ProjectDir $ProjectDir }
    if (-not $ks) { Write-Fail (Get-LocaleMessage -Key 'log.deploy.keystoreInitFailed') -State $State; return $false }
    if (-not (Get-Command Publish-AndroidAab -ErrorAction SilentlyContinue)) { return $false }
    $result = Publish-AndroidAab -State $State -ProjectPath $ProjPath -Tfm $AndroidTfm -Keystore $ks -ProjectType $ProjectType -Incremental:$Incremental
    if (Get-Command Test-RequiredResult -ErrorAction SilentlyContinue) { return (Test-RequiredResult -Result $result -Operation 'android.aab') }
    return (Test-DeployValueSuccess -Value $result)
}

<#
.SYNOPSIS
    Publishes a Web or Blazor WASM project and optionally launches it.
.DESCRIPTION
    Builds the project with Start-BuildAndShow, then for Web projects locates the
    published executable, starts it with the configured port, waits for the port
    to become ready, and opens the target URL in the browser.
.PARAMETER State
    The build state object.
.PARAMETER ProjPath
    Full path to the project file (.csproj).
.PARAMETER DefaultTfm
    The default target framework moniker.
.PARAMETER ProjectType
    The project type (Web or BlazorWasm).
.PARAMETER ProjectDir
    The project directory.
.PARAMETER Incremental
    If specified, skips clean before build.
#>
function Invoke-WebPublish {
    [CmdletBinding()]
    param($State, $ProjPath, $DefaultTfm, [string]$ProjectType = "", $ProjectDir, [switch]$Incremental)
    if (-not (Get-Command Start-BuildAndShow -ErrorAction SilentlyContinue)) { return $false }
    $portReady = $false
    if (Get-Command Start-BuildAndShow -ErrorAction SilentlyContinue) {
        if ($ProjectType -eq 'Web') {
            $swWeb = [Diagnostics.Stopwatch]::StartNew()
             $buildResult = Start-BuildAndShow -State $State -Project $ProjPath -Tfm $DefaultTfm -OutputSubDir 'web' -BuildArgs @("-p:PublishSingleFile=false") -ProjectType $ProjectType -Incremental:$Incremental
             $buildOk = if (Get-Command Test-RequiredResult -ErrorAction SilentlyContinue) { Test-RequiredResult -Result $buildResult -Operation 'web.publish' } else { [bool]$buildResult }
             if (-not $buildOk) { Write-Log (Get-LocaleMessage -Key 'log.deploy.webUiFailed') "Warn" $State; return $false }


             $publishOutput = Resolve-PublishOutputDir -State $State
             $publishRoot = Resolve-DeployStatePath -State $State -Path $publishOutput
             $webOutDir = if ($publishRoot) { Resolve-DeployStatePath -State $State -Path (Join-Path $publishRoot 'web') } else { '' }
             if (-not $webOutDir) { Write-Fail (Resolve-LogMessage -Key 'log.deploy.webContainmentFailed' -Fallback 'Web publish output failed containment validation.') -State $State; return $false }
             $exeBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ProjPath)
             $exeSuffix = Get-ExecutableExtension -State $State
             $exePath = Join-Path $webOutDir ($exeBaseName + $exeSuffix)
                $port = if (Get-Command Get-ProjectPort -ErrorAction SilentlyContinue) { Get-ProjectPort -ProjectDir $ProjectDir } else {
                    Get-BuildConstant -Key 'DefaultPort' -Fallback 5000
                }
            # Level 5 single-source: DeployBaseUrl/DefaultPort live in BuildConstants
            # (config build.defaultPort wins). Literals are emergency standalone fallbacks only.
            $url = "$(Get-BuildConstant -Key 'DeployBaseUrl' -Fallback 'http://localhost'):$port"
            if (Test-Path -Path $exePath) {
                Write-Log (Get-LocaleMessage -Key 'log.deploy.webAppLaunch' -MessageArgs $url) "Gray" $State
                # Stale-instance guard: a leftover process holding our port (often an
                # earlier `dotnet run` whose host runs as dotnet.exe, so the exe-name
                # match in Stop-ProcessByPort misses it) makes the fresh publish crash
                # with 'address already in use'. Kill the port owner before relaunching.
                if (Test-PortListening -Port $port) {
                    if (Get-Command Get-PortOwnerProcess -ErrorAction SilentlyContinue) {
                        $staleOwners = @(Get-PortOwnerProcess -Port $port)
                        # Only terminate the stale host that is OURS (the executable we
                        # are about to relaunch). A foreign process bound to this port
                        # (another app, a manually started server) is left alone -- the
                        # build then fails with 'address already in use' rather than
                        # silently killing someone else's program.
                        $selfExeFull = $null
                        try { $selfExeFull = [System.IO.Path]::GetFullPath($exePath).TrimEnd('\', '/') } catch { }
                        $projToken = [System.IO.Path]::GetFileNameWithoutExtension($exeBaseName)
                        $outDirCanon = $null
                        try { $outDirCanon = [System.IO.Path]::GetFullPath($webOutDir).TrimEnd('\', '/') } catch { }
                        foreach ($so in $staleOwners) {
                            $isSelf = $false
                            # OS-aware path comparison: case-insensitive on Windows only
                            # (NTFS), ordinal on Linux/macOS (case-sensitive FS).
                            # $State.OS first (the mockable record), then the shared
                            # PathUtils.Get-PathComparison resolver for live
                            # detection. The previous form re-implemented the live
                            # branch with its own Get-OSPlatform check, so this
                            # call site carried a second copy of the OS mapping.
                            $pathCmp = [System.StringComparison]::OrdinalIgnoreCase
                            try {
                                if ($State -and $State.OS -and $State.OS -ne 'Windows') { $pathCmp = [System.StringComparison]::Ordinal }
                                elseif (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) {
                                    $pathCmp = [System.StringComparison](Get-PathComparison)
                                }
                                elseif (Get-Command Get-OSPlatform -ErrorAction SilentlyContinue) {
                                    if ((Get-OSPlatform) -ne 'Windows') { $pathCmp = [System.StringComparison]::Ordinal }
                                }
                            } catch { }
                            try {
                                $soPath = [System.IO.Path]::GetFullPath($so.Path).TrimEnd('\', '/')
                                if ($null -ne $soPath -and $null -ne $selfExeFull -and [string]::Equals($soPath, $selfExeFull, $pathCmp)) { $isSelf = $true }
                            } catch { }
                            # Command-line fallback: a prior `dotnet MultiAiAgent.dll
                            # --urls=:5104` runs as dotnet.exe (exe path differs from our
                            # apphost), so also match our dll/exe token or output dir in
                            # its command line -- still scoped to OUR project only.
                            # OS-aware: case-insensitive match on Windows, case-sensitive elsewhere.
                            if (-not $isSelf) {
                                try {
                                    if (Get-Command Get-ProcessCommandLine -ErrorAction SilentlyContinue) {
                                        $soCmd = Get-ProcessCommandLine -ProcessId $so.Id
                                        if ($soCmd) {
                                            $cmdMatch = $false
                                            if ($pathCmp -eq [System.StringComparison]::Ordinal) {
                                                if (($projToken -and $soCmd -clike "*$projToken*") -or
                                                    ($outDirCanon -and $soCmd -clike "*$outDirCanon*")) { $cmdMatch = $true }
                                            } else {
                                                if (($projToken -and $soCmd -like "*$projToken*") -or
                                                    ($outDirCanon -and $soCmd -like "*$outDirCanon*")) { $cmdMatch = $true }
                                            }
                                            if ($cmdMatch) { $isSelf = $true }
                                        }
                                    }
                                } catch { }
                            }
                            if (-not $isSelf) { continue }
                            Write-Log (Get-LocaleMessage -Key 'log.build.killedLockingProcess') "Warn" $State
                            try { Stop-Process -Id $so.Id -Force -ErrorAction SilentlyContinue } catch { }
                        }
                    }
                    # Wait for OS to release the port (single source: Environment.Wait-PortRelease)
                    if (Get-Command Wait-PortRelease -ErrorAction SilentlyContinue) {
                        $null = Wait-PortRelease -Port $port -State $State -Mode 'Bindable'
                    } else {
                        $portWaitAttempts = [int](Get-BuildConstant -Key 'PortWaitAttempts' -Fallback 20)
                        $portWaitDelayMs  = [int](Get-BuildConstant -Key 'PortWaitDelayMs' -Fallback 1000)
                        for ($i = 0; $i -lt $portWaitAttempts; $i++) {
                            Start-Sleep -Milliseconds $portWaitDelayMs
                            if (Test-PortBindable -Port $port) { break }
                        }
                    }
                }
                $maxLaunchAttempts = [int](Get-BuildConstant -Key 'WebAppLaunchMaxAttempts' -Fallback 3)
                $launchAttempt = 0
                $portReady = $false
                $lastProc = $null
                $lastDiag = $null

                do {
                    $launchAttempt++
                    $spArgs = @{ FilePath = (Get-SafePath -Path $exePath); ArgumentList = "--urls=$url"; WorkingDirectory = (Get-SafePath -Path $webOutDir); PassThru = $true }
                    $osName = if ($State -and $State.OS) { $State.OS } else { Get-OSPlatform }
                    if ($osName -eq 'Windows') { $spArgs['WindowStyle'] = 'Hidden' }
                    $proc = Start-Process @spArgs
                    Write-Log (Get-LocaleMessage -Key 'log.deploy.webAppLaunchAttempt' -MessageArgs $launchAttempt, $maxLaunchAttempts, $url) "Gray" $State

                    $portReady = Test-WebAppReady -Proc $proc -Url $url -Port $port -State $State
                    $swWeb.Stop()
                    if ($portReady) {
                        Write-Done (Get-LocaleMessage -Key 'log.deploy.appLaunched' -MessageArgs $url) $swWeb.Elapsed.TotalSeconds $State
                        break
                    }

                    # Capture diagnostics for this attempt
                    $diagExit = $null; $diagAlive = $false; $diagPort = $false
                    try {
                        if ($proc) { $proc.Refresh(); $diagAlive = -not $proc.HasExited; if ($proc.HasExited) { $diagExit = $proc.ExitCode } }
                    } catch { }
                    try { $diagPort = Test-PortListening -Port $port } catch { }
                    $lastDiag = @{ Exit=$diagExit; Alive=$diagAlive; Port=$diagPort; PID=$proc.Id }

                    # Never leave the just-launched process behind holding our port:
                    if ($diagAlive -and $proc) {
                        try {
                            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                            $proc.Refresh()
                            Write-Log (Get-LocaleMessage -Key 'log.deploy.terminatedNonReady' -MessageArgs @($launchAttempt, $proc.Id, $port)) 'Warn' $State
                        } catch { }
                    }
                    $lastProc = $proc
                    $proc = $null
                    $swWeb.Restart()
                } while ($launchAttempt -lt $maxLaunchAttempts -and -not $portReady)

                if ($portReady) {
                    if ((Get-Command Open-Target -ErrorAction SilentlyContinue)) { Open-Target -Target $url }
                    Write-Done (Get-LocaleMessage -Key 'log.deploy.appLaunched' -MessageArgs $url) $swWeb.Elapsed.TotalSeconds $State
                } else {
                    # Final sweep: the per-attempt kill above is best-effort
                    # (SilentlyContinue), so ensure the last failed attempt cannot
                    # linger holding the port for the next build.
                    if ($lastProc) {
                        try {
                            $lastProc.Refresh()
                            if (-not $lastProc.HasExited) {
                                Stop-Process -Id $lastProc.Id -Force -ErrorAction SilentlyContinue
                                Write-Log (Resolve-LogMessage -Key 'log.deploy.terminatedLeftover' -MessageArgs @([string]$lastProc.Id, $maxLaunchAttempts) -Fallback 'Terminated leftover web process (pid {0}) after {1} failed attempt(s)') 'Warn' $State
                            }
                        } catch { }
                    }
                    $diagText = "Web app did not become ready at $url after $maxLaunchAttempts attempt(s)"
                    if ($null -ne $lastDiag.Exit) { $diagText += " (last: process exited, code $($lastDiag.Exit); port listening=$($lastDiag.Port))" }
                    elseif ($lastDiag.Alive) { $diagText += " (last: process alive but not serving on port $port)" }
                    else { $diagText += " (last: process no longer alive; port listening=$($lastDiag.Port))" }
                    # Append PID from last process handle if available
                    try { if ($lastProc) { $diagText += " (pid $($lastProc.Id))" } } catch { }
                    Write-Fail $diagText -State $State
                }
             } else { Write-Fail (Get-LocaleMessage -Key 'log.deploy.exeNotFound' -MessageArgs $exePath) -State $State }
             return [bool]$portReady
         } else {
              $buildResult = Start-BuildAndShow -State $State -Project $ProjPath -Tfm $DefaultTfm -OutputSubDir 'blazorwasm' -ProjectType $ProjectType -Incremental:$Incremental
              $buildOk = if (Get-Command Test-RequiredResult -ErrorAction SilentlyContinue) { Test-RequiredResult -Result $buildResult -Operation 'blazor.publish' } else { [bool]$buildResult }
              if (-not $buildOk) { Write-Log (Get-LocaleMessage -Key 'log.deploy.blazorFailed') "Warn" $State; return $false }

             return $true
         }
    }
    return $false
}


<#
.SYNOPSIS
    Publishes a desktop application (WinForms, WinExe, or MAUI Windows).
.DESCRIPTION
    Resolves the target framework and delegates to Start-BuildAndShow with
    appropriate build arguments based on the project type.
.PARAMETER State
    The build state object.
.PARAMETER ProjPath
    Full path to the project file (.csproj).
.PARAMETER WinTfm
    The Windows target framework moniker.
.PARAMETER Tfms
    Array of all target frameworks.
.PARAMETER DefaultTfm
    The default target framework moniker.
.PARAMETER ProjectType
    The project type (WinForms, WinExe, or MAUI).
.PARAMETER Incremental
    If specified, skips clean before build.
#>
function Invoke-DesktopPublish {
    [CmdletBinding()]
    param($State, $ProjPath, $WinTfm, $Tfms, $DefaultTfm, [string]$ProjectType = "", [switch]$Incremental)
    if ($State.OS -ne 'Windows') {
        Write-Log (Resolve-LogMessage -Key 'log.deploy.desktopNeedsWindows' -MessageArgs @([string]$State.OS) -Fallback 'Desktop publish (WinForms/WinExe) requires Windows (current: {0})') 'Warn' $State
        return $false
    }
    if (-not (Get-Command Start-BuildAndShow -ErrorAction SilentlyContinue)) { return $false }
    $targetTfm = if ($WinTfm) { $WinTfm } elseif ($Tfms) { $Tfms[0] } else { "$DefaultTfm-windows" }
    if ($ProjectType -in @('WinForms', 'WinExe')) {
        $result = Start-BuildAndShow -State $State -Project $ProjPath -Tfm $targetTfm -OutputSubDir 'winforms' -ProjectType $ProjectType -Incremental:$Incremental
        if (Get-Command Test-RequiredResult -ErrorAction SilentlyContinue) { return (Test-RequiredResult -Result $result -Operation 'desktop.publish') }
        return [bool]$result
    }
    $winMsixArgs = @("-p:WindowsPackageType=None", "-p:PublishSingleFile=false", "--self-contained", "true")
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try {
            $cfgArgs = Get-BuildConstant -Key 'DeployChoiceArgsWinMsix' -State $State -Fallback $null
            if ($cfgArgs -and @($cfgArgs).Count -gt 0) { $winMsixArgs = @($cfgArgs) }
        } catch { }
    }
    $result = Start-BuildAndShow -State $State -Project $ProjPath -Tfm $targetTfm -OutputSubDir 'win' -BuildArgs $winMsixArgs -ProjectType $ProjectType -Incremental:$Incremental
    if (Get-Command Test-RequiredResult -ErrorAction SilentlyContinue) { return (Test-RequiredResult -Result $result -Operation 'desktop.publish') }
    return [bool]$result
}

<#
.SYNOPSIS
    Unified publish entry point that all menu handlers delegate to.
.DESCRIPTION
    Wraps Start-BuildAndShow with the resolved TFM, output sub-directory and
    build arguments for a given publish target. Centralises the previously
    duplicated Start-BuildAndShow calls from menu choices 2/4/5/6/9/10/11/12.
.PARAMETER State
    The build state object.
.PARAMETER ProjPath
    Full path to the project file (.csproj).
.PARAMETER Tfm
    The target framework moniker to build for.
.PARAMETER OutputSubDir
    Sub-directory under publish-output for this target.
.PARAMETER BuildArgs
    Extra MSBuild arguments (e.g. -p:AndroidPackageFormat=apk).
.PARAMETER ProjectType
    The project type (MAUI, Web, WinForms, ...).
.PARAMETER Incremental
    If specified, skips clean before build.
#>
function Start-ProjectPublish {
    [CmdletBinding()]
    param($State, $ProjPath, $Tfm, $OutputSubDir, [string[]]$BuildArgs = @(), [string]$ProjectType = "", [switch]$Incremental, [switch]$Detailed)
    $operation = "project.publish:$OutputSubDir"
    $result = $null
    if (Get-Command Start-BuildAndShow -ErrorAction SilentlyContinue) {
        try {
            $rawResult = Start-BuildAndShow -State $State -Project $ProjPath -Tfm $Tfm -OutputSubDir $OutputSubDir -BuildArgs $BuildArgs -ProjectType $ProjectType -Incremental:$Incremental
            if (Get-Command ConvertTo-OperationResult -ErrorAction SilentlyContinue) {
                $result = ConvertTo-OperationResult -Value $rawResult -Operation $operation
            } elseif ($rawResult -is [bool]) {
                $result = if ($rawResult) { [PSCustomObject]@{ Status = 'Succeeded'; Operation = $operation; ReasonCode = 'OK'; Message = "$operation succeeded"; ExitCode = 0; DurationMs = 0; Details = $rawResult } } else { [PSCustomObject]@{ Status = 'Failed'; Operation = $operation; ReasonCode = 'FalseResult'; Message = "$operation returned false"; ExitCode = 1; DurationMs = 0; Details = $rawResult } }
            } elseif ($null -eq $rawResult) {
                $result = [PSCustomObject]@{ Status = 'Failed'; Operation = $operation; ReasonCode = 'NullResult'; Message = "$operation returned no result"; ExitCode = 1; DurationMs = 0; Details = $null }
            } else {
                if (Test-DeployValueSuccess -Value $rawResult) {
                    $result = [PSCustomObject]@{ Status = 'Succeeded'; Operation = $operation; ReasonCode = 'OK'; Message = "$operation succeeded"; ExitCode = 0; DurationMs = 0; Details = $rawResult }
                } else {
                    $result = [PSCustomObject]@{ Status = 'Failed'; Operation = $operation; ReasonCode = 'FalseResult'; Message = "$operation failed"; ExitCode = 1; DurationMs = 0; Details = $rawResult }
                }
            }
        } catch {
            $result = [PSCustomObject]@{ Status = 'Failed'; Operation = $operation; ReasonCode = 'Exception'; Message = $_.Exception.Message; ExitCode = 1; DurationMs = 0; Details = $_ }
        }
    } else {
        Write-Fail (Resolve-LogMessage -Key 'log.module.notLoaded' -MessageArgs @('Build') -Fallback 'Build module not loaded.') -State $State
        $result = [PSCustomObject]@{ Status = 'Blocked'; Operation = $operation; ReasonCode = 'ModuleNotLoaded'; Message = 'Build module not loaded.'; ExitCode = 127; DurationMs = 0; Details = $null }
    }
    if ($Detailed) { return $result }
    return ($result.Status -eq 'Succeeded')
}

<#
.SYNOPSIS
    Waits for a web process to start serving over the given URL and port.
.DESCRIPTION
    Level 5 two-phase readiness probe (layered, no duplication):
      Phase 1 = Environment.Test-PortListening (TCP listener fast-poll)
      Phase 2 = Test-UrlServing → Environment.Test-HttpEndpoint (HTTP GET)
    A bare listener that never serves HTTP does not count as ready.
    The aggregate is bounded by $maxAttempts per phase.
.PARAMETER Proc
    The launched process (used to short-circuit when it exits early).
.PARAMETER Url
    The URL the app is expected to serve.
.PARAMETER Port
    The TCP port the app binds to.
.PARAMETER State
    The build state object (optional; used for logging).
.PARAMETER MaxAttempts
    Override for the per-phase attempt budget. Defaults to the
    deploy.webReadinessAttempts constant (30). Exposed explicitly so tests and
    fast-fail callers can bound the probe without editing global config; the
    production call path omits it and behaves exactly as before.
.PARAMETER ProbeDelayMs
    Override for the URL-phase sleep between attempts (deploy.webAppLaunchDelayMs).
.PARAMETER ProbeDelayMinMs
    Override for the port-phase starting sleep (deploy.webAppLaunchDelayMinMs).
.PARAMETER PortProbe
    Pass -PortProbe:$false to skip phase 1. When omitted, the
    deploy.webPortProbe constant decides.
#>
function Test-WebAppReady {
    [CmdletBinding()]
    param($Proc, [string]$Url, [int]$Port, $State,
          [int]$MaxAttempts = 0,
          [int]$ProbeDelayMs = 0,
          [int]$ProbeDelayMinMs = 0,
          [bool]$PortProbe = $true)

    $maxAttempts   = if ($MaxAttempts -gt 0) { $MaxAttempts } else { [int](Get-BuildConstant -Key 'WebReadinessAttempts' -Fallback 30) }
    $probeDelayMs  = if ($ProbeDelayMs -gt 0) { $ProbeDelayMs } else { [int](Get-BuildConstant -Key 'WebAppLaunchDelayMs' -Fallback 250) }
    $probeDelayMin = if ($ProbeDelayMinMs -gt 0) { $ProbeDelayMinMs } else { [int](Get-BuildConstant -Key 'WebAppLaunchDelayMinMs' -Fallback 100) }
    $portProbe     = if ($PortProbe) { [bool](Get-BuildConstant -Key 'WebAppReadyPortProbe' -Fallback $true) } else { $false }
    $portListening = $false
    $started       = [System.Diagnostics.Stopwatch]::StartNew()

    if ($portProbe) {
        $probeDelay = $probeDelayMin
        for ($i = 0; $i -lt $maxAttempts -and -not $portListening; $i++) {
            if (Test-ProcessExited -Proc $Proc -State $State) { break }
            if (Test-PortListening -Port $Port) { $portListening = $true; break }
            Start-Sleep -Milliseconds $probeDelay
            if ($probeDelay -lt $probeDelayMs) { $probeDelay = [Math]::Min($probeDelay * 2, $probeDelayMs) }
        }
    }

    $ready = $false
    $probeDelay = $probeDelayMs
    for ($i = 0; $i -lt $maxAttempts -and -not $ready; $i++) {
        if (Test-ProcessExited -Proc $Proc -State $State) { break }
        if (Test-UrlServing -Url $Url) { $ready = $true; break }
        Start-Sleep -Milliseconds $probeDelay
    }
    $started.Stop()
    return $ready
}

function Test-ProcessExited {
    [CmdletBinding()]
    param($Proc, $State)
    if (-not $Proc) { return $false }
    try {
        if ($Proc.HasExited) {
            Write-Log (Get-LocaleMessage -Key 'log.deploy.processExited' -MessageArgs $Proc.ExitCode) 'Err' $State
            return $true
        }
    } catch { }
    return $false
}

Export-ModuleMember -Function @('Invoke-AndroidAabBuild','Invoke-WebPublish','Invoke-DesktopPublish','Start-ProjectPublish','Test-WebAppReady','Test-UrlServing')






