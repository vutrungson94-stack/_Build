# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$null = Import-Module (Join-Path $PSScriptRoot 'helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

Set-PluginMetadata @{
    Name = 'Node'
    SupportedLanguages = @('Node.js', 'TypeScript')
    Priority = 2
    ToolName = 'npm'
    ManifestFiles = @('package.json')
    BuildCommand = 'npm run build'
    TestCommand = 'npm test'
    LintCommand = 'eslint .'
    CleanCommand = 'npm run clean'
    RunCommand = 'npm start'
    MissingToolLevel = 'Warn'
}

function Get-LocalEslintPath {
    param([Parameter(Mandatory)][string]$ProjectDir)

Set-StrictMode -Version 1.0
    $root = Join-Path $ProjectDir 'node_modules/.bin'
    foreach ($name in @('eslint.cmd', 'eslint.bat', 'eslint')) {
        $candidate = Join-Path $root $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command eslint -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { if ($command.Source) { return [string]$command.Source }; return [string]$command.Path }
    return ''
}

$script:CustomBuild = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $pkg = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('package.json')
    if (-not $pkg) { $r = New-PluginActionResult -Status Failed -Operation 'node.build' -ReasonCode 'ManifestMissing' -Message 'package.json was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-NpmScriptDefined -PackageJsonPath $pkg -ScriptName 'build')) { $r = New-PluginActionResult -Status Failed -Operation 'node.build' -ReasonCode 'BuildScriptMissing' -Message 'package.json does not define a build script'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'npm')) { $r = New-PluginActionResult -Status Failed -Operation 'node.build' -ReasonCode 'ToolMissing' -Message 'npm is not available'; if ($Detailed) { return $r }; return $false }
    $lock = Join-Path $ProjectDir 'package-lock.json'
    $modules = Join-Path $ProjectDir 'node_modules'
    # Reinstall only when dependencies are absent. Running `npm ci` whenever a
    # lockfile exists needlessly removes/recreates a large dependency tree (AWS
    # SDK on Windows can take >10 minutes) and can leave node_modules incomplete
    # if the build is interrupted. `npm ci` remains available in CI/explicit
    # clean builds; incremental/local builds validate the existing install.
    if (-not (Test-Path -LiteralPath $modules -PathType Container)) {
        $install = if (Test-Path -LiteralPath $lock) { 'ci' } else { 'install' }
        $installResult = Invoke-PluginCommandResult -ScriptBlock ([scriptblock]::Create("npm $install")) -State $State -ProjectDir $ProjectDir -Label "Running npm $install..."
        if (-not $installResult.Succeeded) { if ($Detailed) { return $installResult }; return $false }
    }
    $envValue = if ($Configuration -eq 'Release') { 'production' } else { 'development' }
    $build = Invoke-PluginCommandResult -ScriptBlock { param($mode) Invoke-WithEnv -Name 'NODE_ENV' -Value $mode -ScriptBlock { npm run build } } -State $State -ProjectDir $ProjectDir -ArgumentList @($envValue) -Label 'Running npm run build...'
    if ($Detailed) {
        if ($build.Succeeded) {
            $candidates = @((Join-Path $ProjectDir 'dist'), (Join-Path $ProjectDir 'build'), (Join-Path $ProjectDir 'lib'))
            $build = Publish-PluginArtifacts -Result $build -State $State -ProjectDir $ProjectDir -Subdirectory 'node' -CandidatePaths $candidates
        }
        return $build
    }
    return [bool]$build.Succeeded
}

$script:CustomTest = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $pkg = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('package.json')
    if (-not $pkg) { $r = New-PluginActionResult -Status Skipped -Operation 'node.test' -ReasonCode 'ManifestMissing' -Message 'package.json was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-NpmScriptDefined -PackageJsonPath $pkg -ScriptName 'test')) {
        $status = if (Test-PluginTestRequired -State $State) { 'Failed' } else { 'Skipped' }
        $r = New-PluginActionResult -Status $status -Operation 'node.test' -ReasonCode 'TestScriptMissing' -Message 'package.json does not define a test script'
        if ($Detailed) { return $r }
        return $false
    }
    if (-not (Test-ToolAvailable -ToolName 'npm')) { $r = New-PluginActionResult -Status Skipped -Operation 'node.test' -ReasonCode 'ToolMissing' -Message 'npm is not available'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { npm test } -State $State -ProjectDir $ProjectDir -ArgumentList @($Configuration) -Label 'Running npm test...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomLint = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $pkg = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('package.json')
    if (-not $pkg) { $r = New-PluginActionResult -Status Skipped -Operation 'node.lint' -ReasonCode 'ManifestMissing' -Message 'package.json was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'npm')) { $r = New-PluginActionResult -Status Skipped -Operation 'node.lint' -ReasonCode 'ToolMissing' -Message 'npm is not available'; if ($Detailed) { return $r }; return $false }
    # Prefer the project's lint command so Node-native checks, ESLint, Biome,
    # or another future linter can be used without changing the plugin.
    if (Test-NpmScriptDefined -PackageJsonPath $pkg -ScriptName 'lint') {
        $result = Invoke-PluginCommandResult -ScriptBlock { npm run lint } -State $State -ProjectDir $ProjectDir -Label 'Running npm run lint...'
        if ($Detailed) { return $result }
        return [bool]$result.Succeeded
    }
    # Legacy fallback for projects without a lint script.
    # Shared helper (PluginHelpers.Test-ConfigFilePresent) - also adds the
    # eslint.config.ts / .mts variants this inline probe was missing.
    $hasConfig = Test-ConfigFilePresent -ProjectDir $ProjectDir -Patterns @('.eslintrc*', 'eslint.config.js', 'eslint.config.mjs', 'eslint.config.cjs', 'eslint.config.ts', 'eslint.config.mts')
    if (-not $hasConfig) { $r = New-PluginActionResult -Status Skipped -Operation 'node.lint' -ReasonCode 'LintConfigurationMissing' -Message 'ESLint configuration was not found'; if ($Detailed) { return $r }; return $false }
    $eslint = Get-LocalEslintPath -ProjectDir $ProjectDir
    if (-not $eslint) { $r = New-PluginActionResult -Status Skipped -Operation 'node.lint' -ReasonCode 'ToolMissing' -Message 'A local eslint binary was not found'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($binary) & $binary . } -State $State -ProjectDir $ProjectDir -ArgumentList @($eslint) -Label 'Running local eslint...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    $errors = @(); $warnings = @()
    if (-not (Test-ToolAvailable -ToolName 'npm')) { $errors += 'Missing tool: npm' }
    $pkg = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('package.json')
    if (-not $pkg) { $errors += 'Missing manifest: package.json' }
    return @{ Passed = ($errors.Count -eq 0); Errors = $errors; Warnings = $warnings }
}

# Export list derived from the shared contract instead of a 5th copy of it.
# This literal was byte-identical in all 14 plugins (plus 2 in Loader and 2 in
# the test suite = 18 encodings of one contract). BasePlugin.ps1 is dot-sourced
# at the top of this file and owns the canonical list.
Export-ModuleMember -Function @(
    (Get-BasePluginContractFunctions)
    # Optional lifecycle verbs. Present in every plugin via BasePlugin, so the
    # dispatchers in Loader stay wired even when a plugin has no implementation.
    'Invoke-PluginClean'
    'Invoke-PluginRun'
)
