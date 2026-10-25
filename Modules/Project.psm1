# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# ==================================================================================================
# Modules/Project.psm1 (Configuration-Driven, Portable, Professional)
# ==================================================================================================



# ==== Import centralized OS detection ====
# Nested import WITHOUT -Force: references the globally loaded Environment when
# present (gbuild bootstrap / Import-GBuildModule) - a nested -Force re-import
# would orphan the global Environment module in PS 5.1 (same as the Logging rule).
$projectEnvPath = Join-Path $PSScriptRoot 'Environment.psm1'
if (Test-Path $projectEnvPath) { Import-Module $projectEnvPath -DisableNameChecking -ErrorAction SilentlyContinue }
$projectLogPath = Join-Path $PSScriptRoot 'Logging.psm1'
# Nested import WITHOUT -Force (references the globally loaded Logging from the
# gbuild.ps1 bootstrap) — a nested -Force re-import orphans the global Logging
# module in PS 5.1, breaking Write-Log resolution for every module.
if (Test-Path $projectLogPath) { $null = Import-Module $projectLogPath -DisableNameChecking -ErrorAction SilentlyContinue }

$null = Import-GBuildModule -Names @('SharedUtils', 'PathUtils') -Force

# ==== OS detection uses Get-OSPlatform (Environment.psm1, Tier-1 import) ====

# ==== Module Configuration (Default Fallbacks) ====
# These are ONLY used when gbuild.config.json is unavailable or missing keys.
# At runtime, Resolve-ProjectConfig merges live config on top of these defaults.
# NOTE: PublishOutputDir resolved via SharedUtils.Resolve-PublishOutputDir at call time (not snapshotted)
# to avoid stale values when config changes between module load and execution.
# Pre-computed exclude regex (import-time): PathUtils when available, else an
# inline literal fallback — an orphaned PathUtils must never break module import.
$script:ProjectExcludePatternInit = if (Get-Command Get-ExcludeDirPattern -ErrorAction SilentlyContinue) {
    (Get-ExcludeDirPattern -FromConstant 'SyntaxCheckExcludeDirs' -Extra @('packages','.vs','.idea','TestResults')) + '(.*)'
} else {
    # .tools MUST be in this list: BuildConstants.SyntaxCheckExcludeDirs documents
    # it as vendored third-party tooling that must never block a preflight syntax
    # gate, and its PSScriptAnalyzer compat JSONs use reserved 'psobject' member
    # names. Dropping it here made Get-AllProjects enumerate .tools whenever
    # PathUtils was not loaded at import time.
    $script:ProjectExcludeFallbackDirs = @(@(if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { @(Get-BuildConstant -Key 'SyntaxCheckExcludeDirs' -Fallback @()) } else { @() }) + @('packages','.vs','.idea','TestResults','obj','bin','.git','node_modules','publish-output','.gbuildcache','build-reports','logs','_Build','.tools') | Select-Object -Unique)
    '[\\/](' + (($script:ProjectExcludeFallbackDirs | ForEach-Object { [regex]::Escape([string]$_) }) -join '|') + ')[\\/](.*)'
}
$script:ProjectConfig = [PSCustomObject]@{
    DefaultTfm          = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { Get-BuildConstant -Key 'DefaultTfm' -Fallback '' } else { '' }

    # Project type detection - .NET SDK identifiers
    DefaultProjectType  = "Library"
    SdkWeb              = "Microsoft.NET.Sdk.Web"
    SdkBlazorWasm       = "Microsoft.NET.Sdk.BlazorWebAssembly"
    OutputTypeExe       = "Exe"
    OutputTypeWinExe    = "WinExe"

    # Project discovery defaults (overridden by config.projects.*)
    DefaultSearchDepth  = Get-BuildConstant -Key 'ProjectSearchDepth' -Fallback 5
    # Single source: PathUtils.Get-ExcludeDirPattern over SyntaxCheckExcludeDirs
    # (adds domain extras packages/.vs/.idea). Level 5 resilience: import-time
    # guard + inline regex fallback so an orphaned PathUtils never breaks import.
    ExcludePattern      = $script:ProjectExcludePatternInit
    TestProjectPatterns = @('\.(Tests|Specs|UnitTests|IntegrationTests)$')
    SystemDirPattern    = '[\\/]_[^/\\]*[\\/]'

    # Launch settings
    PropertiesDir       = "Properties"
    LaunchSettingsFile  = "launchSettings.json"
    DefaultPort         = Get-BuildConstant -Key 'DefaultPort' -Fallback 5000

    # Messages (internationalizable)
    Messages = [PSCustomObject]@{
        ScanningProjects      = "Scanning for project files..."
        RootDirectory         = "Root directory: {0}"
        FoundProjects         = "Found {0} project(s)"
        AutoSelectSameLevel   = "Auto-select: {0} (same level as working directory)"
        AutoSelectNameMatch   = "Auto-select: {0} (matches folder name)"
        AutoSelectNonTest     = "Auto-select: {0} (excluded system/test projects)"
        NonInteractiveSelect  = "NonInteractive: Auto-selecting {0}"
        MultipleProjects     = "Found multiple projects, please select:"
        SelectIndex           = "Enter index (or press Enter for 0)"
        ParseError            = "Cannot parse {0}: {1}"
    }

    # XML node names for project type detection (real .NET SDK property names)
    XmlNodes = [PSCustomObject]@{
        UseMaui         = "UseMaui"
        UseWindowsForms = "UseWindowsForms"
        UseWPF          = "UseWPF"
        OutputType      = "OutputType"
    }

    # Project type mappings
    ProjectTypes = [PSCustomObject]@{
        MAUI       = "MAUI"
        Web        = "Web"
        BlazorWasm = "BlazorWasm"
        WinForms   = "WinForms"
        WPF        = "WPF"
        Console    = "Console"
        WinExe     = "WinExe"
        Avalonia   = "Avalonia"
        WinUI      = "WinUI"
    }
}

