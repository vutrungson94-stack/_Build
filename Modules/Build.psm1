# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================



# ModuleBootstrap.ps1 self-loads BuildImport.psm1 (defines Import-GBuildModule /
# Import-BuildDependencies) before resolving -Dependencies.

. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @()

# -- Import dependency modules (safe for both standalone and launcher loading) --
Import-BuildModule -Dependencies @('Environment', 'Project', 'Android', 'Clean', 'ErrorHandling', 'EventBus', 'Metrics', 'Loader', 'LanguageDetector', 'BuildProgress')
Import-GBuildModuleIfMissing -Name 'Locale' -SentinelCommand 'Get-LocaleMessage'

# Color resolution delegated to Resolve-SafeColor / Resolve-ConsoleColor from Logging.psm1

<#
.SYNOPSIS
    Loads project-type-specific build actions from config (build.projectTypeActions).
.DESCRIPTION
    Reads build.projectTypeActions from gbuild.config.json. Returns a PSCustomObject
    with properties for each platform condition (android, ios, windows, nonWindows, default)
    and for Library type (command, args). Returns $null if config section is absent.
.PARAMETER State
    The build state object carrying BuildConfig.
.PARAMETER ProjectType
    The detected project type (MAUI, Web, WinForms, etc.).
.OUTPUTS
    PSCustomObject with action arrays or $null.
#>
function Get-ProjectTypeActions {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectType
    )

Set-StrictMode -Version 1.0
    if (-not $State -or -not $State.BuildConfig -or -not $State.BuildConfig.build -or -not $State.BuildConfig.build.projectTypeActions) {
        return $null
    }
    $actions = $State.BuildConfig.build.projectTypeActions
    if (-not $actions.PSObject.Properties.Name -contains $ProjectType) {
        return $null
    }
    return $actions.$ProjectType
}

<#
.SYNOPSIS
    Loads cache artifact patterns from config (build.cacheArtifactPatterns).
.DESCRIPTION
    Reads build.cacheArtifactPatterns from gbuild.config.json. Returns an array of
    patterns for the given OutputSubDir, with ${exeBaseName} placeholder expanded.
    Falls back to *.dll if config section is absent or OutputSubDir not found.
.PARAMETER State
    The build state object carrying BuildConfig.
.PARAMETER OutputSubDir
    The output subdirectory (apk, aab, ios, mac, web, win, winforms, wpf, console, etc.).
.PARAMETER ExeBaseName
    The executable base name (project file name without extension).
.OUTPUTS
    string[] of patterns with placeholders expanded.
#>
function Get-CacheArtifactPatterns {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$OutputSubDir,
        [string]$ExeBaseName = ''
    )
    if (-not $State -or -not $State.BuildConfig -or -not $State.BuildConfig.build -or -not $State.BuildConfig.build.cacheArtifactPatterns) {
        return @('*.dll')
    }
    $patterns = $State.BuildConfig.build.cacheArtifactPatterns
    if (-not $patterns.PSObject.Properties.Name -contains $OutputSubDir) {
        if ($patterns.PSObject.Properties.Name -contains 'default') {
            return @($patterns.default)
        }
        return @('*.dll')
    }
    $raw = @($patterns.$OutputSubDir)
    # Expand ${exeBaseName} placeholder
    $result = @()
    foreach ($p in $raw) {
        if ($p -like '*${exeBaseName}*' -and $ExeBaseName) {
            $result += $p -replace '\$\{exeBaseName\}', $ExeBaseName
        } else {
            $result += $p
        }
    }
    return $result
}

function New-BuildResult {
    [CmdletBinding()]
    param(
        [ValidateSet('Succeeded', 'Failed', 'Skipped', 'Blocked')][string]$Status = 'Succeeded',
        [string]$Operation = 'build',
        [string]$ReasonCode = '',
        [string]$Message = '',
        [int]$ExitCode = 0,
        [object]$Details = $null,
        [string]$OutputPath = ''
    )
    $result = New-OperationResult -Status $Status -Operation $Operation -ReasonCode $ReasonCode -Message $Message -ExitCode $ExitCode -Details $Details
    $result | Add-Member -MemberType NoteProperty -Name OutputPath -Value $OutputPath -Force
    $result | Add-Member -MemberType NoteProperty -Name Skipped -Value ($Status -eq 'Skipped') -Force
    return $result
}

function Get-BuildPluginCacheKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCustomObject]$State,
        [string]$ProjectPath,
        [string]$Tfm,
        [string]$Configuration,
        [string]$InputHash
    )
    if (Get-Command Get-PluginCacheKey -ErrorAction SilentlyContinue) {
        $dotnet = if ($State -and ($State.PSObject.Properties.Name -contains 'DotnetCmd') -and $State.DotnetCmd) { [string]$State.DotnetCmd } else { 'dotnet' }
        $pluginPath = Join-Path $PSScriptRoot 'Plugins/Dotnet.psm1'
        $plugin = @{ Info = @{ Name = 'Dotnet'; Version = '1.0.0'; ToolName = $dotnet }; Path = $pluginPath }
        $key = Get-PluginCacheKey -Plugin $plugin -Language 'C#' -ProjectDir (Split-Path -Parent $ProjectPath) -ProjectFile $ProjectPath -Configuration $Configuration -InputHash $InputHash
        return ($key + '|tfm=' + $Tfm)
    }
    # SharedUtils.Get-BuildStringHash owns the UTF8 -> SHA256 -> lowercase-hex
    # sequence. This was a third inline copy, and the cache-key path hash had
    # already drifted once: Cache.psm1 emitted lowercase and
    # CacheProvider.psm1 emitted UPPERCASE for the same computation, so one
    # cache entry hashed to two different keys depending on which module asked.
    $path = [System.IO.Path]::GetFullPath($ProjectPath)
    $pathHash = Get-BuildStringHash -Text $path
    if (-not $pathHash) { return "build-v2|$path|$Configuration|$Tfm|$InputHash" }
    return "build-v2|$pathHash|$Configuration|$Tfm|$InputHash"
}

<#
.SYNOPSIS
    Run dotnet publish with TFM, output, incremental options, real-time display.
#>
# NOTE: build hooks ('before-build'/'after-build') are fired ONCE per pipeline
# run by Invoke-GBuildHook (Orchestrator — RegisterPlugins step + Start-GBuild
# finally). Do NOT fire them here as well: that double-fired every hook on the
# standard menu flow. The pipeline layer is the single canonical owner because
# it also covers plugin/non-.NET builds, which never enter this module.

function Invoke-AndroidArtifactDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$State,
        [string]$OutputDir,
        [string]$CsprojContent,
        [string]$OutputSubDir,
        [string]$ExeBaseName
    )
    if (-not $OutputDir -or -not (Test-Path $OutputDir)) { return }
    $apkFile = Get-ChildItem -Path $OutputDir -Filter "*Signed*.apk" -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $apkFile) {
        $apkFile = Get-ChildItem -Path $OutputDir -Filter "*.apk" -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($apkFile) {
        $appIdMatch = [regex]::Match($CsprojContent, '<ApplicationId>([^<]+)</ApplicationId>')
        $appId = if ($appIdMatch.Success) { $appIdMatch.Groups[1].Value.Trim() } else { [string](Get-BuildConstant -Key 'AndroidDefaultApplicationId' -State $State -Fallback 'com.companyname.app') }
        Write-Log ' '
        Invoke-AutoDeploy -State $State -ApkPath $apkFile.FullName -AppId $appId -AndroidSdkPath $State.AndroidSdk
    }
}

function Invoke-BuildOutputReveal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$State,
        [string]$OutputDir,
        [string]$ProjectType
    )
    if (-not $OutputDir -or -not (Test-Path -LiteralPath $OutputDir)) { return }
    # Single source: SharedUtils.Resolve-BuildOpenOutput (explicit
    # build.openOutput wins; CI/non-interactive never opens). The previous
    # inline read of an undocumented config key defaulted to never opening,
    # with no schema entry and no way to discover the knob.
    $openOutput = $false
    try {
        if (Get-Command Resolve-BuildOpenOutput -ErrorAction SilentlyContinue) { $openOutput = [bool](Resolve-BuildOpenOutput -State $State) }
    } catch { $openOutput = $false }
    Write-Log (Get-LocaleMessage -Key 'log.build.output' -MessageArgs @($OutputDir)) 'Succ' $State
    if ($openOutput -and (Get-Command Open-Target -ErrorAction SilentlyContinue)) {
        try { Open-Target $OutputDir -State $State } catch { Write-Log (Get-LocaleMessage -Key 'log.build.autoOpenFailed' -MessageArgs @($OutputDir)) 'Warn' $State }
    }
}

