# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$null = Import-Module (Join-Path $PSScriptRoot 'helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

Set-PluginMetadata @{
    Name = 'Go'
    SupportedLanguages = @('Go')
    Priority = 1
    ToolName = 'go'
    ManifestFiles = @('go.mod')
    BuildCommand = 'go build'
    TestCommand = 'go test ./...'
    LintCommand = 'go vet ./...'
    CleanCommand = 'go clean'
    RunCommand = 'go run .'
}

function Get-GoPackageName {
    param([string]$Package, [string]$ProjectDir)

Set-StrictMode -Version 1.0
    $value = $Package.Trim()
    if ($value -eq '.' -or [string]::IsNullOrWhiteSpace($value)) { $value = Split-Path -Leaf $ProjectDir }
    $leaf = Split-Path -Leaf $value
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'package' }
    return ($leaf -replace '[^A-Za-z0-9_.-]', '_')
}

$script:CustomBuild = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('go.mod')
    if (-not $manifest) { $r = New-PluginActionResult -Status Failed -Operation 'go.build' -ReasonCode 'ManifestMissing' -Message 'go.mod was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'go')) { $r = New-PluginActionResult -Status Failed -Operation 'go.build' -ReasonCode 'ToolMissing' -Message 'Go is not available'; if ($Detailed) { return $r }; return $false }
    $list = Invoke-PluginCommandResult -ScriptBlock { go list ./... } -State $State -ProjectDir $ProjectDir -Label 'Resolving Go packages...'
    if (-not $list.Succeeded) { if ($Detailed) { return $list }; return $false }
    $packages = @($list.Details | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($packages.Count -eq 0) { $r = New-PluginActionResult -Status Skipped -Operation 'go.build' -ReasonCode 'NoPackages' -Message 'Go project contains no packages'; if ($Detailed) { return $r }; return $false }
    $outputDir = New-PluginOutputDirectory -State $State -ProjectDir $ProjectDir -Subdirectory 'go'
    # NOT $isWindows: read-only automatic variable since PowerShell 6.0, so this
    # assignment silently no-op'd and the HOST decided the binary suffix.
    $onWindows = $State -and ($State.PSObject.Properties.Name -contains 'OS') -and ([string]$State.OS -eq 'Windows')
    $suffix = if ($onWindows) { '.exe' } else { '' }
    $tags = if ($Configuration -and $Configuration -ne 'Release') { @('-tags', $Configuration.ToLowerInvariant()) } else { @() }
    $failures = @()
    $usedNames = @{}
    foreach ($package in $packages) {
        $baseName = Get-GoPackageName -Package $package -ProjectDir $ProjectDir
        $name = $baseName
        $ordinal = 1
        while ($usedNames.ContainsKey($name)) { $ordinal++; $name = $baseName + '_' + $ordinal.ToString() }
        $usedNames[$name] = $true
        $output = Join-Path $outputDir ($name + $suffix)
        $goArgs = @('build', '-o', $output) + $tags + @($package)
        $result = Invoke-PluginCommandResult -ScriptBlock { param($args) & go @args } -State $State -ProjectDir $ProjectDir -ArgumentList @($goArgs) -Label "Building Go package $package..."
        if (-not $result.Succeeded) { $failures += $result }
    }
    if ($failures.Count -gt 0) { $r = New-PluginActionResult -Status Failed -Operation 'go.build' -ReasonCode 'BuildFailed' -Message 'One or more Go packages failed to build' -Details $failures -OutputPath $outputDir; if ($Detailed) { return $r }; return $false }
    $r = New-PluginActionResult -Status Succeeded -Operation 'go.build' -ReasonCode 'OK' -Message 'Go packages built' -Details $packages -OutputPath $outputDir
    if ($Detailed) { return $r }
    return $true
}

$script:CustomTest = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('go.mod')
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'go.test' -ReasonCode 'ManifestMissing' -Message 'go.mod was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'go')) { $r = New-PluginActionResult -Status Skipped -Operation 'go.test' -ReasonCode 'ToolMissing' -Message 'Go is not available'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { go test ./... } -State $State -ProjectDir $ProjectDir -ArgumentList @($Configuration) -Label 'Running Go tests...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomLint = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('go.mod')
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'go.lint' -ReasonCode 'ManifestMissing' -Message 'go.mod was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'go')) { $r = New-PluginActionResult -Status Skipped -Operation 'go.lint' -ReasonCode 'ToolMissing' -Message 'Go is not available'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { go vet ./... } -State $State -ProjectDir $ProjectDir -ArgumentList @($Configuration) -Label 'Running go vet...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    $errors = @(); $warnings = @()
    if (-not (Test-ToolAvailable -ToolName 'go')) { $errors += 'Missing tool: go' }
    if (-not (Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('go.mod'))) { $errors += 'Missing manifest: go.mod' }
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
