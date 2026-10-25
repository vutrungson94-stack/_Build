# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

$pluginHelpersPath = Join-Path $PSScriptRoot 'PluginHelpers.psm1'
if (Test-Path -LiteralPath $pluginHelpersPath) { $null = Import-Module $pluginHelpersPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue }

function Resolve-DotnetCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    # Delegates to SDK.psm1's Resolve-DotnetSdkCommand, which is the single owner
    # of dotnet selection. This function used to return State.DotnetCmd (or the
    # bare name 'dotnet') with no capability check, so on a machine where PATH
    # put a runtime-only muxer first, lint and SAST invoked a dotnet that cannot
    # run SDK commands and failed with misleading errors.
    #
    # Two contracts are preserved deliberately:
    #  1. State.DotnetCmd is sanitised by picking the first STRING element. It can
    #     arrive as a polluted array (upstream output pollution), and casting the
    #     whole array with [string] produced 'True C:\fake\dotnet.exe', which then
    #     crashed Test-ToolAvailable's -ToolName binding.
    #  2. The legacy fallback shape is kept - the preferred path, else the
    #     DotnetToolName constant, else the bare name 'dotnet' - so a caller that
    #     only checks tool availability still behaves as before when SDK.psm1 is
    #     not loaded.
    $preferred = ''
    if ($State -and ($State.PSObject.Properties.Name -contains 'DotnetCmd')) {
        $values = @(@($State.DotnetCmd) | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) })
        if ($values.Count -gt 0) { $preferred = [string]$values[0] }
    }
    if (Get-Command Resolve-DotnetSdkCommand -ErrorAction SilentlyContinue) {
        try {
            $resolved = Resolve-DotnetSdkCommand -State $State -PreferredPath $preferred
            if ($resolved) { return [string]$resolved }
        } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($preferred)) { return $preferred }
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) { return [string](Get-BuildConstant -Key 'DotnetToolName' -Fallback 'dotnet') }
    return 'dotnet'
}

function Get-DotnetManifestFilters {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([switch]$IncludeSolution, [switch]$SolutionOnly)
    $projects = @('*.csproj', '*.fsproj', '*.vbproj')
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $projects = @(Get-BuildConstant -Key 'DotnetProjectFilters' -Fallback $projects) } catch { }
    }
    $solution = '*.sln'
    if ($IncludeSolution -or $SolutionOnly) {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            try { $solution = [string](Get-BuildConstant -Key 'DotnetSolutionFilter' -Fallback $solution) } catch { }
        }
        if ($SolutionOnly) { return @($solution) }
    }
    if (-not $IncludeSolution) { return @($projects | Where-Object { $_ }) }
    return @(@($projects | Where-Object { $_ }) + $solution)
}

function Resolve-DotnetProjectFile {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [string]$ProjectFile = '',
        [Parameter(Mandatory)][string]$ProjectDir,
        [string[]]$Filters = $null
    )
    if ($null -eq $Filters) { $Filters = Get-DotnetManifestFilters }
    $filters = @($Filters | Where-Object { $_ })
    $explicitProvided = -not [string]::IsNullOrWhiteSpace($ProjectFile)
    if ($explicitProvided) {
        if (-not (Test-Path -LiteralPath $ProjectFile -PathType Leaf)) { return $null }
        $leaf = [System.IO.Path]::GetFileName($ProjectFile)
        foreach ($filter in $filters) { if ($leaf -like $filter) { return Get-Item -LiteralPath $ProjectFile } }
        $explicitExt = [System.IO.Path]::GetExtension($ProjectFile)
        foreach ($filter in $filters) {
            $filterExt = [System.IO.Path]::GetExtension($filter)
            if ($explicitExt -and $filterExt -and $explicitExt.Equals($filterExt, [System.StringComparison]::OrdinalIgnoreCase)) { return Get-Item -LiteralPath $ProjectFile }
        }
        return $null
    }
    $skipDirs = @('node_modules', 'bin', 'obj', '.git', 'packages', 'publish-output')
    foreach ($filter in $filters) {
        $found = Get-ChildItem -LiteralPath $ProjectDir -Filter $filter -File -Recurse -Depth 3 -Exclude $skipDirs -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found }
    }
    return $null
}

