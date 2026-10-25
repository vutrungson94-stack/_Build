# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$helperPath = Join-Path $PSScriptRoot 'helpers/DotnetHelpers.psm1'
if (Test-Path -LiteralPath $helperPath) { $null = Import-Module $helperPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue }

Set-PluginMetadata @{
    Name = 'Avalonia'
    SupportedLanguages = @('Avalonia', 'LinuxDesktop')
    Priority = 10
    ToolName = 'dotnet'
    ManifestFiles = @('*.csproj')
    BuildCommand = 'dotnet publish'
    TestCommand = 'dotnet test'
    LintCommand = 'dotnet format'
    CleanCommand = 'dotnet clean'
    RunCommand = 'dotnet run'
}

function Test-AvaloniaProject {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$CsprojPath)

Set-StrictMode -Version 1.0
    if (-not $CsprojPath -or -not (Test-Path -LiteralPath $CsprojPath -PathType Leaf)) { return $false }
    try {
        $content = Get-Content -LiteralPath $CsprojPath -Raw -Encoding UTF8 -ErrorAction Stop
        return ($content -match '(?i)Avalonia\.Framework|PackageReference[^>]*Include\s*=\s*["'']Avalonia')
    } catch { return $false }
}

$script:CustomBuild = {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Incremental,
        [switch]$Detailed
    )
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $project = Resolve-DotnetProjectFile -ProjectFile $ProjectFile -ProjectDir $ProjectDir -Filters @('*.csproj')
    if (-not $project -or -not (Test-AvaloniaProject -CsprojPath $project.FullName)) {
        $result = New-PluginActionResult -Status Failed -Operation 'avalonia.build' -ReasonCode 'ProjectMissing' -Message 'Avalonia .csproj was not found'
        if ($Detailed) { return $result }
        return $false
    }
    $frontend = Invoke-NpmBuildIfPresent -State $State -ProjectDir $ProjectDir -ProjectFile $project.FullName -Detailed:$Detailed
    if ($frontend -is [PSCustomObject] -and $frontend.PSObject.Properties.Name -contains 'Status' -and $frontend.Status -eq 'Failed') { if ($Detailed) { return $frontend }; return $false }
    $dotnet = if ($State -and ($State.PSObject.Properties.Name -contains 'DotnetCmd') -and $State.DotnetCmd) { [string]$State.DotnetCmd } else { 'dotnet' }
    if (-not (Test-ToolAvailable -ToolName $dotnet)) {
        $result = New-PluginActionResult -Status Failed -Operation 'avalonia.build' -ReasonCode 'ToolMissing' -Message "$dotnet is not available"
        if ($Detailed) { return $result }
        return $false
    }
    # Was: `{ 'linux-x64' }` as the fallback. On Windows or macOS without
    # Environment loaded that made a self-contained publish target a LINUX
    # runtime, producing an unrunnable artifact. Fall back through the config
    # key, then the declared build target, then a host-derived default.
    $rid = ''
    if (Get-Command Get-RuntimeIdentifier -ErrorAction SilentlyContinue) { $rid = [string](Get-RuntimeIdentifier) }
    if (-not $rid -and (Get-Command Get-DeployDefaultRid -ErrorAction SilentlyContinue)) { $rid = [string](Get-DeployDefaultRid -State ) }
    if (-not $rid) { $rid = 'win-x64' }
    $output = New-PluginOutputDirectory -State $State -ProjectDir $ProjectDir -Subdirectory 'avalonia'
    $result = Invoke-PluginCommandResult -ScriptBlock { param($dotnetPath, $projectPath, $configuration, $runtime, $outputPath, $incremental) $args = @('publish', $projectPath, '--configuration', $configuration, '--runtime', $runtime, '--self-contained', 'true', '--output', $outputPath); if ($incremental) { $args += '--no-restore' }; & $dotnetPath @args } -State $State -ProjectDir $ProjectDir -ArgumentList @($dotnet, $project.FullName, $Configuration, $rid, $output, [bool]$Incremental) -Label "Publishing Avalonia ($rid)..."
    if ($Detailed) {
        if ($result.Succeeded) { $result | Add-Member -MemberType NoteProperty -Name OutputPath -Value $output -Force }
        return $result
    }
    return [bool]$result.Succeeded
}

$script:CustomTest = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $result = Invoke-DotnetTest -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -PluginLabel 'Avalonia' -Detailed:$Detailed
    if ($Detailed) { return $result }
    return [bool]$result
}

$script:CustomLint = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $result = Invoke-DotnetLint -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -PluginLabel 'Avalonia' -Detailed:$Detailed
    if ($Detailed) { return $result }
    return [bool]$result
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    return Get-DotnetPreflightResult -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -ManifestFilters @('*.csproj')
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
