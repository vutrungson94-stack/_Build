# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$null = Import-Module (Join-Path $PSScriptRoot 'helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

Set-PluginMetadata @{
    Name = 'PHP'
    SupportedLanguages = @('PHP')
    Priority = 2
    ToolName = 'composer'
    SecondaryToolNames = @('php')
    ManifestFiles = @('composer.json')
    BuildCommand = 'composer validate'
    TestCommand = 'phpunit'
    LintCommand = 'phpcs'
    CleanCommand = 'composer dump-autoload --optimize'
    RunCommand = 'composer run serve'
    MissingToolLevel = 'Warn'
}

function Get-VendorBinary {
    param([Parameter(Mandatory)][string]$ProjectDir, [Parameter(Mandatory)][ValidateSet('phpunit', 'phpcs')][string]$Name, [PSCustomObject]$State)

Set-StrictMode -Version 1.0
    # NOT $isWindows: read-only automatic variable since PowerShell 6.0. The
    # assignment silently no-op'd and left the HOST value in place, so the
    # per-State decision below never took effect.
    $onWindows = $false
    if ($State -and ($State.PSObject.Properties.Name -contains 'OS')) { $onWindows = ([string]$State.OS -eq 'Windows') }
    $leaf = if ($onWindows -and $Name -eq 'phpunit') { 'phpunit.bat' } elseif ($onWindows) { 'phpcs.bat' } else { $Name }
    $path = Join-Path (Join-Path $ProjectDir 'vendor/bin') $leaf
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    $path = Join-Path (Join-Path $ProjectDir 'vendor/bin') $Name
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return ''
}

$script:CustomBuild = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('composer.json')
    if (-not $manifest) { $r = New-PluginActionResult -Status Failed -Operation 'php.build' -ReasonCode 'ManifestMissing' -Message 'composer.json was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'composer')) { $r = New-PluginActionResult -Status Failed -Operation 'php.build' -ReasonCode 'ToolMissing' -Message 'Composer is not available'; if ($Detailed) { return $r }; return $false }
    $vendor = Join-Path $ProjectDir 'vendor'
    if (-not (Test-Path -LiteralPath $vendor -PathType Container)) {
        $allow = $false
        try { if ($State.BuildConfig -and $State.BuildConfig.build -and $State.BuildConfig.build.php -and $State.BuildConfig.build.php.installDependencies) { $allow = [bool]$State.BuildConfig.build.php.installDependencies } } catch { }
        if (-not $allow) { $r = New-PluginActionResult -Status Failed -Operation 'php.build' -ReasonCode 'DependenciesMissing' -Message 'PHP dependencies are not installed; enable build.php.installDependencies to allow Composer install' ; if ($Detailed) { return $r }; return $false }
        $install = Invoke-PluginCommandResult -ScriptBlock { composer install --no-interaction --prefer-dist --no-progress } -State $State -ProjectDir $ProjectDir -Label 'Installing PHP dependencies...'
        if (-not $install.Succeeded) { if ($Detailed) { return $install }; return $false }
    }
    $validate = Invoke-PluginCommandResult -ScriptBlock { composer validate --no-check-publish --no-interaction } -State $State -ProjectDir $ProjectDir -Label 'Validating composer.json...'
    if ($Detailed) { if ($validate.Succeeded) { $validate | Add-Member -MemberType NoteProperty -Name OutputPath -Value (New-PluginOutputDirectory -State $State -ProjectDir $ProjectDir -Subdirectory 'php') -Force }; return $validate }
    return [bool]$validate.Succeeded
}

$script:CustomTest = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('composer.json')
    $config = Test-ConfigFilePresent -ProjectDir $ProjectDir -Patterns @('phpunit.xml', 'phpunit.xml.dist')
    $tests = @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -Filter '*Test.php' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](vendor|node_modules)[\\/]' })
    if (-not $manifest -or -not $config -or $tests.Count -eq 0) { $r = New-PluginActionResult -Status Skipped -Operation 'php.test' -ReasonCode 'NoTests' -Message 'PHPUnit configuration or tests were not found'; if ($Detailed) { return $r }; return $false }
    $binary = Get-VendorBinary -ProjectDir $ProjectDir -Name 'phpunit' -State $State
    if (-not $binary) { $r = New-PluginActionResult -Status Skipped -Operation 'php.test' -ReasonCode 'ToolMissing' -Message 'A local PHPUnit binary was not found'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($tool) & $tool } -State $State -ProjectDir $ProjectDir -ArgumentList @($binary) -Label 'Running PHPUnit...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomLint = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('composer.json')
    $config = Test-ConfigFilePresent -ProjectDir $ProjectDir -Patterns @('phpcs.xml', '.phpcs.xml', 'phpcs.xml.dist')
    if (-not $manifest -or -not $config) { $r = New-PluginActionResult -Status Skipped -Operation 'php.lint' -ReasonCode 'LintConfigurationMissing' -Message 'PHPCS configuration was not found'; if ($Detailed) { return $r }; return $false }
    $binary = Get-VendorBinary -ProjectDir $ProjectDir -Name 'phpcs' -State $State
    if (-not $binary) { $r = New-PluginActionResult -Status Skipped -Operation 'php.lint' -ReasonCode 'ToolMissing' -Message 'A local PHPCS binary was not found'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($tool) & $tool } -State $State -ProjectDir $ProjectDir -ArgumentList @($binary) -Label 'Running PHPCS...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    $errors = @(); $warnings = @()
    if (-not (Test-ToolAvailable -ToolName 'composer')) { $errors += 'Missing tool: composer' }
    if (-not (Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('composer.json'))) { $errors += 'Missing manifest: composer.json' }
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