function Invoke-NpmBuildIfPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$Label = 'WEBUI',
        [string]$ProjectFile = '',
        [switch]$Detailed
    )
    $pkg = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('package.json')
    if (-not $pkg) { if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'dotnet.frontend' -ReasonCode 'ManifestMissing' -Message 'No frontend package.json found' }; return $true }
    $hasBuild = Test-NpmScriptDefined -PackageJsonPath $pkg -ScriptName 'build'
    if (-not $hasBuild) { if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'dotnet.frontend' -ReasonCode 'BuildScriptMissing' -Message 'Frontend has no build script' }; return $true }
    if (-not (Test-ToolAvailable -ToolName 'npm')) { if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'dotnet.frontend' -ReasonCode 'ToolMissing' -Message 'npm is not available' }; return $false }
    $lock = Join-Path $ProjectDir 'package-lock.json'
    $nodeModules = Join-Path $ProjectDir 'node_modules'
    if (-not (Test-Path -LiteralPath $nodeModules) -or (Test-Path -LiteralPath $lock)) {
        $install = if (Test-Path -LiteralPath $lock) { 'ci' } else { 'install' }
        $installResult = Invoke-PluginCommandResult -ScriptBlock ([scriptblock]::Create("npm $install")) -State $State -ProjectDir $ProjectDir -Label "$Label`: npm $install..."
        if (-not $installResult.Succeeded) { if ($Detailed) { return $installResult }; return $false }
    }
    $buildResult = Invoke-PluginCommandResult -ScriptBlock { npm run build } -State $State -ProjectDir $ProjectDir -Label "$Label`: npm run build..."
    if ($Detailed) { return $buildResult }
    return [bool]$buildResult.Succeeded
}

function Invoke-DotnetTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [string]$PluginLabel = '.NET',
        [switch]$Detailed
    )
    $dotnet = Resolve-DotnetCommand -State $State
    if (-not (Test-ToolAvailable -ToolName $dotnet)) {
        $result = New-PluginActionResult -Status Skipped -Operation 'dotnet.test' -ReasonCode 'ToolMissing' -Message "$dotnet is not available" -Details $dotnet
        if ($Detailed) { return $result }
        return $false
    }
    $projects = @()
    if ($ProjectFile -and (Test-Path -LiteralPath $ProjectFile -PathType Leaf) -and ([System.IO.Path]::GetFileName($ProjectFile) -like '*Tests*.csproj')) { $projects = @(Get-Item -LiteralPath $ProjectFile) }
    if ($projects.Count -eq 0 -and $ProjectDir) { $projects = @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -Filter '*Tests*.csproj' -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](bin|obj|\.git|node_modules)[\\/]' }) }
    if ($projects.Count -eq 0) {
        $result = New-PluginActionResult -Status Skipped -Operation 'dotnet.test' -ReasonCode 'NoTests' -Message "No $PluginLabel test projects were found"
        if ($Detailed) { return $result }
        return $false
    }
    # An unset Configuration used to be silently forced to 'Release' here, which
    # both defeated this parameter's "let the tool decide" default and made the
    # tests run against a different configuration than the build produced. It now
    # resolves through Loader.Resolve-PluginDispatchConfiguration, the same
    # profile-aware owner every $script:Custom* path uses via
    # Resolve-PluginConfiguration (a dot-sourced BasePlugin helper is not
    # visible from this module's session state, so this delegates to the
    # module-side owner directly instead of carrying a second copy).
    $cfg = $Configuration
    if ([string]::IsNullOrWhiteSpace($cfg)) {
        if (Get-Command Resolve-PluginDispatchConfiguration -ErrorAction SilentlyContinue) {
            $cfg = [string](Resolve-PluginDispatchConfiguration -State $State -Configuration $cfg)
        } else { $cfg = 'Release' }
    }
    $failures = @()
    foreach ($project in $projects) {
        $result = Invoke-PluginCommandResult -ScriptBlock { param($dotnetPath, $projectPath, $configuration) & $dotnetPath test $projectPath --configuration $configuration --nologo } -State $State -ProjectDir $ProjectDir -ArgumentList @($dotnet, $project.FullName, $cfg) -Label "Running $PluginLabel tests: $($project.Name)"
        if (-not $result.Succeeded) { $failures += $result }
    }
    if ($failures.Count -gt 0) {
        $result = New-PluginActionResult -Status Failed -Operation 'dotnet.test' -ReasonCode 'TestFailed' -Message "$PluginLabel tests failed" -Details $failures
        if ($Detailed) { return $result }
        return $false
    }
    $result = New-PluginActionResult -Status Succeeded -Operation 'dotnet.test' -ReasonCode 'OK' -Message "$PluginLabel tests passed" -Details $projects.FullName
    if ($Detailed) { return $result }
    return $true
}