# ==== Helper: test XML boolean property (created once at module scope) ====
$script:TestXmlBool = {
    param([xml]$XmlDoc, [string]$NodeName)

Set-StrictMode -Version 1.0
    $node = $XmlDoc.SelectSingleNode("//*[local-name()='$NodeName']")
    return ($node -and $node.InnerText -eq 'true')
}

# ===------------------------------------------------------------------------------------------------------------------------------------------------------===
# SHARED UTILITIES
# ===------------------------------------------------------------------------------------------------------------------------------------------------------===

<#
.SYNOPSIS
    Detects whether the current session supports interactive user input.
.DESCRIPTION
    Checks $State.NonInteractive flag first, then probes $Host.UI.RawUI
    to handle headless/CI environments where Read-Host would hang.
    Centralises the non-interactive detection logic that was previously
    duplicated across Project.psm1 and the former module facade.
.PARAMETER State
    The global build state object (GState).
.OUTPUTS
    bool: $true if the session can accept interactive input, $false otherwise.
#>
function Test-InteractiveSession {
    [CmdletBinding()]
    [OutputType([bool])]
    param([PSCustomObject]$State)

    # Explicit flag from caller (e.g. -NonInteractive switch, CI mode)
    if ($State -and $State.NonInteractive -eq $true) { return $false }

    # Environment variable fallback (CI pipelines often set NON_INTERACTIVE=true)
    if ($env:NON_INTERACTIVE -and ($env:NON_INTERACTIVE -eq 'true' -or $env:NON_INTERACTIVE -eq '1' -or [bool]$env:NON_INTERACTIVE)) { return $false }

    # Probe the host UI - if $Host.UI.RawUI is unavailable, we are headless.
    # ServerHost (e.g. remoting, jobs) is non-interactive; ConsoleHost is interactive.
    # On some hosts (VS Code, Windows Terminal with PSReadLine) CursorSize may throw
    # even though the session is interactive, so treat probe failure as interactive.
    try {
        $null = $Host.UI.RawUI.CursorSize
        return $true
    } catch {
        if ($Host.Name -eq 'ServerHost') { return $false }
        return $true
    }
}