function Start-BuildAndShow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$State,
        [string]$Project,
        [string]$Tfm,
        [string]$OutputSubDir,
        [string[]]$BuildArgs,
        [string]$ProjectType = "",
        [string]$Configuration = '',
        [switch]$Incremental,
        [switch]$Detailed
    )
    try { if ($null -eq $ProjectType) { $ProjectType = "" } } catch { $ProjectType = "" }
    if ([string]::IsNullOrWhiteSpace($Project) -or -not (Test-Path -LiteralPath $Project -PathType Leaf -EA SilentlyContinue)) {
        if ($Detailed) { return New-BuildResult -Status Failed -Operation 'build' -ReasonCode 'ProjectMissing' -Message 'Project file was not found' }
        return $false
    }
    Set-StateColors -State $State
    if ([string]::IsNullOrWhiteSpace($Configuration)) {
        try { $Configuration = [string](Get-BuildConstant -Key 'DefaultConfiguration' -State $State -Fallback 'Release') } catch { $Configuration = 'Release' }
        try {
            if ($State.ActiveProfile -and $State.BuildConfig -and $State.BuildConfig.profiles) {
                $profile = $State.BuildConfig.profiles.($State.ActiveProfile)
                if ($profile -and $profile.configuration) { $Configuration = [string]$profile.configuration }
            }
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = 'Release' }
    $projectDir = Split-Path -Parent $Project
    $resolvedProjectDir = try { (Get-Item -LiteralPath $projectDir -EA Stop).FullName } catch { $null }
    if (-not $resolvedProjectDir -or -not (Test-Path -LiteralPath $resolvedProjectDir -PathType Container)) {
        # Was a hardcoded 'Project directory was not found'. log.build.projectDirNotFound
        # shipped translated in all 7 locales and was never emitted, so this - the
        # single most common misconfiguration - was always reported in English.
        $msg = Get-LocaleMessage -Key 'log.build.projectDirNotFound' -MessageArgs @($projectDir)
        Write-Log $msg 'Warn' $State
        if ($Detailed) { return New-BuildResult -Status Failed -Operation 'build' -ReasonCode 'ProjectDirectoryMissing' -Message $msg }
        return $false
    }
    Import-GBuildModuleIfMissing -Name 'LanguageDetector' -SentinelCommand 'Get-PrimaryLanguage'
    $lang = Get-PrimaryLanguage -SearchRoot $resolvedProjectDir -State $State
    if (-not $lang) {
        Write-Log (Get-LocaleMessage -Key 'log.build.detectFailed' -MessageArgs $Project) 'Warn' $State
        if ($Detailed) { return New-BuildResult -Status Failed -Operation 'build' -ReasonCode 'LanguageDetectionFailed' -Message 'Project language could not be detected' }
        return $false
    }
    Write-Log (Get-LocaleMessage -Key 'log.build.detectedLang' -MessageArgs $lang.Language) 'Info' $State
    $dotnetLangs = if (Get-Command Get-DotnetLanguages -ErrorAction SilentlyContinue) { @(Get-DotnetLanguages) } else { @('C#', 'F#', 'VB.NET') }
    $isDotnetProject = $lang.Language -in ($dotnetLangs + @('Avalonia', 'LinuxDesktop'))
    if (-not $isDotnetProject) {
        Write-Log (Get-LocaleMessage -Key 'log.build.nonDotnet') 'Info' $State
        $dispatchFile = $Project
        if ($lang.PSObject.Properties.Name -contains 'BuildFilePath' -and $lang.BuildFilePath) { $dispatchFile = [string]$lang.BuildFilePath }
        $pluginResult = Invoke-PluginBuildFor -State $State -Language $lang.Language -ProjectDir $resolvedProjectDir -ProjectFile $dispatchFile -Configuration $Configuration -Incremental:$Incremental -Detailed:$Detailed
        if ($Detailed) { return $pluginResult }
        return [bool]$pluginResult
    }
    # Canonical resolver: picks a dotnet muxer that actually has an SDK, honouring
    # DOTNET_ROOT via Get-SmartSdk. The old code resolved by name/PATH only and
    # cached whatever it found into State.DotnetCmd, so on a machine where a
    # runtime-only muxer precedes the real SDK on PATH, that SDK-less path was
    # pinned for the rest of the build (and every later stage inherited it).
    $dotnet = ''
    if (Get-Command Resolve-DotnetSdkCommand -ErrorAction SilentlyContinue) {
        try {
            $preferred = ''
            if ($State.PSObject.Properties.Name -contains 'DotnetCmd') {
                # Pick the first STRING element: State.DotnetCmd can be a polluted
                # array, and [string] on the whole array yields 'True C:\...'.
                $values = @(@($State.DotnetCmd) | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) })
                if ($values.Count -gt 0) { $preferred = [string]$values[0] }
            }
            $dotnet = [string](Resolve-DotnetSdkCommand -State $State -PreferredPath $preferred)
        } catch { $dotnet = '' }
    }
    if ([string]::IsNullOrWhiteSpace($dotnet)) {
        # No SDK-capable muxer anywhere. Fall back to the legacy lookup so the
        # build still runs (msbuild may work from a runtime-only install for some
        # project shapes) and reports DotnetMissing only if nothing at all exists.
        $legacyName = 'dotnet'
        if ($State.PSObject.Properties.Name -contains 'DotnetCmd') {
            $legacyValues = @(@($State.DotnetCmd) | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) })
            if ($legacyValues.Count -gt 0) { $legacyName = [string]$legacyValues[0] }
        }
        $legacyCmd = Get-Command -Name $legacyName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $legacyCmd -and (Test-Path -LiteralPath $legacyName -PathType Leaf)) { $legacyCmd = [PSCustomObject]@{ Source = $legacyName; Path = $legacyName } }
        if (-not $legacyCmd) { $legacyCmd = Get-Command -Name $legacyName -ErrorAction SilentlyContinue | Where-Object { $_.Source -or $_.Path } | Select-Object -First 1 }
        if (-not $legacyCmd) {
            Write-Log (Get-LocaleMessage -Key 'log.build.dotnetCmdNull' -Fallback 'dotnet is required for this project type') 'Err' $State
            if ($Detailed) { return New-BuildResult -Status Failed -Operation 'build' -ReasonCode 'DotnetMissing' -Message 'dotnet is required for this project type' }
            return $false
        }
        $dotnet = if ($legacyCmd.Source) { [string]$legacyCmd.Source } else { [string]$legacyCmd.Path }
    }
    if ($State.PSObject.Properties.Name -contains 'DotnetCmd') { $State.DotnetCmd = $dotnet }
    else { $State | Add-Member -MemberType NoteProperty -Name DotnetCmd -Value $dotnet -Force }
    $publishOutputDir = Resolve-PublishOutputDir -State $State
    $projectRoot = if ($State.PSObject.Properties.Name -contains 'ProjectRoot' -and $State.ProjectRoot) { [string]$State.ProjectRoot } else { $resolvedProjectDir }
    $rawOut = Join-Path (Join-Path $projectRoot $publishOutputDir) $OutputSubDir
    $exeBaseName = [System.IO.Path]::GetFileNameWithoutExtension($Project)
    $isProgressActive = $false

    $csprojContent = Get-Content -Path $Project -Raw -Encoding UTF8 -EA SilentlyContinue
    $projectSelfContainedFalse = $false
    if ($csprojContent -match '(?is)<SelfContained\b[^>]*>\s*false\s*</SelfContained>' -or $csprojContent -match '(?is)<SelfContained\b[^>]*/>') {
        $projectSelfContainedFalse = $true
    }

    # 2. If Web project -> Auto-check port conflicts
    $actualMeta = Get-ProjectMetadata -CsprojPath $Project
    $actualType = if ($actualMeta -and $actualMeta.ProjectType) { [string]$actualMeta.ProjectType } else { "" }
    # Self-healing: when the orchestrator passed ''/'Unknown' (or $null under a
    # strict caller), prefer the freshly detected type so downstream clean/publish
    # never operates on an empty project type.
    if ([string]::IsNullOrWhiteSpace($ProjectType) -or $ProjectType -eq 'Unknown') {
        if (-not [string]::IsNullOrWhiteSpace($actualType)) { $ProjectType = $actualType }
    }

    if ($actualType -eq 'Web') {
        Write-Log (Get-LocaleMessage -Key 'log.build.webPortCheck') $State.Colors.Gray $State
        try {
            $ports = Get-LaunchSettingsPorts -ProjectDir $resolvedProjectDir -EA Stop
        } catch {
            $ports = @()
        }

        if ($ports -and $ports.Count -gt 0) {
            foreach ($port in $ports) {
                if (Test-PortListening -Port $port) {
                    Write-Log (Get-LocaleMessage -Key 'log.build.portOccupied' -MessageArgs $port) $State.Colors.Warn $State

                    Stop-ProcessByPort -State $State -ProjectDir $resolvedProjectDir -ProjectType $actualType -ExeName $exeBaseName -OutputDir $rawOut

                    # Wait for OS to release Port (single source: Environment.Wait-PortRelease)
                    $portFreed = if (Get-Command Wait-PortRelease -ErrorAction SilentlyContinue) {
                        Wait-PortRelease -Port $port -State $State -Mode 'Listening'
                    } else {
                        $portAttempts = [int](Get-BuildConstant -Key 'PortWaitAttempts' -Fallback 20)
                        $freed = $false
                        for ($i = 0; $i -lt $portAttempts; $i++) {
                            Start-Sleep -Milliseconds (Get-BuildConstant -Key 'PortWaitDelayMs' -Fallback 1000)
                            if (-not (Test-PortListening -Port $port)) { $freed = $true; break }
                        }
                        $freed
                    }

                    if ($portFreed) {
                        Write-Log (Get-LocaleMessage -Key 'log.build.portReleased' -MessageArgs $port) $State.Colors.Succ $State
                    } else {
                        Write-Log (Get-LocaleMessage -Key 'log.build.portManual' -MessageArgs $port) $State.Colors.Err $State
                    }
                }
            }
        }
    }

    # 3. If directly compiling Android project, need device connection
    if ($actualType -eq 'MAUI' -or $OutputSubDir -match 'apk|aab') {
        Write-Log (Get-LocaleMessage -Key 'log.build.androidScan') $State.Colors.Gray $State
        $adbPath = Find-AdbPath -State $State
        if ($adbPath -and (Test-Path -Path $adbPath)) {
            $devices = Get-AdbDevices -State $State -AdbPath $adbPath
            if ($devices -and $devices.Count -gt 0) {
                Write-Log (Get-LocaleMessage -Key 'log.build.devicesFound' -MessageArgs $devices.Count) $State.Colors.Succ $State
                foreach ($d in $devices) {
                    $manufacturer = (& $adbPath -s $d shell getprop ro.product.manufacturer 2>&1 | Out-String).Trim()
                    $model = (& $adbPath -s $d shell getprop ro.product.model 2>&1 | Out-String).Trim()
                    $deviceInfo = if ($manufacturer -or $model) { "$d  ($manufacturer $model)" } else { $d }
                    Write-Log (Get-LocaleMessage -Key 'log.build.deviceInfo' -MessageArgs $deviceInfo) $State.Colors.Gray $State
                }
            } else {
                Write-Log (Get-LocaleMessage -Key 'log.build.noDevices') $State.Colors.Warn $State
            }
        } else {
            Write-Log (Get-LocaleMessage -Key 'log.build.adbNotFound') $State.Colors.Warn $State
        }
    }

    # 4. Kill processes occupying OutputDir
    Stop-ProcessByPort -State $State -ProjectDir $projectDir -ProjectType $ProjectType -ExeName $exeBaseName -OutputDir $rawOut

    # Kill additional processes holding files in rawOut.
    # Kill list single-sourced from BuildConstants.BuildKillProcesses
    # (config build.processKillList overrides when present).
    $killList = @(Get-ConfigValue -Path 'build.processKillList' -State $State -Default (Get-BuildConstant -Key 'BuildKillProcesses' -Fallback @('dotnet', 'iisexpress')))
    $killNames = @($exeBaseName) + $killList | Select-Object -Unique
    $lockedProcs = @()
    if ($State.OS -eq 'Windows') {
        $suspiciousProcs = Get-Process -Name $killNames -ErrorAction SilentlyContinue
        $lockedProcs = $suspiciousProcs | Where-Object {
            try { if ($_.Path -like "$rawOut\*") { return $true } } catch { }
            return $false
        }
    } else {
        $suspiciousProcs = Get-Process -Name $killNames -ErrorAction SilentlyContinue
        foreach ($proc in $suspiciousProcs) {
            $pPath = $null
            try {
                if ($proc.Path) { $pPath = $proc.Path }
                elseif (Test-Path "/proc/$($proc.Id)/exe") {
                    try { $pPath = (Get-Item "/proc/$($proc.Id)/exe").Target } catch { }
                }
            } catch { }
            if ($pPath -and $pPath.StartsWith($rawOut, [System.StringComparison]::Ordinal)) {
                $lockedProcs += $proc
            }
        }
    }
    if ($lockedProcs) {
        $lockedProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Log (Get-LocaleMessage -Key 'log.build.killedLockingProcess') $State.Colors.Succ $State
    }

    # -- 5b. Cache check (BEFORE backup/SmartClean!). Ordering matters: a HIT must
    # skip the destructive backup-copy + SmartClean phase entirely, otherwise the
    # freshly-cleaned output dir makes a cached build look like it produced nothing.
    # Single Get-ProjectHash here is reused for the post-build save via
    # Save-BuildCacheEntry (no double hashing).
    $cacheKey = ''
    $cacheEnabled = Get-ConfigValue -Path 'build.enableBuildCache' -State $State -Type bool
    $isForce = [bool]($State -and $State.ForceBuild)
    if ($isForce) { Write-Log (Get-LocaleMessage -Key 'log.build.forceBypass') 'Warn' $State }
    $cacheFlow = $false
    $projectHash = $null
    if (-not $isForce -and $cacheEnabled -and (Get-Command Test-CacheValid -EA SilentlyContinue) -and (Get-Command Get-ProjectHash -EA SilentlyContinue)) {
        $cacheFlow = $true
        $projectHash = Get-ProjectHash -ProjectPath $Project
        $cacheKey = Get-BuildPluginCacheKey -State $State -ProjectPath $Project -Tfm $Tfm -Configuration $Configuration -InputHash ([string]$projectHash)
        if (-not $projectHash) {
            $cacheFlow = $false
            Write-Log (Get-LocaleMessage -Key 'log.cache.cannotCompute' -Fallback '??  [Cache] Cannot compute hash. Skipping cache.') 'Warn' $State
        } else {
            $hashLen = 8
            try {
                if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                    $hashLen = [int](Get-BuildConstant -Key 'ShortHashLength' -State $State -Fallback 8)
                }
            } catch { $hashLen = 8 }
            if ($hashLen -le 0) { $hashLen = 8 }
            if ($hashLen -gt $projectHash.Length) { $hashLen = $projectHash.Length }
            $shortHash = $projectHash.Substring(0, $hashLen)
            Write-Log (Get-LocaleMessage -Key 'log.cache.hash' -MessageArgs @([string]$shortHash) -Fallback "?? [Cache] Hash: $shortHash") 'Gray' $State
            if (Test-CacheValid -Key $cacheKey -ProjectHash $projectHash) {
                # Stale-artifact guard: a cache hit is only valid when the previous
                # outputs still exist on disk (they may have been cleaned by the
                # user, an interrupted run, or an older gbuild version).
                $hasArtifacts = $false
                if (Test-Path -LiteralPath $rawOut) {
                    # Config-driven primary artifact patterns (build.cacheArtifactPatterns)
                    $patterns = Get-CacheArtifactPatterns -State $State -OutputSubDir $OutputSubDir -ExeBaseName $exeBaseName
                    $primaryPattern = if ($patterns.Count -gt 0) { $patterns[0] } else { '*.dll' }
                    # web/console need exact primary exe; dll-only is stale for self-contained publish
                    if ($OutputSubDir -in @('web','console') -and $exeBaseName) {
                        $exeSuffix = if (Get-Command Get-ExecutableExtension -ErrorAction SilentlyContinue) { Get-ExecutableExtension -State $State -Fallback '.exe' } elseif ($State.OS -eq 'Windows') { '.exe' } else { '' }
                        $expectedExe = Join-Path $rawOut ($exeBaseName + $exeSuffix)
                        $hasArtifacts = Test-Path -LiteralPath $expectedExe -PathType Leaf
                        # No dll fallback: it masked missing primary exe (dll remained while exe deleted)
                        # Framework-dependent case still has exe, so strict exe check is correct
                    } elseif ($OutputSubDir -in @('apk','aab','ios')) {
                        $found = @(Get-ChildItem -Path $rawOut -Recurse -File -Include $primaryPattern -ErrorAction SilentlyContinue)
                        $hasArtifacts = ($found.Count -gt 0)
                    } elseif ($OutputSubDir -eq 'mac' -and $primaryPattern -eq '*.app') {
                        $found = @(Get-ChildItem -Path $rawOut -Recurse -Directory -Filter '*.app' -ErrorAction SilentlyContinue)
                        if ($found.Count -eq 0) {
                            $found = @(Get-ChildItem -Path $rawOut -Recurse -File -Include '*.dmg','*.pkg' -ErrorAction SilentlyContinue)
                        }
                        $hasArtifacts = ($found.Count -gt 0)
                    } else {
                        $found = @(Get-ChildItem -Path $rawOut -Recurse -File -Include $primaryPattern -ErrorAction SilentlyContinue)
                        $hasArtifacts = ($found.Count -gt 0)
                    }
                }
                if (-not $hasArtifacts) {
                    Write-Log (Get-LocaleMessage -Key 'log.cache.staleNoOutput' -Fallback '? [Cache] HIT but output directory has no artifacts - rebuilding.') 'Warn' $State
                    if (Get-Command Remove-CacheEntry -ErrorAction SilentlyContinue) {
                        Remove-CacheEntry -Key $cacheKey -ErrorAction SilentlyContinue
                    }
                    if (Get-Command Submit-CacheMetric -ErrorAction SilentlyContinue) {
                        Submit-CacheMetric -Result 'stale' -Project ([System.IO.Path]::GetFileNameWithoutExtension($Project)) -CacheKey $cacheKey | Out-Null
                    }
                    # Fall through to the MISS path below and rebuild.
                } else {
                    $entry = Get-CacheEntry -Key $cacheKey
                    Write-Log (Get-LocaleMessage -Key 'log.cache.hit' -MessageArgs @([string]$entry.CreatedAt) -Fallback "? [Cache] HIT! Skip build (reused from $($entry.CreatedAt))") 'Succ' $State
                    if (Get-Command Submit-BuildMetric -ErrorAction SilentlyContinue) {
                        Submit-BuildMetric -State $State -Step 'CacheHit' -Success $true -ProjectName ([System.IO.Path]::GetFileNameWithoutExtension($Project)) -Configuration $Tfm | Out-Null
                    }
                    if (Get-Command Submit-CacheMetric -ErrorAction SilentlyContinue) {
                        Submit-CacheMetric -Result 'hit' -Project ([System.IO.Path]::GetFileNameWithoutExtension($Project)) -CacheKey $cacheKey | Out-Null
                    }
                    if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                        Send-BuildEvent -EventName $EVT_CACHE_HIT -Source $State -Data @{ Key = $cacheKey; Project = [System.IO.Path]::GetFileNameWithoutExtension($Project) } | Out-Null
                    }
                    if ($actualType -eq 'MAUI' -or $OutputSubDir -match 'apk|aab') {
                        Invoke-AndroidArtifactDeploy -State $State -OutputDir $rawOut -CsprojContent $csprojContent -OutputSubDir $OutputSubDir -ExeBaseName $exeBaseName
                    }
                    # Cache hit must surface the output dir exactly like the rebuild
                    # path below does (identical [OUTPUT] print + Explore). Printed
                    # directly so the reveal never depends on Open-Target quirks;
                    # opening the folder is best-effort and must not abort the hit.
                    if ($ProjectType -ne 'Library') {
                        Invoke-BuildOutputReveal -State $State -OutputDir $rawOut -ProjectType $ProjectType
                    }
                     if ($Detailed) { return New-BuildResult -Status Succeeded -Operation 'build' -ReasonCode 'CacheHit' -Message 'Build cache hit' -Details $entry -OutputPath $rawOut }
                     return $true
                }
            }
            # Genuine miss or stale-hit fallthrough — either way we rebuild.
            Write-Log (Get-LocaleMessage -Key 'log.cache.miss' -Fallback '? [Cache] MISS. Running build...') 'Info' $State
            if (Get-Command Submit-BuildMetric -ErrorAction SilentlyContinue) {
                Submit-BuildMetric -State $State -Step 'CacheMiss' -Success $true -ProjectName ([System.IO.Path]::GetFileNameWithoutExtension($Project)) -Configuration $Tfm | Out-Null
            }
            if (Get-Command Submit-CacheMetric -ErrorAction SilentlyContinue) {
                Submit-CacheMetric -Result 'miss' -Project ([System.IO.Path]::GetFileNameWithoutExtension($Project)) -CacheKey $cacheKey | Out-Null
            }
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                Send-BuildEvent -EventName $EVT_CACHE_MISS -Source $State -Data @{ Key = $cacheKey; Project = [System.IO.Path]::GetFileNameWithoutExtension($Project) } | Out-Null
            }
        }
    }

    # Cache-state rollback: a failed build purges the stale entry so the next run
    # does not false-hit. Registered here (after $cacheKey exists) - the previous
    # location referenced $cacheKey before definition and silently never fired.
    # GetNewClosure is REQUIRED: Invoke-Rollback invokes these scriptblocks from
    # ErrorHandling's scope, where free variables ($State) resolve to $null —
    # the rollback then ran silently without logging.
    if ($cacheEnabled -and (Get-Command Register-RollbackAction -ErrorAction SilentlyContinue)) {
        Register-RollbackAction -Name 'PurgeBuildCache' -Context @{ Key = $cacheKey } -Action {
            param($ctx)
            if (Get-Command Remove-CacheEntry -ErrorAction SilentlyContinue) {
                try {
                    Remove-CacheEntry -Key $ctx.Key | Out-Null
                    Write-Log (Get-LocaleMessage -Key 'log.build.purgedCache') $State.Colors.Succ $State
                } catch {
                    # benign - cache entry may already be gone
                }
            }
        }.GetNewClosure()
    }

    # 5. Clean artifact output (with rollback backup)
    # Fallback: honor config enableIncremental when the switch was not explicitly passed
    # (Orchestrator auto-sets it, but direct calls like Start-ProjectPublish may omit it).
    $effectiveIncremental = $Incremental
    if (-not $effectiveIncremental -and (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue)) {
        $cfgInc2 = Get-ConfigValue -Path 'build.enableIncremental' -State $State -Default $false
        if ($cfgInc2) { $effectiveIncremental = $true }
    }
    if ($State -and $State.ForceBuild) { $effectiveIncremental = $false }
    # MAUI rebuilds MUST clean bin/obj regardless of enableIncremental: a stale
    # MSBuild/XAML/R.java incremental state (dotnet/MAUI known issue) can serve the
    # PREVIOUS build's UI even after the programmer changed code. The source-hash
    # cache already guarantees a rebuild only happens when code changed, so forcing a
    # clean here always compiles the latest edits while the HIT path (no code change)
    # skips build entirely for speed. Other project types keep incremental behavior.
    if ($ProjectType -eq 'MAUI') { $effectiveIncremental = $false }
    $outputBackupDir = $null
    if (-not $effectiveIncremental) {
        if ((Test-Path $rawOut) -and (Get-ChildItem -Path $rawOut -ErrorAction SilentlyContinue)) {
            $outputBackupDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gbuild_restore_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            try {
                Copy-Item -Path $rawOut -Destination $outputBackupDir -Recurse -Force -ErrorAction Stop
                Register-RollbackAction -Name 'RestoreOutputDir' -Context @{ BackupDir = $outputBackupDir; TargetDir = $rawOut } -Action {
                    param($ctx)
                    if ($ctx.BackupDir -and (Test-Path $ctx.BackupDir)) {
                        if (Test-Path $ctx.TargetDir) { Remove-Item -Path $ctx.TargetDir -Recurse -Force -ErrorAction SilentlyContinue }
                        Copy-Item -Path $ctx.BackupDir -Destination $ctx.TargetDir -Recurse -Force -ErrorAction SilentlyContinue
                        # Remove the backup itself after a successful restore — otherwise
                        # every failed build leaked a full gbuild_restore_* tree in %TEMP%.
                        Remove-Item -Path $ctx.BackupDir -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Log (Get-LocaleMessage -Key 'log.build.restoredBackup' -MessageArgs $ctx.BackupDir) $State.Colors.Succ $State
                    } elseif ($ctx.BackupDir) {
                        # Backup already gone: nothing to restore, just clean the path.
                        Remove-Item -Path $ctx.BackupDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }.GetNewClosure()
                Write-Log (Get-LocaleMessage -Key 'log.build.backedUpRollback') $State.Colors.Succ $State
            } catch {
                # Backup copy failed: clean the partial dir immediately so no
                # gbuild_restore_* residue stays in %TEMP%.
                if ($outputBackupDir -and (Test-Path $outputBackupDir)) {
                    Remove-Item -Path $outputBackupDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                $outputBackupDir = $null
            }
        }
        Invoke-SmartClean -State $State -ProjectDir $projectDir -OutputSubDir $OutputSubDir -CsprojPath $Project -ProjectType $ProjectType -CleanOutputDir
    } else {
        Write-Log (Get-LocaleMessage -Key 'log.build.incrementalSkipCleanup') $State.Colors.Cyan $State
    }

    if (-not (Test-Path -Path $rawOut)) {
        [System.IO.Directory]::CreateDirectory($rawOut) | Out-Null
    }
    Write-Log (Get-LocaleMessage -Key 'log.build.outputReady') $State.Colors.Succ $State

    # -- 6. Check platform & Build Params --
    $isAndroidPlatform = $Tfm -match 'android'
    $isApplePlatform   = $Tfm -match '(ios|maccatalyst)'
    $isWindowsPlatform = $Tfm -match 'windows'

    if ($isAndroidPlatform) {
        if (-not $State.AndroidSdk) {
            Write-Log (Get-LocaleMessage -Key 'log.build.missingAndroidSdk') $State.Colors.Err $State
            if ($Detailed) { return New-BuildResult -Status Failed -Operation 'build' -ReasonCode 'AndroidSdkMissing' -Message 'Android SDK is required' }
            return $false
        }
        if (-not $State.JavaSdk) {
            Write-Log (Get-LocaleMessage -Key 'log.build.missingJavaSdk') $State.Colors.Err $State
            if ($Detailed) { return New-BuildResult -Status Failed -Operation 'build' -ReasonCode 'JavaSdkMissing' -Message 'Java SDK is required' }
            return $false
        }
    }

    $safeRawOut  = Get-SafePath -Path $rawOut
    $safeProject = Get-SafePath -Path $Project

    Write-Log (Get-LocaleMessage -Key 'log.build.dotnetCmd' -MessageArgs $State.DotnetCmd) $State.Colors.Gray $State
    Write-Log (Get-LocaleMessage -Key 'log.build.tfmOutput' -MessageArgs @($Tfm, $rawOut)) $State.Colors.Gray $State
        Write-Log (Get-LocaleMessage -Key 'log.build.projectType' -MessageArgs $ProjectType) $State.Colors.Gray $State

    $buildConfigName = if ([string]::IsNullOrWhiteSpace($Configuration)) { [string](Get-BuildConstant -Key 'DefaultConfiguration' -State $State -Fallback 'Release') } else { $Configuration }
    if ([string]::IsNullOrWhiteSpace($buildConfigName)) { $buildConfigName = 'Release' }

    # (Cache check moved to step 5b — BEFORE backup/SmartClean — so a HIT never
    # skips a publish whose outputs were just wiped by the cleanup phase.)

    $params = @(
        "publish", $safeProject,
        "-f", $Tfm,
        "-c", $buildConfigName,
        "--output", $safeRawOut
    )

    # === Platform-type dispatcher (config-driven via build.projectTypeActions) ===
    $projectTypeActions = Get-ProjectTypeActions -State $State -ProjectType $ProjectType
    if ($projectTypeActions) {
        $action = $null
        if ($isAndroidPlatform -and $projectTypeActions.android) { $action = $projectTypeActions.android }
        elseif ($isApplePlatform -and $projectTypeActions.ios) { $action = $projectTypeActions.ios }
        elseif ($isWindowsPlatform -and $projectTypeActions.windows) { $action = $projectTypeActions.windows }
        elseif (-not $isWindowsPlatform -and -not $isAndroidPlatform -and -not $isApplePlatform -and $projectTypeActions.nonWindows) { $action = $projectTypeActions.nonWindows }
        elseif ($projectTypeActions.default) { $action = $projectTypeActions.default }

        if ($action) {
            $expanded = @()
            $skipNext = $false
            foreach ($arg in $action) {
                $argText = [string]$arg
                if ($argText -eq '${rid}') {
                    $argText = [string](Get-RuntimeIdentifier)
                } elseif ($argText -eq '${consoleSelfContained}') {
                    $argText = [string](Get-BuildConstant -Key 'DeployConsoleSelfContained' -State $State -Fallback 'true')
                }
                if ($projectSelfContainedFalse -and $skipNext) {
                    $skipNext = $false
                    if ($argText -match '(?i)^(true|false)$') { continue }
                }
                if ($projectSelfContainedFalse -and $argText -eq '--self-contained') {
                    $skipNext = $true
                    continue
                }
                $expanded += $argText
            }
            $params += $expanded
        }
    }

    # Fallback for Library type (uses 'build' instead of 'publish')
    if ($ProjectType -eq 'Library' -and (-not $projectTypeActions -or -not $projectTypeActions.command)) {
        Write-Log (Get-LocaleMessage -Key 'log.build.librarySwitch') $State.Colors.Warn $State
        $params = @("build", $safeProject, "-f", $Tfm, "-c", $buildConfigName, "--output", $safeRawOut)
    } elseif ($ProjectType -eq 'Library' -and $projectTypeActions.command) {
        $params = @($projectTypeActions.command, $safeProject, "-f", $Tfm, "-c", $buildConfigName, "--output", $safeRawOut)
        if ($projectTypeActions.args) { $params += $projectTypeActions.args }
    } elseif (-not $projectTypeActions) {
        Write-Log (Get-LocaleMessage -Key 'log.build.unknownType' -MessageArgs $ProjectType) $State.Colors.Warn $State
    }

    if ($isAndroidPlatform) {
        $params += "-p:AndroidSdkDirectory=$($State.AndroidSdk)"
        $params += "-p:JavaSdkDirectory=$($State.JavaSdk)"
    }

    if ($BuildArgs) { $params += $BuildArgs }
    $buildCfg = Get-ConfigSection -State $State -Path 'build'
    $msbVerbosity = Get-ConfigValue -Path 'dotnet.verbosity' -State $State -Default 'minimal'
    $parallelArgs = @(Get-BuildConstant -Key 'MsBuildParallelArgs' -State $State -Fallback @("-p:BuildInParallel=true", "-m"))
    if ($buildCfg -and $buildCfg.enableParallelBuild -eq $false) {
        $params += "-v", $msbVerbosity
    } else {
        $params += $parallelArgs + @("-v", $msbVerbosity)
    }

    Write-Log ' ' 'Detail' $State
    try {
        Write-Sep
        Write-SubLog (Get-LocaleMessage -Key 'log.build.publishHeader' -MessageArgs @($Tfm))
        Write-Sep
    } catch {
        Write-Log (Get-LocaleMessage -Key 'log.build.publishHeader' -MessageArgs $Tfm) $State.Colors.Info $State
    }

    # -- 7. Execute Build process (live streaming output) --
    # Wrapped in Invoke-WithRetry (exponential backoff, config-driven maxRetries/baseDelayMs).
    # Invoke-WithLiveOutput streams dotnet output to the console as it arrives and
    # emits a heartbeat when the child is silent (MAUI AOT/dex phases), while still
    # collecting every line for the post-build summary and retry semantics.
    $sw        = [System.Diagnostics.Stopwatch]::StartNew()
    $copyCount = 0; $warnCount = 0; $errCount = 0
    $isProgressActive = $false

    $glyphs = Get-BuildConstant -Key 'Glyphs' -Fallback @{ error = '[x]'; warn = '[!]'; ok = '[v]'; gear = '[*]'; package = '[P]' }

    # dotnet publish emits one "Deleting: <file>" line per removed output file,
    # which otherwise floods the console with hundreds of lines. Consolidate them
    # into a SINGLE in-place progress line (col1 = N/M deletion progress, col2 =
    # the current file) via CR overwrite � exactly like the heartbeat spin. State
    # is carried in a reference hashtable (not plain vars) so it persists across
    # the OnLine callback scope boundary reliably (BuildProgress contract).
    $delState = @{
        IsActive = $false
        UseCR    = $false
        Count    = 0
        Total    = 0
        LineLen  = 0
    }
    try {
        $isCI = [bool]($State -and ($State.IsCI -or $State.NonInteractive))
        $delState.UseCR = (-not $isCI) -and $Host.UI.RawUI -and $Host.UI.RawUI.CursorSize -ge 0
    } catch { $delState.UseCR = $false }

    # Per-line classifier: displays immediately (error red / warning yellow /
    # milestone info / throttled gear gray) and counts for the summary. Runs on
    # the caller scope via the helper's main-thread drain, so these counters work.
    # Classification + excerpt single-sourced via BuildProgress.Test-BuildOutputLine /
    # Get-BuildOutputExcerpt (same engine as the built-in handler — no drifted copies).
    $liveLine = {
        param($rawLine)
        $line = if ($null -eq $rawLine) { '' } else { $rawLine.ToString().TrimEnd() }
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        if ($line -match '^\s*Copying file from') { $copyCount++; return }
        # Consolidate "Deleting:" progress lines into one in-place CR overwrite.
        if ($line -match '^\s*(?:\[?\s*(\d+)\s*/\s*(\d+)\s*\]?\s*)?Deleting:\s*(.+)$') {
            $curFile  = Get-BuildOutputExcerpt -Line $Matches[3] -State $State
            $haveCnt  = $Matches[1] -and $Matches[2]
            if ($haveCnt) {
                $delState.Total   = [int]$Matches[2]
                $delState.Count   = [int]$Matches[1]
                $msg = ('  [{0,3}/{1,3}] Deleting: {2}' -f $delState.Count, $delState.Total, $curFile)
            } else {
                $delState.Count++
                if ($delState.Total -gt 0) {
                    $msg = ('  [{0,3}/{1,3}] Deleting: {2}' -f $delState.Count, $delState.Total, $curFile)
                } else {
                    $msg = '  [Deleting: {0}] {1}' -f $delState.Count, $curFile
                }
            }
            if ($delState.UseCR) {
                # Clamp to console width: an overflowing line wraps and every CR
                # rewrite then paints a new row (same visual spam as unconsolidated).
                try { $cw = [Console]::WindowWidth } catch { $cw = 80 }
                if ($msg.Length -gt ($cw - 1)) { $msg = $msg.Substring(0, $cw - 1) }
                $pad = ' ' * ([Math]::Max(0, $delState.LineLen - $msg.Length))
                try { Write-Host ("`r" + $msg + $pad) -NoNewline -ForegroundColor Gray } catch { }
                $delState.LineLen = $msg.Length
                $delState.IsActive = $true
            } else {
                # Redirected / CI host: CR is ignored, so emit a single throttled
                # line instead of one per file to avoid spamming the log.
                if (-not $delState.IsActive) {
                    Write-Log "   $($glyphs.gear)  $msg" -Level Info -Color Gray -State $State
                    $delState.IsActive = $true
                }
            }
            return
        }
        # Any non-deleting line: clear the in-place deletion progress first.
        if ($delState.IsActive) {
            if ($delState.UseCR) { try { Write-Host '' } catch { } }
            $delState.IsActive = $false
            $delState.LineLen  = 0
        }
        switch (Test-BuildOutputLine -Line $line) {
            'Error' {
                if ($isProgressActive) { Write-Log ' ' 'Detail' $State; $isProgressActive = $false }
                $errCount++
                Write-Log "  $($glyphs.error)  $line" 'Err' $State
            }
            'Warn' {
                if ($isProgressActive) { Write-Log ' ' 'Detail' $State; $isProgressActive = $false }
                $warnCount++
                Write-Log "  $($glyphs.warn)  $line" 'Warn' $State
            }
            'Milestone' {
                if ($isProgressActive) { Write-Log ' ' 'Detail' $State; $isProgressActive = $false }
                Write-Log "  $($glyphs.ok)  $line" 'Info' $State
            }
            default {
                Write-Log "   $($glyphs.gear)  $(Get-BuildOutputExcerpt -Line $line -State $State)" -Level Info -Color Gray -State $State
                $isProgressActive = $true
            }
        }
    }

    # The publish action returns the output dir on success (cache save path) and
    # throws on failure (retry path). Lines were already displayed live via $liveLine.
    $publishAction = {
        # Flow-scoped CWD: run publish from the project dir so NuGet/config
        # discovery never picks up the caller's tree (same class of bug as SAST).
        $pubDir = try { Split-Path $Project -Parent } catch { '' }
        if ([string]::IsNullOrWhiteSpace($pubDir) -or -not (Test-Path $pubDir)) { $pubDir = '' }
        if ($pubDir) { $res = Invoke-WithLiveOutput -FilePath $State.DotnetCmd -ArgList $params -State $State -Label "dotnet publish [$Tfm]" -WorkingDir $pubDir -OnLine $liveLine } else { $res = Invoke-WithLiveOutput -FilePath $State.DotnetCmd -ArgList $params -State $State -Label "dotnet publish [$Tfm]" -OnLine $liveLine }
        if ($res.ExitCode -ne 0) { throw (Resolve-LogMessage -Key 'log.build.line813' -MessageArgs @([string]$res.ExitCode) -Fallback "dotnet publish failed with exit code $($res.ExitCode)") }
        return $rawOut
    }

    try {
        if ($cacheFlow) {
            # PrecomputedHash: the hash was already computed for the pre-check above —
            # passing it here keeps the SINGLE hash flow (no second recursive SHA256
            # scan inside Invoke-BuildWithCache). The save is done by
            # Invoke-BuildWithCache (single write-path) with BuiltAt metadata.
            $null = Invoke-WithRetry -OperationName "dotnet publish [$Tfm]" -State $State -Action {
                Invoke-BuildWithCache -ProjectPath $Project -CacheKey $cacheKey -State $State -BuildAction $publishAction -PrecomputedHash $projectHash -BuildMetadata @{ BuiltAt = (Get-Date -Format 'o') }
            }
        } else {
            $null = Invoke-WithRetry -OperationName "dotnet publish [$Tfm]" -State $State -Action $publishAction
        }

        $sw.Stop()

        # Clean up the last progress line if present
        if ($isProgressActive) {
            Write-Log ' ' 'Detail' $State
            $isProgressActive = $false
        }
        # Clean up the in-place deletion progress line if it is still active
        # (publish may end with deletions, so no trailing non-deleting line arrived).
        if ($delState.IsActive) {
            if ($delState.UseCR) { try { Write-Host '' } catch { } }
            $delState.IsActive = $false
            $delState.LineLen  = 0
        }

        try {
            Write-Sep
            Write-SectionBox "BUILD RESULTS"
            if ($copyCount -gt 0) { _2Col "  $($glyphs.package) Static files" "$copyCount file(s) copied" (Resolve-SafeColor -ColorName 'Gray' -State $State -Fallback 'Gray') "DarkGray" }
        } catch {
            Write-Log (Get-LocaleMessage -Key 'log.build.results') $State.Colors.Info $State
            Write-Log (Get-LocaleMessage -Key 'log.build.staticFilesCopied' -MessageArgs $copyCount) $State.Colors.Succ $State
        }

        Write-Done (Get-LocaleMessage -Key 'log.build.success') $sw.Elapsed.TotalSeconds $State

        # Build succeeded: clear rollback so post-build failures don't restore output
        if ($outputBackupDir -and (Test-Path $outputBackupDir)) {
            Remove-Item -Path $outputBackupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Get-Command Clear-RollbackStack -ErrorAction SilentlyContinue) { Clear-RollbackStack }

                # Store credentials into the vault after the build (audit/rollback)
        # NOTE: CredentialVault service may not yet be registered in the DI container
        # at build-success time (race during tiered import). Resolve the key path
        # directly from State to avoid a hard DI dependency, and defensively wrap
        # the vault write in try/catch so a keyfile failure never fails a
        # successful build.
        if (Get-Command Protect-CredentialValue -ErrorAction SilentlyContinue) {
            $vaultKeyPath = $null
            if (Get-Command Get-VaultKeyFile -ErrorAction SilentlyContinue) {
                try {
                    $vaultKeyPath = Get-VaultKeyFile -State $State
                } catch {
                    Write-Log (Get-LocaleMessage -Key 'log.build.vaultKeyFileFailed' -MessageArgs $_) $State.Colors.Err $State
                    $vaultKeyPath = $null
                }
            }
            $envVaultKeys = @('ANDROID_KEYSTORE_PASS', 'ANDROID_KEY_PASS')
            foreach ($ek in $envVaultKeys) {
                $envVal = [Environment]::GetEnvironmentVariable($ek)
                if (-not [string]::IsNullOrEmpty($envVal)) {
                    try {
                        Protect-CredentialValue -Value $envVal -Purpose "env:$ek" -State $State -KeyFilePath $vaultKeyPath | Out-Null
                    } catch {
                        # CORRECTED: passed the undefined variable $File (1
                        # occurrence in this file, never assigned), so a
                        # credential-encryption failure always logged a
                        # garbage message. The loop variable is $ek.
                        Write-Log (Get-LocaleMessage -Key 'log.build.vaultEncryptFailed' -MessageArgs @($ek, $_)) $State.Colors.Err $State
                    }
                }
            }
        }

        # Cache save is handled by Invoke-BuildWithCache (single write-path) —
        # no second Save-BuildCacheEntry here (was a double-save + double-hash).

        if ($ProjectType -ne 'Library') {
            Invoke-BuildOutputReveal -State $State -OutputDir $rawOut -ProjectType $ProjectType
        }

        # 8. Post-build: Install to device (if Android APK)
        if ($isAndroidPlatform -and $OutputSubDir -eq "apk") {
            Invoke-AndroidArtifactDeploy -State $State -OutputDir $rawOut -CsprojContent $csprojContent -OutputSubDir $OutputSubDir -ExeBaseName $exeBaseName
            $apkFile = Get-ChildItem -Path $rawOut -Filter "*.apk" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $apkFile) {
                Write-Log (Get-LocaleMessage -Key 'log.build.noApk') $State.Colors.Warn $State
                Invoke-BuildOutputReveal -State $State -OutputDir $rawOut -ProjectType $ProjectType
            }
        }

    } catch {
        # Exit code details printed above; this catch only re-throws to the caller
        throw
    } finally {
        # Always clean up any incomplete progress line if there is an exception
        if ($isProgressActive) {
            Write-Log ' ' 'Detail' $State
        }
    }

    # Build succeeded (after-build hook is fired by the pipeline finally-block)
    if ($Detailed) { return New-BuildResult -Status Succeeded -Operation 'build' -ReasonCode 'OK' -Message 'Build completed' -OutputPath $rawOut }
    return $true
}

