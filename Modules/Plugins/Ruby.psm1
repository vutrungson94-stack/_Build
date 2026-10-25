# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$null = Import-Module (Join-Path $PSScriptRoot 'helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

Set-PluginMetadata @{
    Name = 'Ruby'
    SupportedLanguages = @('Ruby')
    Priority = 2
    ToolName = 'bundle'
    SecondaryToolNames = @('ruby')
    ManifestFiles = @('Gemfile')
    BuildCommand = 'bundle check'
    TestCommand = 'bundle exec rspec'
    LintCommand = 'bundle exec rubocop'
    CleanCommand = 'bundle clean --force'
    RunCommand = 'bundle exec rake'
    LintToolName = 'rubocop'
    MissingToolLevel = 'Gray'
    SoftFailLint = $true
}

function Get-RubyConfig {
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    if ($State -and $State.BuildConfig) { try { if ($State.BuildConfig.build -and $State.BuildConfig.build.ruby) { return $State.BuildConfig.build.ruby } } catch { } }
    return $null
}

$script:CustomBuild = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('Gemfile')
    if (-not $manifest) { $r = New-PluginActionResult -Status Failed -Operation 'ruby.build' -ReasonCode 'ManifestMissing' -Message 'Gemfile was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'bundle')) { $r = New-PluginActionResult -Status Failed -Operation 'ruby.build' -ReasonCode 'ToolMissing' -Message 'Ruby Bundler is not available'; if ($Detailed) { return $r }; return $false }
    $check = Invoke-PluginCommandResult -ScriptBlock { bundle check } -State $State -ProjectDir $ProjectDir -Label 'Checking Ruby dependencies...'
    if (-not $check.Succeeded) {
        $cfg = Get-RubyConfig -State $State
        $allowInstall = $false
        if ($cfg -and $cfg.PSObject.Properties.Name -contains 'installDependencies') { $allowInstall = [bool]$cfg.installDependencies }
        if (-not $allowInstall) { $r = New-PluginActionResult -Status Failed -Operation 'ruby.build' -ReasonCode 'DependenciesMissing' -Message 'Ruby dependencies are not installed; enable build.ruby.installDependencies to allow an explicit install' -Details $check; if ($Detailed) { return $r }; return $false }
        $install = Invoke-PluginCommandResult -ScriptBlock { bundle install --local } -State $State -ProjectDir $ProjectDir -Label 'Installing Ruby dependencies from local cache...'
        if (-not $install.Succeeded) { if ($Detailed) { return $install }; return $false }
    }
    $output = New-PluginOutputDirectory -State $State -ProjectDir $ProjectDir -Subdirectory 'ruby'
    $r = New-PluginActionResult -Status Succeeded -Operation 'ruby.build' -ReasonCode 'OK' -Message 'Ruby dependencies are ready' -Details $manifest -OutputPath $output
    if ($Detailed) { return $r }
    return $true
}

$script:CustomTest = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('Gemfile')
    $specs = @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -Filter '*_spec.rb' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](vendor|tmp)[\\/]' })
    $tests = @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -Filter '*_test.rb' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](vendor|tmp)[\\/]' })
    if (-not $manifest -or ($specs.Count -eq 0 -and $tests.Count -eq 0)) { $r = New-PluginActionResult -Status Skipped -Operation 'ruby.test' -ReasonCode 'NoTests' -Message 'No Ruby test files were found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'bundle')) { $r = New-PluginActionResult -Status Skipped -Operation 'ruby.test' -ReasonCode 'ToolMissing' -Message 'Ruby Bundler is not available'; if ($Detailed) { return $r }; return $false }
    $command = if ($specs.Count -gt 0) { 'bundle exec rspec' } else { 'bundle exec rake test' }
    $result = Invoke-PluginCommandResult -ScriptBlock ([scriptblock]::Create($command)) -State $State -ProjectDir $ProjectDir -Label "Running $command..."
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomLint = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('Gemfile')
    $config = Test-ConfigFilePresent -ProjectDir $ProjectDir -Patterns @('.rubocop.yml', '.rubocop.yaml')
    if (-not $manifest -or -not $config) { $r = New-PluginActionResult -Status Skipped -Operation 'ruby.lint' -ReasonCode 'LintConfigurationMissing' -Message 'Ruby lint configuration was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'bundle')) { $r = New-PluginActionResult -Status Skipped -Operation 'ruby.lint' -ReasonCode 'ToolMissing' -Message 'Ruby Bundler is not available'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { bundle exec rubocop } -State $State -ProjectDir $ProjectDir -Label 'Running RuboCop...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    $errors = @(); $warnings = @()
    if (-not (Test-ToolAvailable -ToolName 'bundle')) { $errors += 'Missing tool: bundle' }
    if (-not (Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('Gemfile'))) { $errors += 'Missing manifest: Gemfile' }
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