<#
.SYNOPSIS
    Merges runtime config (from gbuild.config.json) onto module defaults.
.DESCRIPTION
    Reads the "projects" section from $State.BuildConfig and overrides
    the module-level $script:ProjectConfig values.  This allows the
    config file to be the single source of truth while the module
    defaults guarantee portability when no config is present.
.PARAMETER State
    The global build state object that may contain .BuildConfig.
#>
function Resolve-ProjectConfig {
    [CmdletBinding()]
    param([PSCustomObject]$State)

    if (-not $State -or -not $State.BuildConfig) { return }
    $cfg = $State.BuildConfig

    # projects.exclude - convert glob patterns to a single regex exclude pattern
    if ($cfg.projects -and $cfg.projects.exclude -and $cfg.projects.exclude.Count -gt 0) {
        # Build regex from glob-style patterns:  **/bin/** - [\\/]bin[\\/]
        $parts = foreach ($glob in $cfg.projects.exclude) {
            # Escape special regex characters in the glob pattern
            $escaped = $glob -replace '\*\*/', '' -replace '/\*\*', ''
            $escaped = $escaped -replace '([.+?^${}()|\[\]\\])', '\$1'
            $escaped = $escaped.Trim('/')
            "[\\/]$escaped[\\/]"
        }
        $script:ProjectConfig.ExcludePattern = '(' + ($parts -join '|') + ')'
    }

    # projects.testProjectPatterns - regex patterns for test project detection
    if ($cfg.projects -and $cfg.projects.testProjectPatterns -and $cfg.projects.testProjectPatterns.Count -gt 0) {
        $script:ProjectConfig.TestProjectPatterns = @($cfg.projects.testProjectPatterns)
    }

    # projects.systemDirPattern - regex pattern for system directory detection
    if ($cfg.projects -and $cfg.projects.systemDirPattern) {
        $script:ProjectConfig.SystemDirPattern = $cfg.projects.systemDirPattern
    }

    # projects.autoSelectStrategy - smart auto-select behaviour (L5: was orphan
    # config key). 'smart' (default) = rules 1-4 below; 'off'/'manual' = skip
    # auto-select and go straight to interactive/non-interactive fallback.
    # projects.preferRootProject - when $false, skip rule 1 (same-level) so a
    # nested project can win over the root one.
    if ($cfg.projects -and $cfg.projects.autoSelectStrategy) {
        $script:ProjectConfig | Add-Member -MemberType NoteProperty -Name AutoSelectStrategy -Value ([string]$cfg.projects.autoSelectStrategy) -Force
    } elseif (-not ($script:ProjectConfig.PSObject.Properties.Name -contains 'AutoSelectStrategy')) {
        $script:ProjectConfig | Add-Member -MemberType NoteProperty -Name AutoSelectStrategy -Value 'smart' -Force
    }
    if ($cfg.projects -and ($null -ne $cfg.projects.preferRootProject)) {
        $script:ProjectConfig | Add-Member -MemberType NoteProperty -Name PreferRootProject -Value ([bool]$cfg.projects.preferRootProject) -Force
    } elseif (-not ($script:ProjectConfig.PSObject.Properties.Name -contains 'PreferRootProject')) {
        $script:ProjectConfig | Add-Member -MemberType NoteProperty -Name PreferRootProject -Value $true -Force
    }

    # Override TFM from config defaults first, then active profile
    $defaultTfm = Get-BuildConstant -Key 'DefaultTfm' -State $State
    if ($defaultTfm) { $script:ProjectConfig.DefaultTfm = $defaultTfm }
    if ($cfg.profiles -and $State.ActiveProfile) {
        $activeProfile = $cfg.profiles.($State.ActiveProfile)
        if ($activeProfile -and $activeProfile.targetFramework) {
            $script:ProjectConfig.DefaultTfm = $activeProfile.targetFramework
        }
    }
}