<#
.SYNOPSIS
    Deploy and debug Android application on device via ADB.
#>
function Invoke-DeviceDebug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$State,
        [string]$Project,
        [string]$Tfm
    )

    # Early validation: skip silently if Project path is not a real file
    if ([string]::IsNullOrWhiteSpace($Project) -or -not (Test-Path $Project -PathType Leaf -EA SilentlyContinue)) {
        return
    }

    $adb = Find-AdbPath -State $State
    if (-not $adb -or -not (Test-Path -Path $adb)) { Write-Log (Get-LocaleMessage -Key 'log.build.adbNotFound') $State.Colors.Warn $State; return }

    $devices = Get-AdbDevices -State $State -AdbPath $adb
    if ($devices.Count -eq 0) {
        Write-Log (Get-LocaleMessage -Key 'log.build.noDevicesConnected') $State.Colors.Warn $State
        return
    }

    $manufacturer = & $adb -s $devices[0] shell getprop ro.product.manufacturer 2>&1 | Out-String
    if ($manufacturer.Trim() -eq 'Xiaomi') {
        Write-Log (Get-LocaleMessage -Key 'log.build.xiaomiOptimize') $State.Colors.Cyan $State
        & $adb shell settings put global verifier_verify_adb_installs 0 2>&1 | Out-Null
        & $adb shell settings put global package_verifier_enable 0 2>&1 | Out-Null
    } else {
        Write-Log (Get-LocaleMessage -Key 'log.build.notXiaomi') $State.Colors.Gray $State
    }

    Write-Log (Get-LocaleMessage -Key 'log.android.devicesFound' -MessageArgs @($devices[0].ToString().Trim())) 'Info' $State
    Write-Log (Get-LocaleMessage -Key 'log.build.autoDeployDebug') $State.Colors.Cyan $State

    $safeProject    = Get-SafePath -Path $Project
    $safeAndroidSdk = Get-SafePath -Path $State.AndroidSdk
    $safeJavaSdk    = Get-SafePath -Path $State.JavaSdk

    Write-Log (Get-LocaleMessage -Key 'log.build.deployingApp') $State.Colors.Cyan $State
    & $State.DotnetCmd @(
        "build", $safeProject,
        "-t:Run",
        "-f", $Tfm,
        "-p:AndroidSdkDirectory=$safeAndroidSdk",
        "-p:JavaSdkDirectory=$safeJavaSdk"
    )
}

