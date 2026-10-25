# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$null = Import-Module (Join-Path $PSScriptRoot 'helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

Set-PluginMetadata @{
    Name = 'Rust'
    SupportedLanguages = @('Rust')
    Priority = 4
    ToolName = 'cargo'
    ManifestFiles = @('Cargo.toml')
    BuildCommand = 'cargo build'
    TestCommand = 'cargo test'
    LintCommand = 'cargo clippy -- -D warnings'
    CleanCommand = 'cargo clean'
    RunCommand = 'cargo run'
    SoftFailLint = $true
}

$script:CustomBuild = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)

Set-StrictMode -Version 1.0
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('Cargo.toml')
    if (-not $manifest) { $r = New-PluginActionResult -Status Failed -Operation 'rust.build' -ReasonCode 'ManifestMissing' -Message 'Cargo.toml was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'cargo')) { $r = New-PluginActionResult -Status Failed -Operation 'rust.build' -ReasonCode 'ToolMissing' -Message 'cargo is not available'; if ($Detailed) { return $r }; return $false }
    $targetDir = New-PluginOutputDirectory -State $State -ProjectDir $ProjectDir -Subdirectory 'rust'
    $args = @('build', '--target-dir', $targetDir)
    if ($Configuration -eq 'Release') { $args += '--release' }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($cargoArgs) & cargo @cargoArgs } -State $State -ProjectDir $ProjectDir -ArgumentList @($args) -Label 'Running cargo build...'
    if ($Detailed) { if ($result.Succeeded) { $result | Add-Member -MemberType NoteProperty -Name OutputPath -Value $targetDir -Force }; return $result }
    return [bool]$result.Succeeded
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    $errors = @(); $warnings = @()
    if (-not (Test-ToolAvailable -ToolName 'cargo')) { $errors += 'Missing tool: cargo' }
    if (-not (Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('Cargo.toml'))) { $errors += 'Missing manifest: Cargo.toml' }
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