# ===------------------------------------------------------------------------------------------------------------------------------------------------------===
# CORE FUNCTIONS
# ===------------------------------------------------------------------------------------------------------------------------------------------------------===

<#
.SYNOPSIS
    Parses a .csproj file and returns project type and target frameworks.
.DESCRIPTION
    Reads the MSBuild XML to determine:
      - Target framework(s) from <TargetFramework> / <TargetFrameworks>
      - Project type by inspecting SDK attribute and property nodes
        (UseMaui, UseWindowsForms, UseWPF, OutputType)
    Falls back to $State.CurrentTfm or module default when TFM cannot be read.
.PARAMETER CsprojPath
    Full path to the .csproj file.
.PARAMETER State
    The global build state object.
.OUTPUTS
    PSCustomObject with .ProjectType (string) and .Tfms (string[]).
#>
function Get-ProjectMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$CsprojPath,
        [PSCustomObject]$State
    )

    $fallbackTfm = if ($State -and $State.CurrentTfm) { $State.CurrentTfm } else { $script:ProjectConfig.DefaultTfm }
    $default = [PSCustomObject]@{ ProjectType = 'Unknown'; Tfms = @($fallbackTfm) }

    if (-not (Test-Path -Path $CsprojPath -PathType Leaf)) { return $default }

    # Cache Write-Log availability once per call
    $hasWriteLog = [bool](Get-Command Write-Log -ErrorAction SilentlyContinue)

    try {
        [xml]$xml = Get-Content -Path $CsprojPath -Raw -Encoding UTF8 -ErrorAction Stop

        # -- Parse TFMs (supports both TargetFramework and TargetFrameworks) --
        $tfms = [System.Collections.ArrayList]@()
        $nodes = $xml.SelectNodes("//*[local-name()='TargetFramework' or local-name()='TargetFrameworks']")
        foreach ($node in $nodes) {
            if ($node.InnerText) {
                $node.InnerText -split ';' | ForEach-Object {
                    $trimmed = $_.Trim()
                    if ($trimmed) { $tfms.Add($trimmed) | Out-Null }
                }
            }
        }
        # Drop unexpanded MSBuild expressions: csproj files commonly append with
        # $(TargetFrameworks);netX-windows inside a Condition block, and the raw
        # XML value keeps the literal '$(...)' which is NOT a real TFM. Feeding it
        # downstream breaks DefaultTfm selection and menu option availability.
        $realTfms = [System.Collections.ArrayList]@()
        foreach ($t in $tfms) {
            if (-not ($t -match '\$\(([^)]*)\)')) { [void]$realTfms.Add($t) }
        }
        if ($realTfms.Count -gt 0) { $tfms = @($realTfms) }
        $tfms = @($tfms | Select-Object -Unique)
        if ($tfms.Count -eq 0) { $tfms = @($fallbackTfm) }

        # -- Get SDK attribute safely --
        $sdk = $null
        try { $sdk = $xml.DocumentElement.GetAttribute('Sdk') } catch {
            # benign - $sdk stays null when attribute absent
            }

        # -- Determine ProjectType via real .NET SDK property nodes --
        $projectType = $script:ProjectConfig.DefaultProjectType
        $xmlNodes    = $script:ProjectConfig.XmlNodes
        $types       = $script:ProjectConfig.ProjectTypes

        # Use scoped scriptblock helper (created at module scope)
        if (& $script:TestXmlBool $xml $xmlNodes.UseMaui) {
            $projectType = $types.MAUI
        }
        elseif ($sdk -eq $script:ProjectConfig.SdkWeb) {
            $projectType = $types.Web
        }
        elseif ($sdk -eq $script:ProjectConfig.SdkBlazorWasm) {
            $projectType = $types.BlazorWasm
        }
        elseif (& $script:TestXmlBool $xml $xmlNodes.UseWindowsForms) {
            $projectType = $types.WinForms
        }
        elseif (& $script:TestXmlBool $xml $xmlNodes.UseWPF) {
            $projectType = $types.WPF
        }
        elseif ($xml.OuterXml -match 'Avalonia\.Framework' -or $xml.OuterXml -match 'PackageReference[^>]*Include="Avalonia') {
            $projectType = $types.Avalonia
        }
        elseif ($xml.OuterXml -match 'UseWinUI' -or $xml.OuterXml -match 'Microsoft.WindowsAppSDK' -or $xml.OuterXml -match 'PackageReference[^>]*Include="WinUI') {
            $projectType = $types.WinUI
        }
        else {
            $outputNode = $xml.SelectSingleNode("//*[local-name()='$($xmlNodes.OutputType)']")
            if ($outputNode -and $outputNode.InnerText) {
                switch ($outputNode.InnerText.Trim()) {
                    $script:ProjectConfig.OutputTypeExe    { $projectType = $types.Console }
                    $script:ProjectConfig.OutputTypeWinExe { $projectType = $types.WinExe  }
                }
            }
        }

        return [PSCustomObject]@{
            ProjectType = $projectType
            Tfms        = $tfms
        }
    } catch {
        if ($hasWriteLog) {
            Write-Log (Get-LocaleMessage -Key 'log.project.parseError' -MessageArgs @($CsprojPath, $_)) "Warn" $State
        }
        return $default
    }
}