<#
.SYNOPSIS
    Uninstall old app, install APK and launch on first Android device.
#>
function Invoke-AutoDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$State,
        [string]$ApkPath,
        [string]$AppId,
        [string]$AndroidSdkPath = ""
    )

    try { $adb = Find-AdbPath -State $State } catch { return }
    if (-not $adb -or -not (Test-Path -Path $adb)) { return }
    if ([string]::IsNullOrWhiteSpace($ApkPath) -or -not (Test-Path -Path $ApkPath)) { return }

    $safeApkPath = Get-SafePath -Path $ApkPath

    $retryCount = [int](Get-BuildConstant -Key 'AdbInstallRetryCount' -Fallback 2)
    $retryDelay = [int](Get-BuildConstant -Key 'AdbInstallRetryDelayMs' -Fallback 1200)

    # Resolve the target serial. Get-AdbDevices auto-connects inactive emulators
    # and (via Invoke-AdbDeviceScan) restarts a dead adb daemon, so this is also
    # our "ensure daemon is up" step.
    $currentDevices = @(Get-AdbDevices -State $State -AdbPath $adb)
    if ($currentDevices.Count -eq 0) { return }

    $realDevices  = @($currentDevices | Where-Object { $_ -notmatch "^emulator-" -and $_ -notmatch "^127\.0\.0\." })
    $emulators    = @($currentDevices | Where-Object { $_ -match "^emulator-" -or $_ -match "^127\.0\.0\." })
    $targetDevice = if ($realDevices.Count -gt 0) { $realDevices[0] } else { $emulators[0] }

    Write-Log (Get-LocaleMessage -Key 'log.build.deployingToDevice' -MessageArgs $targetDevice) $State.Colors.Cyan $State
    Write-Log (Get-LocaleMessage -Key 'log.build.deployingToDevice' -MessageArgs @($targetDevice)) 'Info' $State

    $packageInstalled = (& $adb -s $targetDevice shell "pm path $AppId" 2>&1) -match "$AppId"
    if ($packageInstalled) {
        Write-Log (Get-LocaleMessage -Key 'log.build.uninstalling' -MessageArgs $AppId) $State.Colors.Cyan $State
        & $adb -s $targetDevice uninstall $AppId 2>&1 | Out-Null
        Start-Sleep -Milliseconds (Get-BuildConstant -Key 'AdbUninstallDelayMs' -Fallback 800)
        & $adb -s $targetDevice wait-for-device 2>&1 | Out-Null
        & $adb start-server 2>&1 | Out-Null
    }

    $attempt = 0
    $lastExit = -1
    $installOut = @()
    $usePushInstall = $false  # start with streaming; fallback to push (--no-streaming)

    while ($attempt -le $retryCount) {
        $attempt++

        # Re-resolve the target serial before each install attempt: an adb
        # daemon restart or a late-registering emulator can change/evict serials
        # between uninstall and install, producing "device '<serial>' not found".
        $currentDevices = @(Get-AdbDevices -State $State -AdbPath $adb)
        if ($currentDevices.Count -gt 0) {
            $realDevices  = @($currentDevices | Where-Object { $_ -notmatch "^emulator-" -and $_ -notmatch "^127\.0\.0\." })
            $emulators    = @($currentDevices | Where-Object { $_ -match "^emulator-" -or $_ -match "^127\.0\.0\." })
            if ($realDevices.Count -eq 0 -and $emulators.Count -eq 0) { break }
            if ($targetDevice -notin $currentDevices) {
                $targetDevice = if ($realDevices.Count -gt 0) { $realDevices[0] } else { $emulators[0] }
                Write-Log (Get-LocaleMessage -Key 'log.build.deployingToDevice' -MessageArgs $targetDevice) $State.Colors.Cyan $State
            }
        } else { break }

        $installArgs = @("install", "-r", "-d", "-t", "-g")
        if ($usePushInstall) { $installArgs += "--no-streaming" }
        $installArgs += $safeApkPath

        Write-Log (Get-LocaleMessage -Key 'log.build.installingApk') $State.Colors.Cyan $State
        $installOut = @(& $adb -s $targetDevice $installArgs 2>&1)
        $lastExit = $LASTEXITCODE

        if ($lastExit -eq 0) { break }

        # If streaming failed, try push on next attempt (and vice versa if push was first)
        if (-not $usePushInstall) {
            $usePushInstall = $true
            Write-Log (Get-LocaleMessage -Key 'log.build.installStreamingRetry') $State.Colors.Warn $State
        }

        if ($attempt -le $retryCount) {
            Write-Log (Get-LocaleMessage -Key 'log.build.installRetry' -MessageArgs @($lastExit, $attempt, ($retryCount + 1))) $State.Colors.Warn $State
            # Restart the flaky daemon and give the emulator time to re-register.
            & $adb kill-server 2>&1 | Out-Null
            & $adb start-server 2>&1 | Out-Null
            Start-Sleep -Milliseconds $retryDelay
        }
    }

    if ($lastExit -eq 0) {
        Write-Log (Get-LocaleMessage -Key 'log.build.installSucceeded') $State.Colors.Succ $State
        Write-Log (Get-LocaleMessage -Key 'log.build.launchingApp' -MessageArgs $AppId) $State.Colors.Cyan $State

        # L5: resolve the real launcher activity (was orphan Get-LauncherActivity).
        # `monkey` fails with "No activities found" when the app has no LAUNCHER
        # category — explicit `am start -n` with the resolved activity is exact.
        $launcherActivity = $null
        if (Get-Command Get-LauncherActivity -ErrorAction SilentlyContinue) {
            try { $launcherActivity = Get-LauncherActivity -State $State -AdbPath $adb -Device $targetDevice -AppId $AppId } catch { $launcherActivity = $null }
        }
        if ($launcherActivity -and $launcherActivity -ne '.MainActivity') {
            Write-Log (Get-LocaleMessage -Key 'log.android.launchingApp' -MessageArgs @($AppId, $launcherActivity)) $State.Colors.Info $State
            $launchResult = & $adb -s $targetDevice shell "am start -n $AppId/$launcherActivity" 2>&1
        } else {
            Write-Log (Get-LocaleMessage -Key 'log.android.launchingApp' -MessageArgs @($AppId, 'LAUNCHER')) $State.Colors.Info $State
            $launchResult = & $adb -s $targetDevice shell "monkey -p $AppId -c android.intent.category.LAUNCHER 1" 2>&1
        }

        if ($launchResult -match "No activities found to run") {
            Write-Log (Get-LocaleMessage -Key 'log.build.noLauncherActivity') $State.Colors.Warn $State
        } else {
            Write-Log (Get-LocaleMessage -Key 'log.build.appOpened') $State.Colors.Succ $State
        }
    } else {
        Write-Log (Get-LocaleMessage -Key 'log.build.installFailed' -MessageArgs $lastExit) $State.Colors.Err $State
        Write-Log (Get-LocaleMessage -Key 'log.build.installRetriesExhausted' -MessageArgs $attempt) $State.Colors.Err $State
        if ($installOut) {
            foreach ($line in $installOut) {
                $trimmedLine = $line.ToString().Trim()
                if (-not [string]::IsNullOrWhiteSpace($trimmedLine)) {
                    Write-Log (Get-LocaleMessage -Key 'log.build.adbOutput' -MessageArgs $trimmedLine) $State.Colors.Warn $State
                }
            }
        }
    }
}

