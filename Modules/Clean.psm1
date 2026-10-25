# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================



# Bootstrap loads: Logging + ConfigProvider (automatic) + Environment/ErrorHandling/PathUtils
# (explicit deps) — do NOT manually import Logging here anymore (BuildImport is the single
# source; nested -Force re-import also risks orphaning global Logging on PS 5.1).
# Locale IS a declared dependency: Invoke-SmartClean calls Get-LocaleMessage
# unguarded (7 sites), and Locale is a leaf module (Dependencies @(), no Logging
# back-import, no cycle), so declaring it is safe. Relying on ambient Locale
# made the Clean scope pass in-process but fail isolated.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Environment', 'ErrorHandling', 'PathUtils', 'Locale')

# ==================================================================================================
# Modules/Clean.psm1 (Optimized for Zero-Touch & State Pattern)
# ==================================================================================================

# -- Constants & Configuration --
# Single source: BuildConstants (CleanRetry* + CleanTargetDirNames + CleanArtifactExtensions).
# Get-Command guard so a standalone import doesn't depend on module load order.
$script:CleanRetryAttempts   = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'CleanRetryAttempts' -Fallback 3 } else { 3 }
$script:CleanRetryDelayBase  = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'CleanRetryDelayBaseSec' -Fallback 1 } else { 1 }
$script:CleanCacheExtensions = @('.nuspec', '.cache', 'project.nuget.cache')
$script:CleanArtifactExtensions = @('.dll', '.exe', '.pdb', '.deps.json', '.runtimeconfig.json', '.xml', '.staticwebassets.runtime.json', '.so', '.dylib', '.apk', '.aab', '.msix', '.appxbundle', '.pkg', '.ipa', '.wasm', '.blat', '.dat', '.map')
# Stated ONCE. This 19-element list was previously written out in full TWICE -
# once as the -Fallback and again in the `else` taken when BuildConstants is
# unavailable - so extending it meant editing two 200-character literals, and a
# partial edit left the standalone path cleaning a different extension set from
# the configured one. The canonical list stays owned by BuildConstants; the
# local exists only so the survival copy is stated once per module.
$cleanArtifactExtensionsFallback = @('.dll', '.exe', '.pdb', '.deps.json', '.runtimeconfig.json', '.xml', '.staticwebassets.runtime.json', '.so', '.dylib', '.apk', '.aab', '.msix', '.appxbundle', '.pkg', '.ipa', '.wasm', '.blat', '.dat', '.map')
$script:CleanArtifactExtensions = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
    @(Get-BuildConstant -Key 'CleanArtifactExtensions' -Fallback $cleanArtifactExtensionsFallback)
} else { $cleanArtifactExtensionsFallback }
function Get-CleanTargetDirNames {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

Set-StrictMode -Version 1.0
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        return @(Get-BuildConstant -Key 'CleanTargetDirNames' -Fallback @('bin', 'obj', '.vs', '.idea', '.fleet'))
    }
    return @('bin', 'obj', '.vs', '.idea', '.fleet')
}

<#
.SYNOPSIS
    Loads clean targets configuration from config (build.cleanTargetsPerProjectType).
.DESCRIPTION
    Reads build.cleanTargetsPerProjectType from gbuild.config.json. Returns a PSCustomObject
    with additionalDirs and platformsDirs arrays for the given ProjectType.
    Returns $null if config section is absent or ProjectType not found.
.PARAMETER State
    The build state object carrying BuildConfig.
.PARAMETER ProjectType
    The detected project type (Web, MAUI, etc.).
.OUTPUTS
    PSCustomObject with additionalDirs and platformsDirs arrays or $null.
#>
function Get-CleanTargetsConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [string]$ProjectType = ""
    )
    if (-not $State -or -not $State.BuildConfig -or -not $State.BuildConfig.build -or -not $State.BuildConfig.build.cleanTargetsPerProjectType) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($ProjectType)) {
        return $null
    }
    $targets = $State.BuildConfig.build.cleanTargetsPerProjectType
    if (-not $targets.PSObject.Properties.Name -contains $ProjectType) {
        return $null
    }
    return $targets.$ProjectType
}

