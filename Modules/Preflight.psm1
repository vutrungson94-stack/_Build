# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# ==================================================================================================
# Modules/Preflight.psm1 — Cross-Language Pre-Build Validation
# ==================================================================================================

. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('SharedUtils', 'PathUtils')

Import-GBuildModule -Names @('LanguageDetector','SharedUtils','Loader') -Force
$null = Import-GBuildModule -Names @('BuildConstants') -Force

<#
.SYNOPSIS
    Validates a project manifest file is parseable.
.DESCRIPTION
    Supports XML (.csproj/.fsproj/.vbproj/.xml), JSON (.json/.package.json/.composer.json),
    TOML (.toml/.pyproject.toml/.cargo.toml/.go.mod), YAML (.yml/.yaml), Dockerfile,
    CMakeLists.txt, Gradle (.gradle/.kts), Gemfile.
#>
function Test-ProjectManifest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [PSCustomObject]$State
    )

Set-StrictMode -Version 1.0
    if (-not (Test-Path $Path)) {
        return @{ Passed = $false; Errors = @("File not found: $Path"); Warnings = @() }
    }
    $name = [System.IO.Path]::GetFileName($Path).ToLowerInvariant()
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    try {
        if ($ext -in @('.csproj','.fsproj','.vbproj','.xml')) {
            $null = [xml](Get-Content -Path $Path -Raw -Encoding UTF8 -EA Stop)
            return @{ Passed = $true; Errors = @(); Warnings = @() }
        }
        if ($ext -eq '.json' -or $name -eq 'package.json' -or $name -eq 'composer.json') {
            $raw = Get-Content -Path $Path -Raw -Encoding UTF8 -EA Stop
            $raw = Remove-JsonComments -JsonWithComments $raw
            # -AsHashTable (PS 6+) tolerates "" property keys used by npm/NuGet lockfiles.
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $null = $raw | ConvertFrom-Json -AsHashTable -EA Stop
            } else {
                $null = $raw | ConvertFrom-Json -EA Stop
            }
            return @{ Passed = $true; Errors = @(); Warnings = @() }
        }
        # Solution and script-based manifests: no structural schema to validate —
        # verify readability so missing/corrupt files still fail closed.
        if ($ext -eq '.sln' -or $name -in @('setup.py', 'makefile', 'build.sbt', 'package.swift', 'mix.exs', 'gemfile', 'rakefile', 'vagrantfile')) {
            $null = Get-Content -Path $Path -Raw -Encoding UTF8 -EA Stop
            return @{ Passed = $true; Errors = @(); Warnings = @() }
        }
        if ($ext -in @('.toml') -or $name -in @('pyproject.toml','cargo.toml','go.mod')) {
            $content = Get-Content -Path $Path -Raw -Encoding UTF8 -EA Stop
            $warnings = @()
            # L5: structural TOML validation (previously a single '^\s*\[' check).
            # Still fail-open (Passed=true) for compat — only truly unreadable
            # files fail — but suspicious content now surfaces as warnings so
            # misconfigurations are visible instead of silent.
            $hasSection = $content -match '(?m)^\s*\[[A-Za-z0-9_\-". ]+\]'
            $hasPair = $content -match '(?m)^\s*[A-Za-z0-9_\-".]+\s*='
            if (-not $hasSection -and -not $hasPair) {
                $warnings += 'TOML has neither [section] nor key = value; verify file content'
            } else {
                if ($content -match '(?m)^\s*\[{2,}') { $warnings += 'TOML has malformed [[section]] header' }
                # Duplicate section headers are almost always a merge mistake.
                $sections = @(Select-String -InputObject $content -Pattern '(?m)^\s*\[([^\]]+)\]' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value.Trim() })
                $dupes = @($sections | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
                if ($dupes.Count -gt 0) { $warnings += ('TOML duplicate section(s): ' + ($dupes -join ', ')) }
                if (-not $hasSection) { $warnings += 'TOML-like structure (no [section] header found)' }
            }
            return @{ Passed = $true; Errors = @(); Warnings = @($warnings) }
        }
        if ($ext -in @('.yml','.yaml')) {
            $raw = Get-Content -Path $Path -Raw -Encoding UTF8 -EA Stop
            # L5: YAML sanity checks (previously readability-only). Fail-open
            # with warnings: tabs are illegal in YAML indentation, and a file
            # with no 'key:' mapping is unlikely to be a valid manifest.
            $warnings = @()
            if ($raw -match '(?m)^\t+') { $warnings += 'YAML uses tab indentation (spaces required)' }
            if ($raw -match '(?m)^\s*-\s*$') { $warnings += 'YAML has empty list item' }
            if ($raw -notmatch '(?m)^\s*[A-Za-z0-9_\-".]+\s*:') { $warnings += 'YAML has no key: mapping; verify file content' }
            return @{ Passed = $true; Errors = @(); Warnings = @($warnings) }
        }
        if ($name -eq 'dockerfile') {
            $lines = Get-Content -Path $Path -EA Stop
            $hasFrom = $false
            foreach ($line in $lines) { if ($line -match '^\s*FROM\s+\S+') { $hasFrom = $true; break } }
            if (-not $hasFrom) { return @{ Passed = $false; Errors = @('Dockerfile missing FROM'); Warnings = @() } }
            return @{ Passed = $true; Errors = @(); Warnings = @() }
        }
        if ($name -eq 'cmakelists.txt') {
            $lines = Get-Content -Path $Path -EA Stop
            $hasProject = $false
            foreach ($line in $lines) { if ($line -match '^\s*project\s*\(') { $hasProject = $true; break } }
            if (-not $hasProject) { return @{ Passed = $false; Errors = @('CMakeLists.txt missing project()'); Warnings = @() } }
            return @{ Passed = $true; Errors = @(); Warnings = @() }
        }
        if ($ext -in @('.gradle','.kts') -or $name -in @('gemfile', 'rakefile', 'vagrantfile', 'fastfile', 'appfile')) {
            $null = Get-Content -Path $Path -Raw -Encoding UTF8 -EA Stop
            return @{ Passed = $true; Errors = @(); Warnings = @() }
        }
        return @{ Passed = $true; Errors = @(); Warnings = @("Unchecked manifest type: $name") }
    } catch {
        return @{ Passed = $false; Errors = @("Manifest parse failed: $_"); Warnings = @() }
    }
}