<#
.SYNOPSIS
    Discovers all .csproj files under a root directory.
.DESCRIPTION
    Uses Invoke-CompatibleChildItem (from Environment.psm1) when available
    for PS 5.1 compatibility, falls back to native Get-ChildItem -Depth.
.PARAMETER SearchRoot
    The directory to search from.
.PARAMETER Depth
    Maximum directory depth (default from module config).
.PARAMETER State
    Optional: the global build state object (used for logging).
.OUTPUTS
    FileInfo[]: Array of .csproj FileInfo objects.
#>
function Get-AllProjects {
    [CmdletBinding()]
    param(
        [string]$SearchRoot,
        [int]$Depth = $script:ProjectConfig.DefaultSearchDepth,
        [PSCustomObject]$State
    )

    $excludePattern = $script:ProjectConfig.ExcludePattern

    # Use Invoke-CompatibleChildItem when available (cross-platform PS 5.1+)
    if (Get-Command Invoke-CompatibleChildItem -ErrorAction SilentlyContinue) {
        $allProjects = Invoke-CompatibleChildItem -Path $SearchRoot -Recurse -File -Depth $Depth -Filter "*.csproj" |
                       Where-Object { $_.FullName -notmatch $excludePattern }
    } else {
        # Fallback: native Get-ChildItem (PS 6+)
        $allProjects = Get-ChildItem -Path $SearchRoot -Recurse -Depth $Depth -Filter *.csproj -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.FullName -notmatch $excludePattern }
    }

    return @($allProjects)
}

<#
.SYNOPSIS
    Smart project discovery with zero-touch auto-selection.
.DESCRIPTION
    Scans for .csproj files and applies heuristics to auto-select the most
    likely target project:
      1. Project at the same level as WorkingDir
      2. Project whose name matches the root folder
      3. Non-test/non-system project (when only one remains)
      4. Non-interactive fallback (first non-test project)
      5. Interactive prompt (last resort)
.PARAMETER State
    The global build state object (required).
.OUTPUTS
    FileInfo: The selected .csproj file, or $null if none found.