# -- Helper: Delegates to ErrorHandling.psm1 Invoke-WithRetry --
# The inline fallback below is ONLY the path taken when ErrorHandling is not
# loaded (PS 5.1 module orphan). It is kept semantically aligned with
# ErrorHandling.Invoke-WithRetry, which is the single source:
#   * attempts: `while ($attempt -le $MaxRetries)` = MaxRetries+1 total tries,
#     matching the canonical, not `for ($i -lt $MaxRetries)` = MaxRetries;
#   * backoff: BASE DELAY IN MILLISECONDS, matching the canonical. The old
#     fallback multiplied a SECONDS value by 2^i while the canonical used ms,
#     so the two paths waited for wildly different times for the same retry;
#   * `$Action.Invoke()` was kept because a scriptblock invoked that way resolves
#     variables in its own defining scope, which is what the two call sites rely
#     on ($Path / $FolderPath).
function Invoke-Retry {
    param(
        [Parameter(Mandatory)] [scriptblock]$Action,
        [int]$MaxRetries = $script:CleanRetryAttempts,
        [int]$DelayBaseSec = $script:CleanRetryDelayBase
    )
    if (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue) {
        return Invoke-WithRetry -Action $Action -MaxRetries $MaxRetries -BaseDelayMs ($DelayBaseSec * 1000)
    }
    $baseDelayMs = [int]($DelayBaseSec * 1000)
    $attempt = 0
    # Fallback path (ErrorHandling not loaded). CORRECTED: this retried EVERY
    # exception, including a permanent UnauthorizedAccessException on a locked
    # file - 4 attempts with 1+2+4 s of sleeps against a condition that cannot
    # resolve. Orchestrator.psm1 documents exactly this defect as the bug it
    # fixed ("the previous version retried EVERY error ... with NO delay, so
    # maxRetries iterations completed in microseconds and a step with a side
    # effect was re-executed immediately N times"), and this fallback still
    # carried it. Classify before retrying, and cap the backoff from the shared
    # constant instead of an inline 30000.
    # 'RetryBackoffMaxMs' was never a BuildConstants key, so this lookup always
    # fell through to the literal and the two retry paths disagreed: the
    # canonical Invoke-WithRetry caps at errorHandling.maxDelayMs (10s) while
    # this fallback waited 30s for the same condition. Use the real key.
    $maxDelayMs = 30000
    try { if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { $maxDelayMs = [int](Get-BuildConstant -Key 'RetryMaxDelayMs' -Fallback 30000) } } catch { }
    while ($attempt -le $MaxRetries) {
        try { return $Action.Invoke() }
        catch {
            if ($attempt -ge $MaxRetries) { throw }
            # Only transient failures are worth another attempt.
            $retryable = $true
            if (Get-Command Get-ErrorCategory -ErrorAction SilentlyContinue) {
                try { $retryable = ([string](Get-ErrorCategory -ErrorRecord $_) -eq 'Transient') } catch { $retryable = $true }
            } else {
                $msg = ''
                try { $msg = [string]$_.Exception.Message } catch { }
                # Conservative inline classifier: only lock/network/IO races.
                $retryable = ($msg -match '(?i)(network|timeout|connection|temporary|transient|retry|locked|being used|sharing violation)')
            }
            if (-not $retryable) { throw }
            Start-Sleep -Milliseconds ([int][math]::Min($baseDelayMs * [math]::Pow(2, $attempt), $maxDelayMs))
            $attempt++
        }
    }
}

# -- Core Security Function --
# Thin wrapper over PathUtils.Test-PathUnderRoots (single implementation of the
# "GetFullPath + StartsWith" guard previously duplicated in SharedUtils.Invoke-SafeRemove).
# Name + signature unchanged for compatibility with the existing API/tests.
function Assert-SafePath {
    param([string]$Target, [string[]]$AllowedRoots)
    if (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) {
        return (Test-PathUnderRoots -Path $Target -AllowedRoots $AllowedRoots)
    }
    # Level 5 resilience: inline strictly-under fallback (fail-closed) when
    # PathUtils was orphaned — clean must never delete outside allowed roots.
    try {
        $ct = ([System.IO.Path]::GetFullPath([string]$Target)).TrimEnd('\', '/')
        $ccmp = Get-PathComparison

        foreach ($cr in $AllowedRoots) {
            if ([string]::IsNullOrWhiteSpace([string]$cr)) { continue }
            $ca = ([System.IO.Path]::GetFullPath([string]$cr)).TrimEnd('\', '/')
            if ($ct.StartsWith($ca + [System.IO.Path]::DirectorySeparatorChar, $ccmp)) { return $true }
        }
    } catch { }
    return $false
}

function Remove-SafeItem {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string[]]$AllowedRoots,
        [PSCustomObject]$State,
        [switch]$Quiet
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Assert-SafePath -Target $Path -AllowedRoots $AllowedRoots)) { return }
    if (-not (Test-Path -Path $Path -EA SilentlyContinue)) { return }

    try {
        if ($PSCmdlet.ShouldProcess("Item: $Path", "Permanently delete")) {
            Invoke-Retry { Remove-Item -Path $Path -Recurse -Force -EA Stop }
            if ($State -and -not $Quiet) { Write-Log (Get-LocaleMessage -Key 'log.clean.deleted' -MessageArgs @($Path)) $State.Colors.Gray $State }
            return $true
        }
        return $true
    }
    catch {
        if ($State) { Write-Log (Get-LocaleMessage -Key 'log.clean.deleteError' -MessageArgs @($Path, $_.Exception.Message)) $State.Colors.Err $State }
        return $false
    }
}

