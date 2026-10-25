# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$null = Import-Module (Join-Path $PSScriptRoot 'helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

Set-PluginMetadata @{
    Name = 'Elixir'
    SupportedLanguages = @('Elixir')
    Priority = 5
    ToolName = 'mix'
    ManifestFiles = @('mix.exs')
    BuildCommand = 'mix compile'
    TestCommand = 'mix test'
    LintCommand = 'mix format --check-formatted'
    CleanCommand = 'mix clean'
    RunCommand = 'mix run'
    SoftFailLint = $true
}

function Invoke-ElixirDepsCheck {
    param([PSCustomObject]$State, [string]$ProjectDir, [switch]$Detailed)

Set-StrictMode -Version 1.0
    $manifest = Resolve-PluginManifest -ProjectDir $ProjectDir -ManifestFiles @('mix.exs')
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'elixir.deps' -ReasonCode 'ManifestMissing' -Message 'mix.exs was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'mix')) { $r = New-PluginActionResult -Status Skipped -Operation 'elixir.deps' -ReasonCode 'ToolMissing' -Message 'mix is not available'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { mix deps } -State $State -ProjectDir $ProjectDir -Label 'Checking Elixir dependencies...'
    $text = @($result.Details) -join ' '
    if (-not $result.Succeeded -or $text -match '(?i)not available|out of date|missing') {
        $r = New-PluginActionResult -Status Failed -Operation 'elixir.deps' -ReasonCode 'DependenciesMissing' -Message 'Elixir dependencies are missing or out of date; run mix deps.get explicitly' -Details $result
        if ($Detailed) { return $r }
        return $false
    }
    if ($Detailed) { return $result }
    return $true
}

$script:CustomBuild = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('mix.exs')
    if (-not $manifest) { $r = New-PluginActionResult -Status Failed -Operation 'elixir.build' -ReasonCode 'ManifestMissing' -Message 'mix.exs was not found'; if ($Detailed) { return $r }; return $false }
    $deps = Invoke-ElixirDepsCheck -State $State -ProjectDir $ProjectDir -Detailed:$Detailed
    if (($deps -is [PSCustomObject]) -and $deps.PSObject.Properties.Name -contains 'Status' -and $deps.Status -eq 'Failed') { if ($Detailed) { return $deps }; return $false }
    if (-not $manifest) { return $false }
    $mixEnv = if ($Configuration -eq 'Release') { 'prod' } else { 'dev' }
    $output = New-PluginOutputDirectory -State $State -ProjectDir $ProjectDir -Subdirectory 'elixir'
    $result = Invoke-PluginCommandResult -ScriptBlock { param($envValue) Invoke-WithEnv -Name 'MIX_ENV' -Value $envValue -ScriptBlock { mix compile } } -State $State -ProjectDir $ProjectDir -ArgumentList @($mixEnv) -Label 'Running mix compile...'
    if ($Detailed) { if ($result.Succeeded) { $result = Publish-PluginArtifacts -Result $result -State $State -ProjectDir $ProjectDir -Subdirectory 'elixir' -CandidatePaths @((Join-Path $ProjectDir "_build/$mixEnv")) }; return $result }
    return [bool]$result.Succeeded
}

$script:CustomTest = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('mix.exs')
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'elixir.test' -ReasonCode 'ManifestMissing' -Message 'mix.exs was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'mix')) { $r = New-PluginActionResult -Status Skipped -Operation 'elixir.test' -ReasonCode 'ToolMissing' -Message 'mix is not available'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { mix test } -State $State -ProjectDir $ProjectDir -Label 'Running mix test...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomLint = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('mix.exs')
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'elixir.lint' -ReasonCode 'ManifestMissing' -Message 'mix.exs was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'mix')) { $r = New-PluginActionResult -Status Skipped -Operation 'elixir.lint' -ReasonCode 'ToolMissing' -Message 'mix is not available'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { mix format --check-formatted } -State $State -ProjectDir $ProjectDir -Label 'Running mix format check...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    $errors = @(); $warnings = @()
    if (-not (Test-ToolAvailable -ToolName 'mix')) { $errors += 'Missing tool: mix' }
    if (-not (Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('mix.exs'))) { $errors += 'Missing manifest: mix.exs' }
    if ($errors.Count -eq 0) { $deps = Invoke-ElixirDepsCheck -State $State -ProjectDir $ProjectDir; if (-not $deps) { $errors += 'Elixir dependencies are not ready' } }
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