#>
function Find-Project {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject]$State)

    # Validate State
    if (-not $State) {
        Write-Error (Get-LocaleMessage -Key 'log.project.stateNull')
        return $null
    }

    # Merge config overrides onto module defaults
    Resolve-ProjectConfig -State $State

    # Cache Write-Log availability once for this entire function
    $hasWriteLog = [bool](Get-Command Write-Log -ErrorAction SilentlyContinue)

    # Convenience wrapper that respects the cached check with proper validation
    $log = {
        param([string]$Msg, [string]$Color)
        if ($hasWriteLog -and $Msg -and -not [string]::IsNullOrWhiteSpace($Msg)) {
            Write-Log $Msg $Color $State
        }
    }

    & $log (Get-LocaleMessage -Key 'log.project.scanning') "Gray"

    # Resolve search root. Portable/embedded mode: when _Build lives inside the
    # project (e.g. MyMaui/_Build), the launch directory (WorkingDir) is _Build
    # itself and contains no .csproj. State.ProjectRoot is the resolved project
    # location, so it must take priority. Fall back to WorkingDir, then ScriptRoot.
    #
    # Explicit -Project authority: when the user passed -Project, the resolved
    # ProjectRoot is the SINGLE source of truth. We must NOT silently fall back to
    # the current working directory (ScriptRoot's parent) — that is exactly what
    # caused the wrong project (WebUI) to be built. If the explicit root yields no
    # project, fail loudly instead of scanning the wrong tree.
    $explicitProject = $false
    if ($State -and $State.PSObject.Properties.Name -contains 'ExplicitProject' -and -not [string]::IsNullOrWhiteSpace($State.ExplicitProject)) {
        $explicitProject = $true
    }

    if ($explicitProject -and $State.ProjectRoot -and (Test-Path $State.ProjectRoot)) {
        $searchRoot = $State.ProjectRoot
        & $log (Get-LocaleMessage -Key 'log.project.explicitRoot' -MessageArgs @($searchRoot)) "Gray"
    } else {
        $candidateRoots = @(
            if ($State.ProjectRoot -and (Test-Path $State.ProjectRoot)) { $State.ProjectRoot }
            if ($State.WorkingDir  -and (Test-Path $State.WorkingDir))  { $State.WorkingDir }
            if ($State.ScriptRoot  -and (Test-Path $State.ScriptRoot))  { $State.ScriptRoot }
        )
        $candidateRoots = @($candidateRoots | Select-Object -Unique)

        # Validate searchRoot
        $searchRoot = if ($candidateRoots -and $candidateRoots.Count -gt 0) { $candidateRoots[0] }
                      elseif (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot }
                      else { $null }
    }

    if (-not $searchRoot -or [string]::IsNullOrWhiteSpace($searchRoot)) {
        # Log-only (no Write-Error): callers treat $null as "fall back to language
        # detection", and a non-terminating error here would falsely fail the whole
        # pipeline step via the 2>&1 ErrorRecord check in Invoke-PipelineStep.
        & $log (Get-LocaleMessage -Key 'log.project.noValidRoot') "Err"
        return $null
    }

    & $log (Get-LocaleMessage -Key 'log.project.rootDirectory' -MessageArgs @($searchRoot)) "Gray"

    # Validate searchRoot before calling Get-AllProjects
    if (-not (Test-Path $searchRoot)) {
        Write-Error (Get-LocaleMessage -Key 'log.project.searchRootMissing' -MessageArgs @($searchRoot))
        return $null
    }

    $allProjects = Get-AllProjects -SearchRoot $searchRoot -State $State
    & $log (Get-LocaleMessage -Key 'log.project.found' -MessageArgs @($allProjects.Count)) "Gray"

    if ($allProjects.Count -eq 0) {
        if ($explicitProject) {
            # Log-only (no Write-Error): ScanProject falls back to language detection
            # for non-dotnet projects (Node/Python/Go/...). See search-root guard above.
            & $log (Get-LocaleMessage -Key 'log.project.noneFound' -MessageArgs @($searchRoot)) "Err"
        }
        return $null
    }
    if ($allProjects.Count -eq 1) { return $allProjects[0] }

    # ------------------------------------------------------------------------------------------------------------------------------
    # SMART AUTO-SELECT (Zero-Touch: avoid Read-Host when possible)
    # Honours projects.autoSelectStrategy ('smart' default / 'off'|'manual' to
    # skip) and projects.preferRootProject ($false skips rule 1).
    # ------------------------------------------------------------------------------------------------------------------------------
    $autoStrategy = 'smart'
    try { if ($script:ProjectConfig.PSObject.Properties.Name -contains 'AutoSelectStrategy' -and $script:ProjectConfig.AutoSelectStrategy) { $autoStrategy = [string]$script:ProjectConfig.AutoSelectStrategy } } catch { }
    $preferRoot = $true
    try { if ($script:ProjectConfig.PSObject.Properties.Name -contains 'PreferRootProject') { $preferRoot = [bool]$script:ProjectConfig.PreferRootProject } } catch { }
    $skipAuto = ($autoStrategy -eq 'off') -or ($autoStrategy -eq 'manual') -or ($autoStrategy -eq 'false')

    # 1. Project at the same level as WorkingDir (skipped when preferRootProject=false)
    if (-not $skipAuto -and $preferRoot) {
    $workDirProjects = @($allProjects | Where-Object { $_.DirectoryName -eq $searchRoot })
    if ($workDirProjects.Count -eq 1) {
        & $log (Get-LocaleMessage -Key 'log.project.autoSameLevel' -MessageArgs @($workDirProjects[0].Name)) "Succ"
        return $workDirProjects[0]
    }
    }

    # 2. Project whose name matches the root folder name
    if (-not $skipAuto) {
    $folderName = Split-Path $searchRoot -Leaf
    $nameMatch = @($allProjects | Where-Object { $_.BaseName -eq $folderName })
    if ($nameMatch.Count -eq 1) {
        & $log (Get-LocaleMessage -Key 'log.project.autoNameMatch' -MessageArgs @($nameMatch[0].Name)) "Succ"
        return $nameMatch[0]
    }
    }

    # 3. Exclude test & system projects (skipped when autoSelectStrategy=off/manual)
    $testPatterns  = $script:ProjectConfig.TestProjectPatterns
    $systemPattern = $script:ProjectConfig.SystemDirPattern
    $nonTestProjects = @($allProjects | Where-Object {
        $baseName = $_.BaseName
        $matchesTest = $false
        foreach ($pattern in $testPatterns) {
            if ($baseName -match $pattern) { $matchesTest = $true; break }
        }
        $matchesSystem = $_.FullName -match $systemPattern
        -not $matchesTest -and -not $matchesSystem
    })
    if (-not $skipAuto -and $nonTestProjects.Count -eq 1) {
        & $log (Get-LocaleMessage -Key 'log.project.autoNonTest' -MessageArgs @($nonTestProjects[0].Name)) "Succ"
        return $nonTestProjects[0]
    }

    # 4. Non-interactive fallback
    if (-not (Test-InteractiveSession -State $State)) {
        $chosen = if ($nonTestProjects.Count -gt 0) { $nonTestProjects[0] } else { $allProjects[0] }
        & $log (Get-LocaleMessage -Key 'log.project.nonInteractive' -MessageArgs @($chosen.Name)) "Info"
        return $chosen
    }

    # 5. Interactive prompt (last resort)
    $displayList = if ($nonTestProjects.Count -gt 0) { $nonTestProjects } else { $allProjects }
    & $log "`n$(Get-LocaleMessage -Key 'log.project.multiple')" "Info"
    for ($i = 0; $i -lt $displayList.Count; $i++) {
        & $log "  [$i] $($displayList[$i].FullName)" "Gray"
    }

    $sel = Read-Host "  $(Get-LocaleMessage -Key 'log.project.selectIndex')"
    $idx = 0
    if ([int]::TryParse($sel, [ref]$idx)) {
        if ($idx -lt 0 -or $idx -ge $displayList.Count) { $idx = 0 }
    }

    return $displayList[$idx]
}