# -- Core Clean Function --
function Remove-SafeFolder {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath,
        [Parameter(Mandatory = $true)]
        [string[]]$AllowedRoots,
        [PSCustomObject]$State
    )

    if (-not (Test-Path -Path $FolderPath) -or -not (Assert-SafePath -Target $FolderPath -AllowedRoots $AllowedRoots)) { return $false }

    if (Test-ReparsePointItem -Path $FolderPath) {
        # The reparse-point removal is a DESTRUCTIVE action, so it is gated by
        # ShouldProcess like every other deletion here. It previously ran before
        # the check below, which made -WhatIf silently delete the junction/symlink
        # while reporting nothing - the one destructive path in this module that
        # -WhatIf did not cover.
        if (-not $PSCmdlet.ShouldProcess("Reparse point: $FolderPath", "Permanently delete")) { return $true }
        if ($State.OS -eq 'Windows') { & cmd.exe /c rmdir "`"$FolderPath`"" }
        else { Remove-Item -Path $FolderPath -Force -ErrorAction SilentlyContinue }
        return (-not (Test-Path -Path $FolderPath))
    }

    try {
        if ($PSCmdlet.ShouldProcess("Folder: $FolderPath", "Permanently delete")) {
            $result = Remove-SafeFolderStandalone -FolderPath $FolderPath
            if ($result -and $State) { Write-Log (Get-LocaleMessage -Key 'log.clean.deletedFolder' -MessageArgs @($FolderPath)) $State.Colors.Gray $State }
            return $result
        }
        return $true
    }
    catch {
        if ($State) { Write-Log (Get-LocaleMessage -Key 'log.clean.deleteFolderError' -MessageArgs @($FolderPath, $_.Exception.Message)) $State.Colors.Err $State }
        return $false
    }
}

function Add-CleanTarget {
    param(
        [string]$Path,
        [string[]]$AllowedRoots,
        [System.Collections.Generic.List[string]]$Targets
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -Path $Path -PathType Container)) { return }
    if (-not (Assert-SafePath -Target $Path -AllowedRoots $AllowedRoots)) { return }
    if (Test-ReparsePointItem -Path $Path) { return }
    $Targets.Add($Path)
}

function Invoke-SmartClean {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir,
        [string]$OutputSubDir  = "",
        [string]$CsprojPath    = "",
        [string]$ProjectType   = "",
        [switch]$CleanOutputDir
    )

    # StrictMode-safe normalization: typed-with-default guarantees the variable
    # exists, but an explicit -ProjectType $null still binds $null. Never read
    # $ProjectType directly here — a `Set-StrictMode -Version Latest` caller scope
    # (user $PROFILE / Pester / global gbuild fn) turns that read into
    # "cannot be retrieved because it has not been set". try/catch self-heals.
    try { if ($null -eq $ProjectType) { $ProjectType = "" } } catch { $ProjectType = "" }

    $AbsProjectDir = try { [System.IO.Path]::GetFullPath($ProjectDir) } catch { return }
    if (-not (Test-Path -Path $AbsProjectDir -PathType Container)) { return }

    $ScriptRoot = if ($State -and $State.ProjectRoot) { $State.ProjectRoot } elseif ($State -and $State.ScriptRoot) { $State.ScriptRoot } else { $PSScriptRoot }
    $publishOutput = Resolve-PublishOutputDir -State $State
    # paths.publishOutput comes from config and is joined below. Without a traversal
    # guard, a value of '../../..' would widen this recursive-delete allowlist to a
    # drive/volume ancestor. Fail closed on any '..' segment (rooted absolutes are
    # still resolved through the same containment check as everything else).
    if (-not [string]::IsNullOrWhiteSpace($publishOutput) -and -not [System.IO.Path]::IsPathRooted($publishOutput) -and
        ($publishOutput -match '(^|[\\/])\.\.([\\/]|$)')) {
        throw [System.InvalidOperationException]::new((Resolve-LogMessage -Key 'log.clean.line277' -Fallback 'paths.publishOutput must not contain parent-directory segments.'))
    }
    $AllowedRoots = @($AbsProjectDir, (Join-Path $ScriptRoot $publishOutput))

    $IsWeb  = $false
    $IsMaui = $false
    if ($CsprojPath -and (Test-Path -Path $CsprojPath -PathType Leaf)) {
        try {
            [xml]$Xml = Get-Content -Path $CsprojPath -Raw -Encoding UTF8 -ErrorAction Stop
            $Sdk = $Xml.Project.Sdk
            if ($Sdk -eq 'Microsoft.NET.Sdk.Web' -or $Sdk -eq 'Microsoft.NET.Sdk.BlazorWebAssembly') { $IsWeb = $true }
            $UseMauiNode = $Xml.SelectSingleNode("//*[local-name()='UseMaui']")
            if ($UseMauiNode -and $UseMauiNode.InnerText -eq 'true') { $IsMaui = $true }
        } catch {
            $CsprojContent = Get-Content -Path $CsprojPath -Raw -Encoding UTF8 -EA SilentlyContinue
            $IsWeb   = $CsprojContent -match 'Sdk\s*=\s*"Microsoft\.NET\.Sdk\.(Web|BlazorWebAssembly)"'
            $IsMaui  = $CsprojContent -match '<UseMaui>\s*true\s*</UseMaui>'
        }
    }

    $TargetsToClean = [System.Collections.Generic.List[string]]::new()

    foreach ($Name in @(Get-CleanTargetDirNames)) {
        Add-CleanTarget -Path (Join-Path $AbsProjectDir $Name) -AllowedRoots $AllowedRoots -Targets $TargetsToClean
    }

    # Config-driven clean targets per project type (build.cleanTargetsPerProjectType)
    $cleanTargetsConfig = Get-CleanTargetsConfig -State $State -ProjectType $ProjectType
    if ($cleanTargetsConfig) {
        if ($cleanTargetsConfig.additionalDirs) {
            foreach ($dir in $cleanTargetsConfig.additionalDirs) {
                Add-CleanTarget -Path (Join-Path $AbsProjectDir $dir) -AllowedRoots $AllowedRoots -Targets $TargetsToClean
            }
        }
        if ($cleanTargetsConfig.platformsDirs -and $IsMaui) {
            $PlatformsDir = Join-Path $AbsProjectDir 'Platforms'
            if (Test-Path -Path $PlatformsDir -PathType Container) {
                Get-ChildItem -Path $PlatformsDir -Directory -EA SilentlyContinue | ForEach-Object {
                    foreach ($pDir in $cleanTargetsConfig.platformsDirs) {
                        Add-CleanTarget -Path (Join-Path $_.FullName $pDir) -AllowedRoots $AllowedRoots -Targets $TargetsToClean
                    }
                }
            }
        }
    }

    # Fallback for Web/MAUI if config not present
    if (-not $cleanTargetsConfig) {
        if ($IsWeb) {
            foreach ($Pair in @(@('wwwroot','_framework'), @('wwwroot','_content'), @('.vite'), @('node_modules'))) {
                $CombinedPath = $AbsProjectDir
                foreach ($Segment in $Pair) { $CombinedPath = Join-Path $CombinedPath $Segment }
                Add-CleanTarget -Path $CombinedPath -AllowedRoots $AllowedRoots -Targets $TargetsToClean
            }
        }
        if ($IsMaui) {
            foreach ($Name in @('.maui', 'MauiAssets')) {
                Add-CleanTarget -Path (Join-Path $AbsProjectDir $Name) -AllowedRoots $AllowedRoots -Targets $TargetsToClean
            }
            $PlatformsDir = Join-Path $AbsProjectDir 'Platforms'
            if (Test-Path -Path $PlatformsDir -PathType Container) {
                Get-ChildItem -Path $PlatformsDir -Directory -EA SilentlyContinue | ForEach-Object {
                    Add-CleanTarget -Path (Join-Path $_.FullName 'bin') -AllowedRoots $AllowedRoots -Targets $TargetsToClean
                    Add-CleanTarget -Path (Join-Path $_.FullName 'obj') -AllowedRoots $AllowedRoots -Targets $TargetsToClean
                }
            }
        }
    }

    # Only delete lightweight cache files, do NOT parse project.assets.json to avoid hangs and NuGet cache corruption
    $ObjDir = Join-Path $AbsProjectDir "obj"
    if (Test-Path -Path $ObjDir -PathType Container) {
        $CacheFiles = Get-ChildItem -Path $ObjDir -Recurse -File -EA SilentlyContinue |
            Where-Object { $_.Extension -in @('.nuspec', '.cache') -or $_.Name -eq 'project.nuget.cache' } |
            Where-Object { Assert-SafePath -Target $_.FullName -AllowedRoots $AllowedRoots }

        foreach ($File in $CacheFiles) {
            if ($PSCmdlet.ShouldProcess("File: $($File.Name)", "Delete nuget cache file")) {
                Remove-Item -Path $File.FullName -Force -EA SilentlyContinue
            }
        }
    }

    Write-Log (Get-LocaleMessage -Key 'log.clean.started') $State.Colors.Info $State
    $CleanedCount = 0; $FailedCount = 0
    foreach ($Folder in $TargetsToClean) {
        if ($PSCmdlet.ShouldProcess("Folder: $Folder", "Permanently delete")) {
            if (Remove-SafeFolder -FolderPath $Folder -AllowedRoots $AllowedRoots -State $State) { $CleanedCount++ } else { $FailedCount++ }
        }
    }

    if ($FailedCount -eq 0 -and $CleanedCount -gt 0) {
        Write-Log (Get-LocaleMessage -Key 'log.clean.completed' -MessageArgs @($CleanedCount)) $State.Colors.Succ $State
    }

    # Clean Output Dir — single-line progress (col1: progress, col2: file) to avoid
    # hundreds of "Deleted: G:\...\publish-output\web\*.dll" lines flooding console/file.
    # Uses CR overwrite (\r) like BuildProgress heartbeat; CI/redirected hosts fall back
    # to throttled gray logs. Per-file delete is Quiet (no Write-Log), final summary logged.
    if ($CleanOutputDir -and $OutputSubDir) {
        $RawOut = Join-Path (Join-Path $ScriptRoot $publishOutput) $OutputSubDir
        if ((Test-Path -Path $RawOut) -and $PSCmdlet.ShouldProcess("Output Folder: $RawOut", "Clean old Artifacts")) {
            $ArtifactExtensions = $script:CleanArtifactExtensions
            $filesToDelete = @(Get-ChildItem -Path $RawOut -Recurse -File -Force -EA SilentlyContinue |
                Where-Object { $_.Extension -in $ArtifactExtensions } |
                Where-Object { Assert-SafePath -Target $_.FullName -AllowedRoots $AllowedRoots })
            if ($filesToDelete.Count -gt 0) {
                $total = $filesToDelete.Count
                $isCI = $false
                try { $isCI = [bool]($State.IsCI -or $State.NonInteractive) } catch { }
                $useCR = $false
                if (-not $isCI) {
                    try { $useCR = $Host.UI.RawUI -and $Host.UI.RawUI.CursorSize -ge 0 } catch { $useCR = $false }
                }
                $grayColor = try { Resolve-SafeColor -ColorName 'Gray' -State $State -Fallback 'DarkGray' } catch { 'DarkGray' }
                $prevLen = 0
                $deletedCount = 0
                $idx = 0
                foreach ($f in $filesToDelete) {
                    $idx++
                    # Display: progress + filename (relative) truncated to ~60 chars.
                    # Use $f.Name (robust vs 8.3 short-name vs long-path mismatch of
                    # e.g. C:\Users\ADMINI~1 vs C:\Users\Administrator that broke
                    # Substring(RawOut.Length)).
                    # For nested files keep subfolder prefix via manual relative calc when possible.
                    if ($useCR) {
                        $rel = $f.Name
                        try {
                            $full = [System.IO.Path]::GetFullPath($f.FullName)
                            $base = [System.IO.Path]::GetFullPath($RawOut)
                            # Single source for path case sensitivity (PathUtils.Get-PathComparison);
    # the local $script:IsWindows ternary was a second independent decision.
    $caseOpt = if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { Get-PathComparison } else { if ($script:IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal } }
                            if ($full.Length -gt $base.Length -and $full.StartsWith($base, $caseOpt)) {
                                $rel = $full.Substring($base.Length).TrimStart([char[]]@('\','/'))
                                if (-not $rel) { $rel = $f.Name }
                            }
                        } catch { $rel = $f.Name }
                        if ($rel.Length -gt 60) { $rel = '...' + $rel.Substring($rel.Length - 57) }
                        $msg = "  [{0,4}/{1}] Deleting: {2}" -f $idx, $total, $rel
                        # Clamp to the real console width: a line longer than the
                        # window wraps, so every CR rewrite would paint a NEW row
                        # (looks like hundreds of separate "Deleting:" lines).
                        try { $w = [Console]::WindowWidth } catch { $w = 80 }
                        if ($msg.Length -gt ($w - 1)) {
                            $fixedLen = ("  [{0}/{1}] Deleting: " -f $idx, $total).Length
                            $keepFile = ($w - 1) - $fixedLen
                            if ($keepFile -lt 12) { $keepFile = 12 }
                            if ($rel.Length -gt $keepFile) { $rel = '...' + $rel.Substring($rel.Length - ($keepFile - 3)) }
                            $msg = "  [{0,4}/{1}] Deleting: {2}" -f $idx, $total, $rel
                            if ($msg.Length -gt ($w - 1)) { $msg = $msg.Substring(0, $w - 1) }
                        }
                        $pad = if ($prevLen -gt $msg.Length) { ' ' * ($prevLen - $msg.Length) } else { '' }
                        try { Write-Host "`r$msg$pad" -NoNewline -ForegroundColor $grayColor } catch { Write-Host "`r$msg$pad" -NoNewline }
                        $prevLen = $msg.Length
                    } elseif ($idx -eq $total) {
                        # CI/redirected host: CR overwrite impossible here, so never log
                        # per-file deletions (the final [SmartClean] summary below reports
                        # counts already; per-file rows flood the log otherwise).
                    }
                    if (Remove-SafeItem -Path $f.FullName -AllowedRoots $AllowedRoots -State $State -Quiet) { $deletedCount++ }
                }
                if ($useCR) { try { Write-Host "" } catch { } }
                if ($deletedCount -gt 0) {
                    Write-Log (Get-LocaleMessage -Key 'log.clean.artifacts' -MessageArgs @($deletedCount, $OutputSubDir, $total)) $State.Colors.Succ $State
                }
            }

            $outFolders = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
                @(Get-BuildConstant -Key 'CleanOutputFolderNames' -Fallback @('wwwroot', 'bin', 'obj', '_framework'))
            } else { @('wwwroot', 'bin', 'obj', '_framework') }
            foreach ($FolderName in $outFolders) {
                $Fp = Join-Path $RawOut $FolderName
                if (Test-Path -Path $Fp) { Remove-SafeItem -Path $Fp -AllowedRoots $AllowedRoots -State $State | Out-Null }
            }
        }
    }

    # L5: plugin clean dispatch (was orphan Invoke-PluginCleanFor). Non-dotnet
    # projects (no csproj) delegate to their language plugin's CustomClean;
    # missing plugin/fn = no-op $true so dotnet flows are unaffected.
    if ([string]::IsNullOrWhiteSpace($CsprojPath) -and -not [string]::IsNullOrWhiteSpace($ProjectType)) {
        if (Get-Command Invoke-PluginCleanFor -ErrorAction SilentlyContinue) {
            try { [void](Invoke-PluginCleanFor -State $State -Language $ProjectType -ProjectDir $AbsProjectDir) } catch { }
        }
    }
}

# -- Module-level wrappers (callable standalone) --
function Remove-SafeFolderStandalone {
    param([string]$FolderPath)
    if ([string]::IsNullOrWhiteSpace($FolderPath) -or -not (Test-Path -Path $FolderPath -EA SilentlyContinue)) { return $false }
    if (Test-ReparsePointItem -Path $FolderPath) {
        Remove-Item -Path $FolderPath -Force -ErrorAction SilentlyContinue
        return (-not (Test-Path -Path $FolderPath))
    }
    try { Invoke-Retry { Remove-Item -Path $FolderPath -Recurse -Force -EA Stop }; return $true }
    catch { return $false }
}

Export-ModuleMember -Function @('Invoke-SmartClean', 'Remove-SafeItem', 'Assert-SafePath', 'Remove-SafeFolder', 'Add-CleanTarget')