<#
.SYNOPSIS
    Checks that required CLI tools are available on PATH.
#>
function Test-ToolsAvailable {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string[]]$Tools = @(),
        [PSCustomObject]$State
    )
    if ($Tools.Count -eq 0) {
        $Tools = if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            @(Get-BuildConstant -Key 'DefaultRequiredTools' -Fallback @('dotnet', 'git'))
        } else { @('dotnet', 'git') }
    }
    $missing = @()
    foreach ($t in $Tools) {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $missing += $t }
    }
    if ($missing.Count -gt 0) {
        return @{ Passed = $false; Errors = @("Missing tools: $($missing -join ', ')"); Warnings = @() }
    }
    return @{ Passed = $true; Errors = @(); Warnings = @() }
}

<#
.SYNOPSIS
    Runs pre-build validation checks (syntax, manifests, tools, disk, network, plugin).
.DESCRIPTION
    Manifest parsing is delegated to Test-ProjectManifest (XML projects,
    JSON incl. generated lockfiles, TOML incl. pyproject.toml/go.mod, YAML,
    Dockerfile, CMakeLists.txt, Gradle, Gemfile).
#>
function Invoke-PreflightValidation {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = ''
    )
    $cfg = Get-ConfigSection -State $State -Path 'build'
    $preflightCfg = Get-SectionValue -Section $cfg -Key 'preflight' -Default $null

    $results = @{ Passed = $true; Errors = @(); Warnings = @(); Checks = @() }

    $checkSyntaxValue = Get-SectionValue -Section $preflightCfg -Key 'checkSyntax' -Default $null
    $checkManifestValue = Get-SectionValue -Section $preflightCfg -Key 'checkManifest' -Default $null
    # Routed through the constant so build.preflight.checkTools resolves via the
    # same config path as every other setting (it was read from the raw
    # sub-tree while PreflightCheckTools sat declared-but-unused).
    $checkToolsValue = Get-BuildConstant -Key 'PreflightCheckTools' -State $State -Fallback $null
    $requiredToolsValue = Get-SectionValue -Section $preflightCfg -Key 'requiredTools' -Default $null
    $checkDiskValue = Get-SectionValue -Section $preflightCfg -Key 'checkDiskSpace' -Default $null
    $checkNetworkValue = Get-SectionValue -Section $preflightCfg -Key 'checkNetwork' -Default $null
    $checkAllManifestsValue = Get-SectionValue -Section $preflightCfg -Key 'checkAllManifests' -Default $null
    $preflightEnabledValue = Get-SectionValue -Section $preflightCfg -Key 'enabled' -Default $null
    $checkSyntax = if ($null -ne $checkSyntaxValue) { [bool]$checkSyntaxValue } else { $true }
    $checkManifest = if ($null -ne $checkManifestValue) { [bool]$checkManifestValue } else { $true }
    $checkToolsEnabled = if ($null -ne $checkToolsValue) { [bool]$checkToolsValue } else { $true }
    $requiredTools = if ($null -ne $requiredToolsValue) { @($requiredToolsValue) } else { @() }
    $checkDisk = if ($null -ne $checkDiskValue) { [bool]$checkDiskValue } else { $true }
    $checkNetwork = if ($null -ne $checkNetworkValue) { [bool]$checkNetworkValue } else { $false }
    $checkAllManifests = if ($null -ne $checkAllManifestsValue) { [bool]$checkAllManifestsValue } else { $true }
    $preflightEnabled = if ($null -ne $preflightEnabledValue) { [bool]$preflightEnabledValue } else { $true }
    if (-not $preflightEnabled) {
        $results.Checks += @{ Name = 'Preflight'; Passed = $true; Skipped = $true }
        return $results
    }

    # 0. Toolchain hermeticity (advisory, never fails the build). Records whether
    # the container image is digest-pinned and the vendored tools match the
    # pinned constants, so drift (analyzer vendored 1.22.0 vs pinned 1.25.0) is
    # visible in preflight output instead of silent. Promotion to a blocking
    # gate is a deliberate future decision, not a side effect: this entry is
    # informational, like the ModuleGraph validator-failure fallback below.
    try {
        $hermToolRoot = Split-Path -Parent $PSScriptRoot
        $herm = Test-ToolchainHermetic -ToolRoot $hermToolRoot
        $results.Checks += @{ Name = 'ToolchainHermetic'; Passed = $true; Advisory = $true; Details = $herm }
        if (-not $herm.Hermetic) { foreach ($why in @($herm.Reasons)) { $results.Warnings += [string]$why } }
    } catch { }

    # 1. Universal syntax check (PowerShell + C#/F#/VB + XML + JSON + TOML + YAML + Docker + CMake)
    if ($checkSyntax) {
        $synResult = @{ Passed = $true; Errors = @(); Warnings = @(); FilesChecked = 0 }
        if (Get-Command Invoke-UniversalSyntaxCheck -ErrorAction SilentlyContinue) {
            $synResult = Invoke-UniversalSyntaxCheck -Root $ProjectDir -Recurse
        } elseif (Get-Command Invoke-SyntaxCheck -ErrorAction SilentlyContinue) {
            $synResult = Invoke-SyntaxCheck -Root $ProjectDir -Recurse
        }
        $results.Checks += @{ Name = 'Syntax'; Passed = $synResult.FilesWithErrors -eq 0; Details = $synResult }
        if ($synResult.FilesWithErrors -gt 0) {
            $results.Passed = $false
            $results.Errors += "$($synResult.FilesWithErrors) file(s) with syntax errors"
            $results.Errors += $synResult.Errors
        }
    }

    $langResult = $null
    # 2. Manifest validation
    if ($checkManifest) {
        $manChecks = @()
        if ($ProjectFile -and (Get-Command Get-PrimaryLanguage -ErrorAction SilentlyContinue)) {
            $langResult = Get-PrimaryLanguage -SearchRoot $ProjectDir -State $State
        }
        $manifests = @()
        if ($checkAllManifests) {
            $priority = @('*.csproj','*.fsproj','*.vbproj','package.json','pyproject.toml','setup.py','Cargo.toml','go.mod','pom.xml','build.gradle','Gemfile','composer.json','Dockerfile','CMakeLists.txt','*.sln','*.axaml','Package.swift','mix.exs','makefile','build.sbt','rakefile','vagrantfile','fastfile','appfile')
            # Embedded tool copy (_Build) must never satisfy a
            # manifest lookup: e.g. _Build/Dockerfile would mask a missing project
            # Dockerfile. Single source: dir list via SharedUtils.Get-SyntaxCheckExcludeDirs
            # (BuildConstants is the only literal), regex via PathUtils.Get-ExcludeDirPattern.
            $exDirs = Get-SyntaxCheckExcludeDirs
            $manifestDepth = [int](Get-ConfigValue -Path 'build.searchMaxDepth' -State $State -Default 3)
            $manifestFiles = @()
            if (Get-Command Get-BoundedProjectFiles -ErrorAction SilentlyContinue) {
                $manifestFiles = @(Get-BoundedProjectFiles -Root $ProjectDir -Filters $priority -Depth $manifestDepth -ExcludeDirs $exDirs -File)
            } else {
                foreach ($pattern in $priority) {
                    $found = Get-ChildItem -Path $ProjectDir -Filter $pattern -File -Recurse -EA SilentlyContinue |
                        Where-Object { $_.FullName.Substring($ProjectDir.Length).Replace('\','/') -notmatch ('[\\/](' + ((@($exDirs) | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')[\\/]') } |
                        Select-Object -First 1
                    if ($found) { $manifestFiles += $found }
                }
            }
            $manifests = @($manifestFiles | Sort-Object FullName -Unique | ForEach-Object { $_.FullName })
            # A manifest is a file the toolchain can BUILD from. The scan list
            # above also carried '*.axaml' (an Avalonia XAML view) and could
            # pick up a tsconfig.json, and Test-ProjectManifest then reported
            # "not a valid manifest" for a file that was never a manifest in
            # the first place - a false preflight error on every Avalonia
            # project. The language map is the single source for "is this a
            # build file", so ask it instead of re-deciding per file name.
            # The non-language markers (makefile, rakefile, ...) are kept:
            # they are build inputs even though no language map claims them.
            $extraManifestLeaves = @('makefile', 'rakefile', 'vagrantfile', 'fastfile', 'appfile')
            $filtered = @()
            foreach ($mf in $manifests) {
                $keep = $true
                if (Get-Command Test-LanguageBuildFile -ErrorAction SilentlyContinue) {
                    try { $keep = [bool](Test-LanguageBuildFile -FilePath $mf -State $State) } catch { $keep = $true }
                }
                if (-not $keep) {
                    $leaf = ''
                    try { $leaf = [System.IO.Path]::GetFileName($mf).ToLowerInvariant() } catch { $leaf = '' }
                    if ($extraManifestLeaves -notcontains $leaf) { continue }
                }
                $filtered += $mf
            }
            $manifests = @($filtered)
        }
        if ($manifests.Count -eq 0 -and $ProjectFile) { $manifests += $ProjectFile }
        foreach ($m in $manifests) {
            $mr = Test-ProjectManifest -Path $m -State $State
            $manChecks += @{ File = $m; Passed = $mr.Passed; Errors = $mr.Errors; Warnings = $mr.Warnings }
            if (-not $mr.Passed) { $results.Passed = $false; $results.Errors += $mr.Errors }
            $results.Warnings += $mr.Warnings
        }
        if ($manChecks.Count -gt 0) {
            $passed = ($manChecks | Where-Object { -not $_.Passed } | Measure-Object | Select-Object -ExpandProperty Count) -eq 0
            $results.Checks += @{ Name = 'Manifest'; Passed = $passed; Details = $manChecks }
        }
    }

    # 3. Required tools
    if ($checkToolsEnabled -and $requiredTools.Count -gt 0) {
        $toolResult = Test-ToolsAvailable -Tools $requiredTools -State $State
        $results.Checks += @{ Name = 'Tools'; Passed = $toolResult.Passed; Details = $toolResult }
        if (-not $toolResult.Passed) {
            $results.Passed = $false
            $results.Errors += $toolResult.Errors
        }
        $results.Warnings += $toolResult.Warnings
    }

    # 4. Disk space (cross-platform: Windows via Get-PSDrive, POSIX via DriveInfo)
    if ($checkDisk) {
        $minMBValue = Get-SectionValue -Section $preflightCfg -Key 'minDiskSpaceMB' -Default $null
        $minMB = if ($null -ne $minMBValue) { [int]$minMBValue } else { Get-BuildConstant -Key 'MinDiskMB' -State $State -Fallback 2048 }
        $osPlatform = if ($State -and $State.OS) { $State.OS } elseif (Get-Command Get-OSPlatform -ErrorAction SilentlyContinue) { Get-OSPlatform } else {
            Get-CanonicalOSName
        }
        $freeMB = $null
        if ($osPlatform -eq 'Windows') {
            # $ProjectDir may be relative (e.g. '..\_Build') or otherwise lack a
            # drive qualifier; resolve to an absolute path before Split-Path,
            # otherwise Split-Path -Qualifier throws FormatException.
            # No literal drive default: on a machine whose project lives on D: (or
            # a Windows container without C:), defaulting to 'C:' measured the
            # WRONG volume - or, with no C: drive at all, silently skipped the
            # disk gate while reporting green. Derive from the project dir; when
            # that fails, skip the check explicitly (freeMB stays $null) instead
            # of measuring an unrelated volume.
            $drive = ''
            try {
                $absProjectDir = if ([System.IO.Path]::IsPathRooted($ProjectDir)) {
                    $ProjectDir
                } else {
                    [System.IO.Path]::GetFullPath((Join-Path ((Get-Location).ProviderPath) $ProjectDir))
                }
                $qual = Split-Path -Qualifier $absProjectDir -ErrorAction SilentlyContinue
                if ($qual) { $drive = $qual }
            } catch { $drive = '' }
            if ($drive) {
                $disk = Get-PSDrive -Name $drive.TrimEnd(':') -EA SilentlyContinue
                if ($disk) { $freeMB = [math]::Round($disk.Free / 1MB, 0) }
            }
        } else {
            # Linux/macOS: no drive letter (C:) — use System.IO.DriveInfo
            # (pwsh on POSIX is always .NET Core, so DriveInfo is available).
            try {
                $rooted = if ([System.IO.Path]::IsPathRooted($ProjectDir)) { $ProjectDir } else { Join-Path ((Get-Location).ProviderPath) $ProjectDir }
                $di = [System.IO.DriveInfo]::new([System.IO.Path]::GetFullPath($rooted))
                if ($di.IsReady) { $freeMB = [math]::Round($di.AvailableFreeSpace / 1MB, 0) }
            } catch { $freeMB = $null } # undeterminable — skip the check, never fail the build
        }
        if ($null -ne $freeMB) {
            $ok = $freeMB -ge $minMB
            $results.Checks += @{ Name = 'Disk'; Passed = $ok; Details = @{ FreeMB = $freeMB; MinMB = $minMB; Platform = $osPlatform } }
            if (-not $ok) {
                $results.Passed = $false
                $results.Errors += "Insufficient disk space: ${freeMB}MB free, ${minMB}MB required"
            }
        }
    }

# 5. Network/endpoints.
    # The old condition checked cmdlet EXISTENCE (`$null -eq (Get-Command
    # Test-CIEnvironment)`), so once EnvironmentProvider was loaded (the normal
    # case) this whole block was skipped even when checkNetwork=true. The intent
    # is to SKIP network probes in CI - test the RESULT, not the existence:
    $isCI = $false
    if ($checkNetwork) {
        if (Get-Command Test-CIEnvironment -ErrorAction SilentlyContinue) {
            try { $isCI = [bool](Test-CIEnvironment) } catch { $isCI = $false }
        } elseif (Get-Command Test-BuildCIHost -ErrorAction SilentlyContinue) {
            # Standalone import (no provider): SharedUtils.Test-BuildCIHost is the
            # owner of the raw $env: probe. The inline copy this replaced checked
            # only GITHUB_ACTIONS/$env:CI, so Azure DevOps and GitLab - where CI
            # may be unset - were reported as local and the network probe ran.
            try { $isCI = [bool](Test-BuildCIHost) } catch { $isCI = $false }
        }
    }
    if ($checkNetwork -and -not $isCI) {
        $endpoints = @()
        $configuredEndpoints = Get-SectionValue -Section $preflightCfg -Key 'endpoints' -Default $null
        if ($configuredEndpoints) { $endpoints = @($configuredEndpoints) }
        if ($endpoints.Count -eq 0) {
            $healthEndpoints = Get-ConfigValue -Path 'health.endpoints' -State $State
            if ($healthEndpoints) { $endpoints = @($healthEndpoints) }
        }
        foreach ($ep in $endpoints) {
            $url = if ($ep -is [string]) { $ep } else { $configuredUrl = Get-SectionValue -Section $ep -Key 'URL' -Default $null; if ($null -eq $configuredUrl) { $configuredUrl = Get-SectionValue -Section $ep -Key 'url' -Default $null }; $configuredUrl }
            if (-not $url) { continue }
            try {
                $resp = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec (Get-BuildConstant -Key 'PreflightNetTimeoutSec' -Fallback 5) -UseBasicParsing -EA Stop
                $results.Checks += @{ Name = "Network:$url"; Passed = $true; Details = @{ Status = $resp.StatusCode } }
            } catch {
                $results.Checks += @{ Name = "Network:$url"; Passed = $false; Details = @{ Error = $_.Exception.Message } }
                $results.Passed = $false
                $results.Errors += "Endpoint unreachable: $url"
            }
        }
    }

    # 6. Plugin-specific preflight
    if ($langResult) {
        $pf = Invoke-PreflightForLanguage -Language $langResult.Language -ProjectDir $ProjectDir -ProjectFile $ProjectFile -State $State
        $results.Checks += @{ Name = "Plugin:$($langResult.Language)"; Passed = $pf.Passed; Details = $pf }
        if (-not $pf.Passed) {
            $results.Passed = $false
            $results.Errors += $pf.Errors
        }
        $results.Warnings += $pf.Warnings
    }

    # 7. Module dependency graph.
    #
    # This module (Modules/ModuleDependencies.psm1) is the platform's OWN validator
    # for missing dependencies and import cycles - and until now it only ever ran
    # under `gbuild -SelfTest`, i.e. never during a build. A missing dependency or a
    # cycle is exactly the defect class that costs a developer an afternoon: the
    # build fails deep inside a plugin, with no indication that the module graph
    # itself is at fault. Preflight is where that belongs.
    # -State $State is LOAD-BEARING. Get-BuildConstant falls back to $global:GState
    # when no State is passed, so an omitted -State reads a DIFFERENT config than
    # the one this preflight run was given: the check then ignores the caller's
    # build.preflight.checkModuleGraph entirely and cannot be turned off. Two
    # existing call sites here (PreflightCheckTools, MinDiskMB) pass -State.
    if (Get-BuildConstant -Key 'PreflightCheckModuleGraph' -State $State -Fallback $true) {
        # Loaded ON DEMAND, not added to the Tier-1 eager list. ModuleDependencies
        # deliberately stays lazy (ModuleDependencies.Tests.ps1 asserts it), and the
        # eager list is the wrong place for a validator that only some flows need.
        $modulesRoot = if ($State -and $State.PSObject.Properties.Name -contains 'ModulesRoot' -and $State.ModulesRoot) {
            [string]$State.ModulesRoot
        } else {
            Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules'
        }
        if (-not (Get-Command Test-ModuleDependencies -ErrorAction SilentlyContinue)) {
            $depModule = Join-Path $modulesRoot 'ModuleDependencies.psm1'
            if (Test-Path -LiteralPath $depModule -PathType Leaf) {
                try { $null = Import-Module $depModule -Force -Global -DisableNameChecking -ErrorAction Stop } catch { }
            }
        }
        if (Get-Command Test-ModuleDependencies -ErrorAction SilentlyContinue) {
            if (Test-Path -LiteralPath $modulesRoot -PathType Container) {
                try {
                    $graph = Test-ModuleDependencies -ModulesRoot $modulesRoot
                    $details = @{
                        Modules   = $graph.ModuleCount
                        Missing   = @($graph.Missing)
                        Cycles    = @($graph.Cycles)
                        Summary   = $graph.Summary
                    }
                    $results.Checks += @{ Name = 'ModuleGraph'; Passed = [bool]$graph.Passed; Details = $details }
                    if (-not $graph.Passed) {
                        $results.Passed = $false
                        foreach ($m in @($graph.Missing)) { $results.Errors += "Module $($m.Module) requires missing dependency '$($m.MissingDep)'" }
                        foreach ($c in @($graph.Cycles)) { $results.Errors += "Module import cycle: $($c -join ' -> ')" }
                    }
                } catch {
                    # A validator that cannot run is a warning, never a build
                    # failure: the graph check must not be able to break a build
                    # that the validator itself is broken.
                    $results.Checks += @{ Name = 'ModuleGraph'; Passed = $true; Details = @{ Skipped = $_.Exception.Message } }
                    $results.Warnings += "Module dependency graph could not be validated: $($_.Exception.Message)"
                }
            } else {
                $results.Warnings += "Module graph check skipped: no Modules directory at $modulesRoot"
            }
        } else {
            $results.Warnings += 'Module graph check skipped: Modules/ModuleDependencies.psm1 is not loaded.'
        }
    }

    return $results
}

<#
.SYNOPSIS
    Verifies the toolchain is hermetic: image digest-pinned, tools vendored.
.DESCRIPTION
    Reads the tool-root Dockerfile (FROM must carry @sha256:) and checks the
    vendored PSScriptAnalyzer directory matches BuildConstants
    ScriptAnalyzerVersion. Pure file reads, never throws: every problem is a
    Reasons entry and Hermetic=$false. PS 5.1-safe.
#>
function Test-ToolchainHermetic {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([string]$ToolRoot)
    if ([string]::IsNullOrWhiteSpace($ToolRoot)) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
    $reasons = [System.Collections.Generic.List[string]]::new()
    $dockerPinned = $false
    $vendoredOk = $false
    $dockerfile = Join-Path $ToolRoot 'Dockerfile'
    if (Test-Path -LiteralPath $dockerfile -PathType Leaf) {
        try {
            $text = [System.IO.File]::ReadAllText($dockerfile)
            if ([regex]::Match($text, '(?m)^\s*FROM\s+\S+@sha256:[0-9a-fA-F]{32,}\s*$').Success) { $dockerPinned = $true }
            else { $reasons.Add('Dockerfile FROM is not digest-pinned') | Out-Null }
        } catch { $reasons.Add('Dockerfile is unreadable') | Out-Null }
    } else { $reasons.Add('Dockerfile not found under the tool root') | Out-Null }
    $want = ''
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $want = [string](Get-BuildConstant -Key 'ScriptAnalyzerVersion' -Fallback '') } catch { $want = '' }
    }
    if ([string]::IsNullOrWhiteSpace($want)) { $reasons.Add('ScriptAnalyzerVersion is unresolvable') | Out-Null }
    else {
        $vendored = Join-Path (Join-Path (Join-Path $ToolRoot '.tools') 'Modules') 'PSScriptAnalyzer'
        if (Test-Path -LiteralPath (Join-Path $vendored $want) -PathType Container) { $vendoredOk = $true }
        else { $reasons.Add(('vendored PSScriptAnalyzer ' + $want + ' is not installed')) | Out-Null }
    }
    return [PSCustomObject]@{ Hermetic = ($dockerPinned -and $vendoredOk); DockerfilePinned = $dockerPinned; VendoredToolsOk = $vendoredOk; Reasons = @($reasons) }
}

Export-ModuleMember -Function @('Invoke-PreflightValidation', 'Test-ProjectManifest', 'Test-ToolchainHermetic')