<#
.SYNOPSIS
    Release processes occupying the output dir or port of the Web/Blazor project.
#>
function Stop-ProcessByPort {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$State,
        [string]$ProjectDir,
        [string]$ProjectType = "",
        [string]$ExeName,
        [string]$OutputDir = ""
    )

    $supportedTypes = @('Web', 'BlazorWasm', 'Console', 'WPF', 'WinForms', 'WinExe')
    if ($ProjectType -notin $supportedTypes) { return }

    Write-Log (Get-LocaleMessage -Key 'log.build.releasingResources' -MessageArgs $ProjectType) $State.Colors.Gray $State

    # Determine path comparison based on OS from State
    # $State.OS first (it is the mockable record of the target machine, which
    # is what the tests stamp), then the shared PathUtils.Get-PathComparison
    # resolver for live detection. The previous form inlined the live branch
    # a second time instead of delegating, so a fix to the resolver's
    # macOS/Linux mapping would never have reached this call site.
    $pathCmp = [System.StringComparison]::OrdinalIgnoreCase
    try {
        if ($State -and $State.OS -and $State.OS -ne 'Windows') { $pathCmp = [System.StringComparison]::Ordinal }
        elseif (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) {
            $pathCmp = [System.StringComparison](Get-PathComparison)
        }
    } catch { }

    # 1. Kill by OutputDir (process path resolution single-sourced via
    # Environment.Get-ProcessCommandLine: Windows CIM, Linux /proc, macOS ps).
    if (-not [string]::IsNullOrWhiteSpace($OutputDir) -and (Test-Path -Path $OutputDir)) {
        $lockedProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $pPath = $null
            try {
                if ($State.OS -eq 'Windows') { $pPath = $_.MainModule.FileName }
                else { $pPath = $_.Path }
            } catch { $pPath = $null }
            if (-not $pPath -and (Get-Command Get-ProcessCommandLine -ErrorAction SilentlyContinue)) {
                try {
                    $cmd = Get-ProcessCommandLine -ProcessId $_.Id
                    if ($cmd) {
                        # Command line contains the executable as its first token.
                        $firstTok = ($cmd -split '\s+')[0].Trim('"', "'")
                        if ($firstTok) { $pPath = $firstTok }
                    }
                } catch { $pPath = $null }
            }
            if (-not $pPath -and $State.OS -eq 'Linux' -and (Test-Path "/proc/$($_.Id)/exe")) {
                try { $pPath = (Get-Item "/proc/$($_.Id)/exe").Target } catch { $pPath = $null }
            }
            $pPath -and $pPath.StartsWith($OutputDir, $pathCmp)
        }
        foreach ($proc in $lockedProcs) {
            if ($PSCmdlet.ShouldProcess("Process: $($proc.ProcessName) (PID: $($proc.Id))", "Kill process locking OutputDir")) {
                Stop-Process -InputObject $proc -Force -ErrorAction SilentlyContinue
                Write-Log (Get-LocaleMessage -Key 'log.build.releasedProcess' -MessageArgs $proc.ProcessName) $State.Colors.Succ $State
            }
        }
    }

    if ($ProjectType -notin @('Web', 'BlazorWasm')) { return }

    $portsToKill = Get-LaunchSettingsPorts -ProjectDir $ProjectDir
    foreach ($cfgFile in @("appsettings.json", "appsettings.Production.json")) {
        $cfgPath = Join-Path $ProjectDir $cfgFile
        if (Test-Path -Path $cfgPath) {
            try {
                $rawJson = Get-Content -Path $cfgPath -Raw -Encoding UTF8
                $cleanJson = Remove-JsonComments -JsonWithComments $rawJson
                $cfg = $cleanJson | ConvertFrom-Json
                if ($cfg.Kestrel -and $cfg.Kestrel.Endpoints) {
                    $cfg.Kestrel.Endpoints.PSObject.Properties.Value | ForEach-Object {
                        if ($_.Url -match ':(\d+)') { [void]$portsToKill.Add([int]$matches[1]) }
                    }
                }
                if ($cfg.Urls) {
                    $cfg.Urls -split ';' | ForEach-Object {
                        if ($_ -match ':(\d+)') { [void]$portsToKill.Add([int]$matches[1]) }
                    }
                }
            } catch { # benign — config file may be malformed or missing expected fields
            }
        }
    }

    if ($portsToKill.Count -eq 0) { return }

    foreach ($port in $portsToKill) {
        # OS-aware listener lookup centralized in Environment.Get-PortOwnerProcess
        $procs = @(Get-PortOwnerProcess -Port $port)
        foreach ($proc in $procs) {
            $inOutputDir = (-not [string]::IsNullOrWhiteSpace($OutputDir)) -and $proc.Path -and $proc.Path.StartsWith($OutputDir, $pathCmp)
            $isExeMatch  = $proc.ProcessName -eq $ExeName
            # Command-line match: a leftover host from OUR previous build can run
            # under a runtime process (e.g. `dotnet MultiAiAgent.dll --urls=:5104`
            # runs as dotnet.exe), so neither the path nor the name matches. Match
            # our output-dir / exe / dll token in its command line to kill ONLY our
            # stale host and never a foreign program bound to the same port.
            $isCmdlineMatch = $false
            if (($inOutputDir -or $isExeMatch) -eq $false) {
                $projToken = if (-not [string]::IsNullOrWhiteSpace($ExeName)) { $ExeName } else { [System.IO.Path]::GetFileNameWithoutExtension($OutputDir) }
                if ($projToken) {
                    $cmdline = $null
                    try {
                        if (Get-Command Get-ProcessCommandLine -ErrorAction SilentlyContinue) { $cmdline = Get-ProcessCommandLine -ProcessId $proc.Id }
                    } catch { $cmdline = $null }
                    if ($cmdline) {
                        $tokenToFind = [System.IO.Path]::GetFileNameWithoutExtension($projToken)
                        # Match "MultiAiAgent" token OR the absolute output dir in the command line.
                        $isCmdlineMatch = ($cmdline -like "*$tokenToFind*") -or
                                          (($OutputDir) -and $cmdline -like "*$OutputDir*")
                    }
                }
            }

            if ($inOutputDir -or $isExeMatch -or $isCmdlineMatch) {
                $why = if ($inOutputDir) { "output-dir" } elseif ($isExeMatch) { "exe-name" } else { "command-line" }
                if ($PSCmdlet.ShouldProcess("Port $port (PID $($proc.Id), match: $why)", "Kill process")) {
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

<#
.SYNOPSIS
    Forwarder approved-verb for Build-AndroidAab (sign and build Android AAB).
#>
function Publish-AndroidAab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$State,
        [string]$ProjectPath,
        [string]$Tfm,
        $Keystore,
        [string]$ProjectType = "",
        [switch]$Incremental
    )
    New-AndroidAab -State $State -ProjectPath $ProjectPath -Tfm $Tfm -Keystore $Keystore -ProjectType $ProjectType -Incremental:$Incremental
}

function New-AndroidAab {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Build Android AAB (Android App Bundle) with signing configuration.
    #>
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$State,
        [string]$ProjectPath,
        [string]$Tfm,
        $Keystore,
        [string]$ProjectType = "",
        [switch]$Incremental
    )

    # Resolve: if ProjectPath is a directory -> find .csproj file
    # Level 5 resilience: inline lookup fallback when PathUtils was orphaned.
    if (Test-Path $ProjectPath -PathType Container) {
        $manifests = if (Get-Command Find-ProjectManifest -ErrorAction SilentlyContinue) {
            @(Find-ProjectManifest -Root $ProjectPath -Filters @('*.csproj') -Recurse:$false)
        } else {
            @(Get-ChildItem -Path $ProjectPath -Filter '*.csproj' -File -ErrorAction SilentlyContinue)
        }
        if ($manifests.Count -eq 0) { return }
        $ProjectPath = $manifests[0].FullName
    }

    # Validate Keystore object (must have Path, Alias, StorePass, KeyPass properties)
    $ksPath  = if ($Keystore -is [string]) { $Keystore } else { $Keystore.Path }
    $ksAlias = if ($Keystore -isnot [string]) { $Keystore.Alias } else { $null }
    if ([string]::IsNullOrWhiteSpace($ksPath) -or -not (Test-Path $ksPath -ErrorAction SilentlyContinue)) {
        Write-Log (Get-LocaleMessage -Key 'log.build.keystoreInvalid' -MessageArgs $ksPath) $State.Colors.Err $State
        return
    }

    Write-Log (Get-LocaleMessage -Key 'log.build.readyAab' -MessageArgs @($ksPath, $ksAlias)) $State.Colors.Cyan $State

    # SECURITY: store/key passwords must NEVER appear on the child-process command
    # line (visible via Get-Process/WMI CommandLine for the whole publish duration).
    # MSBuild imports every environment variable as an overridable property, so we
    # pass AndroidSigningStorePass / AndroidSigningKeyPass / AndroidSigningKeyAlias
    # through $env: instead of expanding them into "-p:..." tokens. Env blocks are
    # only readable by the same user/admin, unlike argv which any local process sees.
    $env:ANDROID_KEYSTORE_PASS = if ($Keystore -isnot [string]) { $Keystore.StorePass } else { '' }
    $env:ANDROID_KEY_PASS = if ($Keystore -isnot [string]) { $Keystore.KeyPass } else { '' }
    $env:AndroidSigningStorePass = [string]$env:ANDROID_KEYSTORE_PASS
    $env:AndroidSigningKeyPass   = [string]$env:ANDROID_KEY_PASS
    $env:AndroidSigningKeyAlias  = [string]$ksAlias
    # Keystore path + flags stay on argv (path/alias are not secrets).
    $signingArgs = @(
        "-p:AndroidKeyStore=true",
        "-p:AndroidSigningKeyStore=`"$ksPath`""
    )

    try {
        Start-BuildAndShow -State $State -Project $ProjectPath -Tfm $Tfm `
            -OutputSubDir "aab" `
            -BuildArgs ($signingArgs + @("-p:AndroidPackageFormat=aab")) `
            -ProjectType $ProjectType `
            -Incremental:$Incremental
    } finally {
        # Clean up ALL signing env vars even if error occurs (both the gbuild names
        # kept for vault/audit compatibility and the MSBuild property names).
        Remove-Item Env:ANDROID_KEYSTORE_PASS -EA SilentlyContinue
        Remove-Item Env:ANDROID_KEY_PASS -EA SilentlyContinue
        Remove-Item Env:AndroidSigningStorePass -EA SilentlyContinue
        Remove-Item Env:AndroidSigningKeyPass -EA SilentlyContinue
        Remove-Item Env:AndroidSigningKeyAlias -EA SilentlyContinue
    }
}

<#
.SYNOPSIS
    Trigger GitHub Actions workflow build.yml for the specified package_format.
#>
function Invoke-GitHubBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$State,
        [string]$PackageFormat
    )

    # Invoke-GitHubBuild now RETURNS a verdict. It previously returned nothing on
    # every path, so its caller had no way to distinguish "workflow dispatched"
    # from "gh is not installed" from "gh exited non-zero" and printed a
    # success line unconditionally. The shape matches New-BuildResult so the
    # caller can pass it straight through.
    $operation = 'target:13'
    if ([string]::IsNullOrWhiteSpace($PackageFormat)) {
        Write-Log (Get-LocaleMessage -Key 'log.build.missingPackageFormat') $State.Colors.Err $State
        return New-BuildResult -Status Failed -Operation $operation -ReasonCode 'NoPackageFormat' -Message 'No package format was supplied'
    }

    Write-Log (Get-LocaleMessage -Key 'log.build.ghConnecting') $State.Colors.Cyan $State

    $ghCmd = Get-Command gh -EA SilentlyContinue
    if (-not $ghCmd) {
        Write-Log (Get-LocaleMessage -Key 'log.build.ghNotFound') $State.Colors.Err $State
        return New-BuildResult -Status Failed -Operation $operation -ReasonCode 'ToolMissing' -Message 'GitHub CLI (gh) is not installed' -ExitCode 127
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    # ci.defaultBranch is the documented fallback ref; ci.workflowFile names the
    # workflow to trigger. Both used to be hardcoded here ('main' / 'build.yml')
    # while sitting unread in config, so an operator renaming either had no effect.
    $defaultBranch = 'main'
    $workflowFile = 'build.yml'
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        $cfgBranch = [string](Get-BuildConstant -Key 'CiDefaultBranch' -State $State -Fallback '')
        if (-not [string]::IsNullOrWhiteSpace($cfgBranch)) { $defaultBranch = $cfgBranch }
        $cfgWorkflow = [string](Get-BuildConstant -Key 'CiWorkflowFile' -State $State -Fallback '')
        if (-not [string]::IsNullOrWhiteSpace($cfgWorkflow)) { $workflowFile = $cfgWorkflow }
    }
    if (-not $gitCmd) {
        $branch = $defaultBranch
    } else {
        $branch = (& git branch --show-current 2>$null)
        if ([string]::IsNullOrWhiteSpace($branch)) {
            $branch = $defaultBranch
        }
    }

    Write-Log (Get-LocaleMessage -Key 'log.build.ghTriggering' -MessageArgs @($PackageFormat, $branch)) $State.Colors.Cyan $State

    # Standard GitHub CLI syntax
    & $ghCmd.Source workflow run $workflowFile --ref $branch -f "package_format=$PackageFormat" 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Log (Get-LocaleMessage -Key 'log.build.ghTriggerFailed' -MessageArgs $LASTEXITCODE) $State.Colors.Err $State
        return New-BuildResult -Status Failed -Operation $operation -ReasonCode 'DispatchFailed' -Message "gh workflow run exited $LASTEXITCODE" -ExitCode $LASTEXITCODE
    }

    Write-Log (Get-LocaleMessage -Key 'log.build.ghTriggerSucceeded') $State.Colors.Succ $State
    return New-BuildResult -Status Succeeded -Operation $operation -ReasonCode 'OK' -Message "Workflow '$workflowFile' dispatched on ref '$branch'"
}

function Invoke-GuildParallelBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$State,
        [string[]]$Projects,
        [string]$Tfm,
        [int]$MaxJobs = 0
    )
    $operation = 'target:14'
    if (-not $Projects -or $Projects.Count -eq 0) {
        return New-BuildResult -Status Skipped -Operation $operation -ReasonCode 'NoProjects' -Message 'Parallel build needs independent projects'
    }
    if (-not (Get-Command Invoke-ParallelBuild -ErrorAction SilentlyContinue)) {
        $parallelPath = Join-Path $PSScriptRoot 'Parallel.psm1'
        if (Test-Path -LiteralPath $parallelPath) { $null = Import-Module $parallelPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue }
    }
    if (-not (Get-Command Invoke-ParallelBuild -ErrorAction SilentlyContinue)) {
        return New-BuildResult -Status Blocked -Operation $operation -ReasonCode 'ModuleNotLoaded' -Message 'Parallel module is not available' -ExitCode 127
    }
    if ($MaxJobs -le 0) {
        $MaxJobs = if (Get-Command Get-BuildSetting -ErrorAction SilentlyContinue) { [int](Get-BuildSetting -Key 'ParallelMaxJobs' -State $State -Fallback 8) } else { 8 }
    }
    $configuration = if ($State.BuildConfig -and $State.BuildConfig.build -and $State.BuildConfig.build.defaultConfiguration) { [string]$State.BuildConfig.build.defaultConfiguration } else { 'Release' }
    $tasks = foreach ($proj in $Projects) {
        $projName = [System.IO.Path]::GetFileNameWithoutExtension($proj)
        @{
            Name = $projName
            ScriptBlock = {
                param($p, $state, $tfm, $config, $projName)
                $dotnet = if ($state -and $state.PSObject.Properties.Name -contains 'DotnetCmd' -and $state.DotnetCmd) { [string]$state.DotnetCmd } else { 'dotnet' }
                $log = if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Get-Command Write-Log } else { $null }
                # These three go through $log (a Get-Command result invoked with
                # &) because the block runs inside a parallel worker where the
                # Write-Log name is not statically visible. That is exactly why
                # the i18nProseCoverage metric cannot see them - it matches verb
                # NAMES - so they are localized here explicitly. ProcessMetrics'
                # known limitation: an emit dispatched through an indirection is
                # outside its vocabulary.
                if ($log) { & $log (Resolve-LogMessage -Key 'log.build.projectBuilding' -MessageArgs @([string]$projName) -Fallback "[{0}] Building...") 'Info' $state }
                # Framework/configuration switches follow the SAME spelling the publish path
                # uses at Build.psm1 ~627 (`-f <tfm> -c <config>`). This task
                # previously passed `-tfm:<value>`, which `dotnet build` does
                # not accept at all: MSBuild rejected it with MSB1001 "Unknown
                # switch" and returned exit 1 for every project, so every
                # parallel build failed. Combined with the hardcoded
                # Success = $true in Parallel.psm1 that reported as a clean
                # 3-of-3 success. `-f` is also omitted when no TFM was resolved,
                # because a bare `-f ''` is itself an error.
                $buildArgs = @('build', $p)
                if (-not [string]::IsNullOrWhiteSpace([string]$tfm)) { $buildArgs += @('-f', [string]$tfm) }
                if (-not [string]::IsNullOrWhiteSpace([string]$config)) { $buildArgs += @('-c', [string]$config) }
                $output = @(& $dotnet @buildArgs 2>&1)
                $exit = $LASTEXITCODE
                if ($exit -eq 0) {
                    if ($log) { & $log (Resolve-LogMessage -Key 'log.build.projectBuildOk' -MessageArgs @([string]$projName) -Fallback "[{0}] Build OK") 'Succ' $state }
                    return @{ Project = $projName; Success = $true; Output = $output }
                }
                if ($log) { & $log (Resolve-LogMessage -Key 'log.build.projectBuildFailed' -MessageArgs @([string]$projName) -Fallback "[{0}] Build FAILED") 'Err' $state }
                return @{ Project = $projName; Success = $false; Output = $output; ExitCode = $exit }
            }
            # projName MUST be passed explicitly. The block is dispatched into a runspace
            # whose only bindings are the named parameters below, so the loop
            # variable that computed it was simply absent there and every log
            # line rendered as "[] Build FAILED" with an empty project name.
            Arguments = @{ p = $proj; state = $State; tfm = $Tfm; config = $configuration; projName = $projName }
        }
    }
    try {
        $raw = Invoke-ParallelBuild -BuildTasks $tasks -MaxJobs $MaxJobs -State $State
        $results = @($raw | Where-Object { $_.PSObject.Properties.Name -contains 'Success' })
        $ok = @($results | Where-Object { [bool]$_.Success }).Count
        $fail = @($results | Where-Object { -not [bool]$_.Success }).Count
        if ($results.Count -eq 0) { return New-BuildResult -Status Skipped -Operation $operation -ReasonCode 'NoResults' -Message 'Parallel build returned no project results' -Details $raw }
        Write-Log (Resolve-LogMessage -Key 'log.build.parallelSummary' -MessageArgs @([string]$ok, $fail) -Fallback 'Parallel build: {0} succeeded, {1} failed') $(if ($fail -gt 0) { 'Warn' } else { 'Succ' }) $State
        $status = if ($fail -gt 0) { 'Failed' } else { 'Succeeded' }
        return New-BuildResult -Status $status -Operation $operation -ReasonCode $(if ($fail -gt 0) { 'BuildFailed' } else { 'OK' }) -Message "Parallel build: $ok succeeded, $fail failed" -Details $results
    } catch {
        return New-BuildResult -Status Failed -Operation $operation -ReasonCode 'Exception' -Message $_.Exception.Message -Details $_
    }
}

function Invoke-GuildDistributedBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$State,
        [string[]]$Projects
    )
    $operation = 'target:X'
    if (-not $Projects -or $Projects.Count -eq 0) {
        return New-BuildResult -Status Skipped -Operation $operation -ReasonCode 'NoProjects' -Message 'Distributed build needs independent projects'
    }
    if (-not (Get-Command Invoke-DistributedBuild -ErrorAction SilentlyContinue)) {
        $distributedPath = Join-Path $PSScriptRoot 'Distributed.psm1'
        if (Test-Path -LiteralPath $distributedPath) { $null = Import-Module $distributedPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue }
    }
    if (-not (Get-Command Invoke-DistributedBuild -ErrorAction SilentlyContinue)) {
        return New-BuildResult -Status Blocked -Operation $operation -ReasonCode 'ModuleNotLoaded' -Message 'Distributed module is not available' -ExitCode 127
    }
    $configuration = if ($State.BuildConfig -and $State.BuildConfig.build -and $State.BuildConfig.build.defaultConfiguration) { [string]$State.BuildConfig.build.defaultConfiguration } else { 'Release' }
    $tasks = foreach ($proj in $Projects) {
        $projName = [System.IO.Path]::GetFileNameWithoutExtension($proj)
        $rel = $proj
        # Relativise against the project root. The comparison MUST follow the
        # host filesystem's case sensitivity: a hardcoded OrdinalIgnoreCase
        # made a case-sensitive Linux/macOS volume treat /repo/App as matching
        # root /repo/app, so the substring offset taken from ProjectRoot.Length
        # no longer corresponded to a real boundary in $proj and the emitted
        # relative path was corrupt. Get-PathComparison is the single source.
        $rootCmp = if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { Get-PathComparison }
                   else { if ((Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) -and (Test-IsWindowsHost)) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal } }
        $projFull = try { [System.IO.Path]::GetFullPath($proj) } catch { $proj }
        $rootFullCmp = try { [System.IO.Path]::GetFullPath($State.ProjectRoot) } catch { [string]$State.ProjectRoot }
        if ($State.ProjectRoot -and $projFull.StartsWith($rootFullCmp, $rootCmp)) {
            $rel = $projFull.Substring($rootFullCmp.Length).TrimStart('\', '/')
        }
        [PSCustomObject]@{ Name = $projName; Command = "dotnet build `"$rel`" --configuration $configuration"; Tags = @() }
    }
    try {
        $raw = Invoke-DistributedBuild -Tasks $tasks -State $State
        if ($null -eq $raw) {
            return New-BuildResult -Status Skipped -Operation $operation -ReasonCode 'Disabled' -Message 'Distributed build is disabled or unavailable'
        }
        $results = @($raw | Where-Object { $_.PSObject.Properties.Name -contains 'Success' })
        if ($results.Count -eq 0) {
            return New-BuildResult -Status Skipped -Operation $operation -ReasonCode 'NoResults' -Message 'Distributed build produced no results' -Details $raw
        }
        $ok = @($results | Where-Object { [bool]$_.Success }).Count
        $fail = @($results | Where-Object { -not [bool]$_.Success }).Count
        $hosts = @($results | ForEach-Object { $_.Host } | Sort-Object -Unique).Count
        Write-Log (Resolve-LogMessage -Key 'log.build.distributedSummary' -MessageArgs @([string]$ok, $fail, $hosts) -Fallback 'Distributed build: {0} succeeded, {1} failed across {2} host(s)') $(if ($fail -gt 0) { 'Warn' } else { 'Succ' }) $State
        $status = if ($fail -gt 0) { 'Failed' } else { 'Succeeded' }
        return New-BuildResult -Status $status -Operation $operation -ReasonCode $(if ($fail -gt 0) { 'BuildFailed' } else { 'OK' }) -Message "Distributed build: $ok succeeded, $fail failed" -Details $results
    } catch {
        return New-BuildResult -Status Failed -Operation $operation -ReasonCode 'Exception' -Message $_.Exception.Message -Details $_
    }
}

# -- Export public functions --
Export-ModuleMember -Function @('Start-BuildAndShow', 'Invoke-DeviceDebug', 'Invoke-AutoDeploy', 'Invoke-GuildParallelBuild', 'Invoke-GuildDistributedBuild', 'Publish-AndroidAab', 'Invoke-GitHubBuild', 'Stop-ProcessByPort')





