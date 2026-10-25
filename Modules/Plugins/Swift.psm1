# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$null = Import-Module (Join-Path $PSScriptRoot 'helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

Set-PluginMetadata @{
    Name = 'Swift'
    SupportedLanguages = @('Swift')
    Priority = 5
    ToolName = 'swift'
    ManifestFiles = @('Package.swift')
    BuildCommand = 'swift build'
    TestCommand = 'swift test'
    LintCommand = 'swiftlint'
    CleanCommand = 'swift package clean'
    RunCommand = 'swift run'
    LintToolName = 'swiftlint'
    MissingToolLevel = 'Error'
}

$script:CustomBuild = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)

Set-StrictMode -Version 1.0
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('Package.swift')
    if (-not $manifest) { $r = New-PluginActionResult -Status Failed -Operation 'swift.build' -ReasonCode 'ManifestMissing' -Message 'Package.swift was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'swift')) { $r = New-PluginActionResult -Status Failed -Operation 'swift.build' -ReasonCode 'ToolMissing' -Message 'Swift is not available'; if ($Detailed) { return $r }; return $false }
    $args = @('build')
    if ($Configuration -eq 'Release') { $args += @('-c', 'release') }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($swiftArgs) & swift @swiftArgs } -State $State -ProjectDir $ProjectDir -ArgumentList @($args) -Label 'Running swift build...'
    if ($Detailed) { if ($result.Succeeded) { $result = Publish-PluginArtifacts -Result $result -State $State -ProjectDir $ProjectDir -Subdirectory 'swift' -CandidatePaths @((Join-Path $ProjectDir '.build')) }; return $result }
    return [bool]$result.Succeeded
}

$script:CustomTest = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    if (-not (Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('Package.swift'))) { $r = New-PluginActionResult -Status Skipped -Operation 'swift.test' -ReasonCode 'ManifestMissing' -Message 'Package.swift was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'swift')) { $r = New-PluginActionResult -Status Skipped -Operation 'swift.test' -ReasonCode 'ToolMissing' -Message 'Swift is not available'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { swift test } -State $State -ProjectDir $ProjectDir -Label 'Running swift test...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomLint = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('Package.swift')
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'swift.lint' -ReasonCode 'ManifestMissing' -Message 'Package.swift was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Get-Command swiftlint -CommandType Application -ErrorAction SilentlyContinue)) { $r = New-PluginActionResult -Status Skipped -Operation 'swift.lint' -ReasonCode 'ToolMissing' -Message 'swiftlint is not available'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { swiftlint lint --strict } -State $State -ProjectDir $ProjectDir -Label 'Running swiftlint...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    $errors = @(); $warnings = @()
    if (-not (Test-ToolAvailable -ToolName 'swift')) { $errors += 'Missing tool: swift' }
    if (-not (Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('Package.swift'))) { $errors += 'Missing manifest: Package.swift' }
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