<#
.SYNOPSIS
    Reads port numbers from a project's launchSettings.json.
.PARAMETER ProjectDir
    The project directory containing Properties/launchSettings.json.
.PARAMETER State
    Optional: the global build state object (used for logging).
.OUTPUTS
    HashSet[int]: Set of unique port numbers found.
#>
function Get-LaunchSettingsPorts {
    [CmdletBinding()]
    param(
        [string]$ProjectDir,
        [PSCustomObject]$State
    )

    $ports = [System.Collections.Generic.HashSet[int]]::new()
    $lsPath = Join-Path (Join-Path $ProjectDir $script:ProjectConfig.PropertiesDir) $script:ProjectConfig.LaunchSettingsFile

    if (Test-Path -Path $lsPath) {
        try {
            $raw = Get-Content -Path $lsPath -Raw -Encoding UTF8
            $cleanJson = Remove-JsonComments -JsonWithComments $raw
            $ls = $cleanJson | ConvertFrom-Json -ErrorAction Stop

            if ($null -ne $ls.profiles) {
                $ls.profiles.PSObject.Properties.Value | ForEach-Object {
                    if ($_.applicationUrl) {
                        $_.applicationUrl -split ';' | ForEach-Object {
                            if ($_ -match ':(\d+)') {
                                [void]$ports.Add([int]$matches[1])
                            }
                        }
                    }
                }
            }
        } catch {
            # Port detection is optional - log only if Write-Log is available
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log (Get-LocaleMessage -Key 'log.project.launchSettingsError' -MessageArgs @($_)) "Warn" $State
            }
        }
    }
    return $ports
}