function Invoke-DotnetLint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [string]$PluginLabel = '.NET',
        [switch]$Detailed
    )
    $dotnet = Resolve-DotnetCommand -State $State
    if (-not (Test-ToolAvailable -ToolName $dotnet)) {
        $result = New-PluginActionResult -Status Skipped -Operation 'dotnet.lint' -ReasonCode 'ToolMissing' -Message "$dotnet is not available" -Details $dotnet
        if ($Detailed) { return $result }
        return $false
    }
    $target = if ($ProjectFile -and (Test-Path -LiteralPath $ProjectFile -PathType Leaf)) { $ProjectFile } else { $ProjectDir }
    $help = Invoke-PluginCommandResult -ScriptBlock { param($dotnetPath) & $dotnetPath format --help } -State $State -ProjectDir $ProjectDir -ArgumentList @($dotnet) -Label "Checking dotnet format for $PluginLabel"
    if (-not $help.Succeeded) {
        $result = New-PluginActionResult -Status Skipped -Operation 'dotnet.lint' -ReasonCode 'FormatUnavailable' -Message 'dotnet format is not available' -Details $help
        if ($Detailed) { return $result }
        return $false
    }
    $lint = Invoke-PluginCommandResult -ScriptBlock { param($dotnetPath, $targetPath) & $dotnetPath format $targetPath --verify-no-changes --no-restore } -State $State -ProjectDir $ProjectDir -ArgumentList @($dotnet, $target) -Label "Running dotnet format for $PluginLabel"
    if ($Detailed) { return $lint }
    return [bool]$lint.Succeeded
}

function Get-DotnetPreflightResult {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [PSCustomObject]$State,
        [string]$ProjectDir,
        [string]$ProjectFile = '',
        [string[]]$ManifestFilters = $null
    )
    if ($null -eq $ManifestFilters) { $ManifestFilters = Get-DotnetManifestFilters -IncludeSolution }
    $errors = @(); $warnings = @()
    $dotnet = Resolve-DotnetCommand -State $State
    if (-not (Test-ToolAvailable -ToolName $dotnet)) { $errors += "Missing tool: $dotnet" }
    $filters = @($ManifestFilters | Where-Object { $_ -and $_ -ne (Get-DotnetManifestFilters -SolutionOnly) })
    if ($filters.Count -eq 0) { $filters = Get-DotnetManifestFilters }
    $found = Resolve-DotnetProjectFile -ProjectFile $ProjectFile -ProjectDir $ProjectDir -Filters $filters
    if (-not $found -and ($ManifestFilters -contains (Get-DotnetManifestFilters -SolutionOnly))) { $found = Resolve-DotnetProjectFile -ProjectFile $ProjectFile -ProjectDir $ProjectDir -Filters (Get-DotnetManifestFilters -SolutionOnly) }
    if (-not $found) { $warnings += "No $($ManifestFilters -join '/') found" }
    return @{ Passed = ($errors.Count -eq 0); Errors = $errors; Warnings = $warnings }
}

Export-ModuleMember -Function @('Get-DotnetManifestFilters', 'Resolve-DotnetProjectFile', 'Invoke-NpmBuildIfPresent', 'Invoke-DotnetTest', 'Invoke-DotnetLint', 'Get-DotnetPreflightResult')
