# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$helperPath = Join-Path $PSScriptRoot 'helpers/DotnetHelpers.psm1'
if (Test-Path -LiteralPath $helperPath) { $null = Import-Module $helperPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue }

Set-PluginMetadata @{
    Name = 'Dotnet'
    SupportedLanguages = if (Get-Command Get-DotnetLanguages -ErrorAction SilentlyContinue) { @(Get-DotnetLanguages) } else { @('C#', 'F#', 'VB.NET') }
    Priority = 1
    ToolName = 'dotnet'
    ManifestFiles = @('*.csproj', '*.fsproj', '*.vbproj')
    BuildCommand = 'dotnet publish'
    TestCommand = 'dotnet test'
    LintCommand = 'dotnet format'
    CleanCommand = 'dotnet clean'
    RunCommand = 'dotnet run'
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

Set-StrictMode -Version 1.0
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $project = Resolve-DotnetProjectFile -ProjectFile $ProjectFile -ProjectDir $ProjectDir
    if (-not $project) {
        $result = New-PluginActionResult -Status Failed -Operation 'dotnet.build' -ReasonCode 'ProjectMissing' -Message 'No .NET project file was found'
        if ($Detailed) { return $result }
        return $false
    }
    $frontend = Invoke-NpmBuildIfPresent -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Detailed:$Detailed
    if ($frontend -is [PSCustomObject] -and $frontend.PSObject.Properties.Name -contains 'Status' -and $frontend.Status -ne 'Succeeded' -and $frontend.Status -ne 'Skipped') { if ($Detailed) { return $frontend }; return $false }
    if ($frontend -is [PSCustomObject] -and $frontend.PSObject.Properties.Name -contains 'Status' -and $frontend.Status -eq 'Failed') { if ($Detailed) { return $frontend }; return $false }
    if (-not (Get-Command Start-BuildAndShow -ErrorAction SilentlyContinue)) {
        $result = New-PluginActionResult -Status Failed -Operation 'dotnet.build' -ReasonCode 'ModuleNotLoaded' -Message 'Build module is not available'
        if ($Detailed) { return $result }
        return $false
    }
    $meta = if (Get-Command Get-ProjectMetadata -ErrorAction SilentlyContinue) { Get-ProjectMetadata -CsprojPath $project.FullName -State $State } else { $null }
    $tfm = if ($meta -and $meta.Tfms -and $meta.Tfms.Count -gt 0) { [string]$meta.Tfms[0] } else { [string](Get-BuildConstant -Key 'DefaultTfm' -Fallback 'net8.0') }
    $type = if ($meta -and $meta.ProjectType) { [string]$meta.ProjectType } else { '' }
    # Optional cross-platform runtime (e.g. osx-x64, osx-arm64, linux-x64). Allows
    # `dotnet publish -r <rid>` for macOS/Linux without a separate target entry.
    $rid = $env:GBUILD_DOTNET_RUNTIME
    if ([string]::IsNullOrWhiteSpace($rid)) { $rid = $env:DOTNET_RUNTIME }
    $buildArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($rid)) {
        $buildArgs += @('-r', $rid, '--self-contained', 'true')
    }
    $result = Start-BuildAndShow -State $State -Project $project.FullName -Tfm $tfm -OutputSubDir 'default' -ProjectType $type -Configuration $Configuration -Incremental:$Incremental -BuildArgs $buildArgs -Detailed:$Detailed
    if ($Detailed) { return $result }
    return [bool]$result
}

$script:CustomTest = {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Incremental,
        [switch]$Detailed
    )
    $result = Invoke-DotnetTest -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -PluginLabel '.NET' -Detailed:$Detailed
    if ($Detailed) { return $result }
    return [bool]$result
}

$script:CustomLint = {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Incremental,
        [switch]$Detailed
    )
    $result = Invoke-DotnetLint -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -PluginLabel '.NET' -Detailed:$Detailed
    if ($Detailed) { return $result }
    return [bool]$result
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    return Get-DotnetPreflightResult -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile
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