<#
.SYNOPSIS
    Returns the first port from launchSettings.json, or the default port.
.PARAMETER ProjectDir
    The project directory.
.PARAMETER State
    Optional: the global build state object.
.OUTPUTS
    int: The resolved port number.
#>
function Get-ProjectPort {
    [CmdletBinding()]
    param(
        [string]$ProjectDir,
        [PSCustomObject]$State
    )

    $ports = Get-LaunchSettingsPorts -ProjectDir $ProjectDir -State $State
    if ($ports.Count -gt 0) { return @($ports)[0] }

    # Read default port from BuildConstants (config-first via Get-BuildConstant)
    $defaultPort = $script:ProjectConfig.DefaultPort
    $cfgPort = Get-BuildConstant -Key 'DefaultPort' -State $State
    if ($cfgPort -and $cfgPort -gt 0) { $defaultPort = $cfgPort }

    return $defaultPort
}

<#
.SYNOPSIS
    Single source of truth for the .NET project-type list.
.DESCRIPTION
    Returns the canonical .NET project types. Reads build.menu.dotnetTypes from
    config when present (appending 'Unknown'), otherwise the built-in default.
    Used by the menu, orchestrator dispatch and non-.NET routing so all three
    consume the same list instead of duplicated literals.
.PARAMETER State
    The build state object (optional — config lookup when provided).
#>
function Get-ProjectTypes {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([PSCustomObject]$State)
    $cfgTypes = Get-ConfigValue -Path 'build.menu.dotnetTypes' -State $State
    if ($cfgTypes -is [array] -and $cfgTypes.Count -gt 0) {
        return @(@($cfgTypes) + 'Unknown' | Select-Object -Unique)
    }
    return @('MAUI','Web','BlazorWasm','WinForms','WinExe','WPF','WinUI','Console','Library','Unknown','Avalonia')
}

Export-ModuleMember -Function @('Get-ProjectMetadata', 'Find-Project', 'Get-LaunchSettingsPorts', `
    'Get-ProjectPort', 'Get-AllProjects', 'Test-InteractiveSession', 'Get-ProjectTypes')
