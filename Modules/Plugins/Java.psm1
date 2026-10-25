# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$null = Import-Module (Join-Path $PSScriptRoot 'helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

Set-PluginMetadata @{
    Name = 'Java'
    SupportedLanguages = @('Java', 'Kotlin', 'Scala')
    Priority = 1
    ToolName = 'java'
    SecondaryToolNames = @('mvn', 'gradle', 'sbt')
    ManifestFiles = @('pom.xml', 'build.gradle', 'build.gradle.kts', 'build.sbt')
    BuildCommand = 'build'
    TestCommand = 'test'
    LintCommand = 'check'
    CleanCommand = ''
    RunCommand = ''
}

function Resolve-JavaBuildTool {
    param([Parameter(Mandatory)][string]$ProjectDir, [Parameter(Mandatory)][string]$ProjectFile, [PSCustomObject]$State)

Set-StrictMode -Version 1.0
    $leaf = [System.IO.Path]::GetFileName($ProjectFile).ToLowerInvariant()
    # NOT $isWindows: read-only automatic variable since PowerShell 6.0, so this
    # assignment silently no-op'd and the HOST value decided the wrapper name.
    $onWindows = $false
    if ($State -and ($State.PSObject.Properties.Name -contains 'OS')) { $onWindows = ([string]$State.OS -eq 'Windows') }
    if ($leaf -eq 'pom.xml') {
        foreach ($name in @('mvnw.cmd', 'mvnw.bat', 'mvnw')) { $path = Join-Path $ProjectDir $name; if (Test-Path -LiteralPath $path -PathType Leaf) { return $path } }
        if (Get-Command mvn -CommandType Application -ErrorAction SilentlyContinue) { return 'mvn' }
        return ''
    }
    if ($leaf -in @('build.gradle', 'build.gradle.kts')) {
        $name = if ($onWindows) { 'gradlew.bat' } else { 'gradlew' }
        $path = Join-Path $ProjectDir $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        if (Get-Command gradle -CommandType Application -ErrorAction SilentlyContinue) { return 'gradle' }
        return ''
    }
    if ($leaf -eq 'build.sbt') {
        foreach ($name in @('sbt.bat', 'sbt.cmd', 'sbt')) { $path = Join-Path $ProjectDir $name; if (Test-Path -LiteralPath $path -PathType Leaf) { return $path } }
        if (Get-Command sbt -CommandType Application -ErrorAction SilentlyContinue) { return 'sbt' }
        return ''
    }
    return ''
}

function Get-JavaManifest {
    param([string]$ProjectDir, [string]$ProjectFile)
    return Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('pom.xml', 'build.gradle', 'build.gradle.kts', 'build.sbt')
}

$script:CustomBuild = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $manifest = Get-JavaManifest -ProjectDir $ProjectDir -ProjectFile $ProjectFile
    if (-not $manifest) { $r = New-PluginActionResult -Status Failed -Operation 'java.build' -ReasonCode 'ManifestMissing' -Message 'No supported Java build manifest was found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'java')) { $r = New-PluginActionResult -Status Failed -Operation 'java.build' -ReasonCode 'ToolMissing' -Message 'Java is not available'; if ($Detailed) { return $r }; return $false }
    $tool = Resolve-JavaBuildTool -ProjectDir $ProjectDir -ProjectFile $manifest -State $State
    if (-not $tool) { $r = New-PluginActionResult -Status Failed -Operation 'java.build' -ReasonCode 'BuildToolMissing' -Message 'No Maven, Gradle, or SBT command/wrapper is available'; if ($Detailed) { return $r }; return $false }
    $leaf = [System.IO.Path]::GetFileName($manifest).ToLowerInvariant()
    $output = New-PluginOutputDirectory -State $State -ProjectDir $ProjectDir -Subdirectory 'java'
    if ($leaf -eq 'pom.xml') {
        $args = @('-f', $manifest, '--batch-mode', "-Dgbuild.configuration=$Configuration", 'package')
        $result = Invoke-PluginCommandResult -ScriptBlock { param($command, $commandArgs) & $command @commandArgs } -State $State -ProjectDir $ProjectDir -ArgumentList @($tool, $args) -Label 'Running Maven package...'
    } elseif ($leaf -eq 'build.sbt') {
        $args = @("-Dconfiguration=$Configuration", 'compile')
        $result = Invoke-PluginCommandResult -ScriptBlock { param($command, $commandArgs) & $command @commandArgs } -State $State -ProjectDir $ProjectDir -ArgumentList @($tool, $args) -Label 'Running SBT compile...'
    } else {
        $args = @("-Pconfiguration=$Configuration", 'build')
        $result = Invoke-PluginCommandResult -ScriptBlock { param($command, $commandArgs) & $command @commandArgs } -State $State -ProjectDir $ProjectDir -ArgumentList @($tool, $args) -Label 'Running Gradle build...'
    }
    if ($Detailed) { if ($result.Succeeded) { $result | Add-Member -MemberType NoteProperty -Name OutputPath -Value $output -Force }; return $result }
    return [bool]$result.Succeeded
}

$script:CustomTest = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Get-JavaManifest -ProjectDir $ProjectDir -ProjectFile $ProjectFile
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'java.test' -ReasonCode 'ManifestMissing' -Message 'No Java build manifest was found'; if ($Detailed) { return $r }; return $false }
    $tool = Resolve-JavaBuildTool -ProjectDir $ProjectDir -ProjectFile $manifest -State $State
    if (-not $tool) { $r = New-PluginActionResult -Status Skipped -Operation 'java.test' -ReasonCode 'BuildToolMissing' -Message 'No selected Java build tool is available'; if ($Detailed) { return $r }; return $false }
    $leaf = [System.IO.Path]::GetFileName($manifest).ToLowerInvariant()
    if ($leaf -eq 'pom.xml') { $args = @('-f', $manifest, '--batch-mode', 'test'); $label = 'Running Maven test...' }
    elseif ($leaf -eq 'build.sbt') { $args = @('test'); $label = 'Running SBT test...' }
    else { $args = @('test'); $label = 'Running Gradle test...' }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($command, $commandArgs) & $command @commandArgs } -State $State -ProjectDir $ProjectDir -ArgumentList @($tool, $args) -Label $label
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomLint = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $manifest = Get-JavaManifest -ProjectDir $ProjectDir -ProjectFile $ProjectFile
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'java.lint' -ReasonCode 'ManifestMissing' -Message 'No Java build manifest was found'; if ($Detailed) { return $r }; return $false }
    $leaf = [System.IO.Path]::GetFileName($manifest).ToLowerInvariant()
    $hasConfig = if ($leaf -eq 'pom.xml') { Test-ConfigFilePresent -ProjectDir $ProjectDir -Patterns @('checkstyle.xml', 'config/checkstyle.xml') } elseif ($leaf -eq 'build.sbt') { Test-ConfigFilePresent -ProjectDir $ProjectDir -Patterns @('scalastyle-config.xml') } else { $true }
    if (-not $hasConfig) { $r = New-PluginActionResult -Status Skipped -Operation 'java.lint' -ReasonCode 'LintConfigurationMissing' -Message 'Java lint configuration was not found'; if ($Detailed) { return $r }; return $false }
    $tool = Resolve-JavaBuildTool -ProjectDir $ProjectDir -ProjectFile $manifest -State $State
    if (-not $tool) { $r = New-PluginActionResult -Status Skipped -Operation 'java.lint' -ReasonCode 'BuildToolMissing' -Message 'No selected Java build tool is available'; if ($Detailed) { return $r }; return $false }
    if ($leaf -eq 'pom.xml') { $args = @('-f', $manifest, '--batch-mode', 'checkstyle:check'); $label = 'Running Maven checkstyle...' }
    elseif ($leaf -eq 'build.sbt') { $args = @('scalastyle'); $label = 'Running SBT scalastyle...' }
    else { $args = @('checkstyleMain'); $label = 'Running Gradle checkstyle...' }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($command, $commandArgs) & $command @commandArgs } -State $State -ProjectDir $ProjectDir -ArgumentList @($tool, $args) -Label $label
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    $errors = @(); $warnings = @()
    if (-not (Test-ToolAvailable -ToolName 'java')) { $errors += 'Missing tool: java' }
    $manifest = Get-JavaManifest -ProjectDir $ProjectDir -ProjectFile $ProjectFile
    if (-not $manifest) { $errors += 'Missing Maven/Gradle/SBT manifest' }
    elseif (-not (Resolve-JavaBuildTool -ProjectDir $ProjectDir -ProjectFile $manifest -State $State)) { $errors += "No build command for $([System.IO.Path]::GetFileName($manifest))" }
    return @{ Passed = ($errors.Count -eq 0); Errors = $errors; Warnings = $warnings }
}

$script:CustomClean = {
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Detailed)
    $manifest = Get-JavaManifest -ProjectDir $ProjectDir -ProjectFile $ProjectFile
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'java.clean' -ReasonCode 'ManifestMissing' -Message 'No Java build manifest was found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'java')) { $r = New-PluginActionResult -Status Skipped -Operation 'java.clean' -ReasonCode 'ToolMissing' -Message 'Java is not available'; if ($Detailed) { return $r }; return $false }
    $tool = Resolve-JavaBuildTool -ProjectDir $ProjectDir -ProjectFile $manifest -State $State
    if (-not $tool) { $r = New-PluginActionResult -Status Skipped -Operation 'java.clean' -ReasonCode 'BuildToolMissing' -Message 'No Maven, Gradle, or SBT command/wrapper is available'; if ($Detailed) { return $r }; return $false }
    $leaf = [System.IO.Path]::GetFileName($manifest).ToLowerInvariant()
    $args = if ($leaf -eq 'pom.xml') { @('-f', $manifest, '--batch-mode', 'clean') } else { @('clean') }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($command, $commandArgs) & $command @commandArgs } -State $State -ProjectDir $ProjectDir -ArgumentList @($tool, $args) -Label 'Running Java clean...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
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
