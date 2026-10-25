# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$null = Import-Module (Join-Path $PSScriptRoot 'helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

Set-PluginMetadata @{
    Name = 'Docker'
    SupportedLanguages = @('Docker')
    Priority = 1
    ToolName = 'docker'
    ManifestFiles = @('Dockerfile')
    BuildCommand = 'docker build'
    LintCommand = 'docker compose config'
    CleanCommand = 'docker compose down --rmi local'
    RunCommand = 'docker compose up'
}

function Get-DockerBuildConfig {
    param([PSCustomObject]$State)

Set-StrictMode -Version 1.0
    if ($State -and $State.BuildConfig) { try { if ($State.BuildConfig.ci -and $State.BuildConfig.ci.docker) { return $State.BuildConfig.ci.docker } } catch { } }
    return $null
}

function Resolve-DockerConfigValue {
    param([string]$Value)
    if (-not $Value) { return '' }
    if (Get-Command Resolve-EnvPlaceholder -ErrorAction SilentlyContinue) { return [string](Resolve-EnvPlaceholder -Text $Value) }
    return $Value
}

function Get-ComposeManifest {
    param([string]$ProjectDir, [string]$ProjectFile = '')
    return Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('compose.yaml', 'compose.yml', 'docker-compose.yml', 'docker-compose.yaml')
}

function Test-DockerPushEnabled {
    param([object]$Config)
    if (-not $Config) { return $false }
    foreach ($name in @('push', 'autoPush', 'pushEnabled')) {
        $value = Get-PluginObjectValue -Object $Config -Name $name -Default $null
        if ($null -ne $value) { return [bool]$value }
    }
    return $false
}

$script:CustomBuild = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $cfg = Get-DockerBuildConfig -State $State
    $enabled = $true
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'enabled') { $enabled = [bool]$cfg.enabled }
    if (-not $enabled) { $r = New-PluginActionResult -Status Skipped -Operation 'docker.build' -ReasonCode 'Disabled' -Message 'Docker builds are disabled by ci.docker.enabled=false'; if ($Detailed) { return $r }; return $false }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('Dockerfile')
    if (-not $manifest) { $r = New-PluginActionResult -Status Failed -Operation 'docker.build' -ReasonCode 'ManifestMissing' -Message 'Dockerfile was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'docker')) { $r = New-PluginActionResult -Status Failed -Operation 'docker.build' -ReasonCode 'ToolMissing' -Message 'Docker is not available'; if ($Detailed) { return $r }; return $false }
    # A Docker repository name must be lowercase: the daemon rejects
    # "repository name must be lowercase" for any uppercase character. The leaf
    # directory is whatever the developer called the folder, so
    # `gbuild -Project C:\Src\MyApp` produced `-t MyApp` and failed on EVERY
    # platform - the tag, not the host, was the problem. Lowercasing here is
    # also what makes the tag a valid cache key for BuildConstants' hash
    # helpers, which lowercase their input.
    $image = (Split-Path -Leaf $ProjectDir).ToLowerInvariant()
    if (-not $image) { $image = 'gbuild-app' }
    $args = @('build', '-t', $image, '--build-arg', "CONFIGURATION=$Configuration")
    if (-not $Incremental) { $args += '--no-cache' }
    $platform = [string](Get-PluginObjectValue -Object $cfg -Name 'platform' -Default '')
    if ($platform) { $args += @('--platform', $platform) }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($dockerArgs) & docker @dockerArgs } -State $State -ProjectDir $ProjectDir -ArgumentList @($args) -Label "Building Docker image $image..."
    if (-not $result.Succeeded) { if ($Detailed) { return $result }; return $false }
    if (Test-DockerPushEnabled -Config $cfg) {
        $owner = Resolve-DockerConfigValue ([string](Get-PluginObjectValue -Object $cfg -Name 'ghcrOwner' -Default ''))
        $prefix = Resolve-DockerConfigValue ([string](Get-PluginObjectValue -Object $cfg -Name 'imagePrefix' -Default ''))
        $ownerResolved = $owner -and $owner -notmatch '\$\{env:'
        $prefixResolved = (-not $prefix) -or $prefix -notmatch '\$\{env:'
        if ($ownerResolved -and $prefixResolved) {
            $ref = if ($prefix) { "$prefix/$image:latest" } else { "ghcr.io/$owner/$image`:latest" }
            $push = Invoke-PluginCommandResult -ScriptBlock { param($source, $target) & docker tag $source $target; & docker push $target } -State $State -ProjectDir $ProjectDir -ArgumentList @($image, $ref) -Label "Pushing $ref..."
            if (-not $push.Succeeded) { if ($Detailed) { return $push }; return $false }
            $result.Details = $ref
        }
    }
    if ($Detailed) { $result | Add-Member -MemberType NoteProperty -Name OutputPath -Value (New-PluginOutputDirectory -State $State -ProjectDir $ProjectDir -Subdirectory 'docker') -Force; return $result }
    return $true
}

$script:CustomTest = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $compose = Get-ComposeManifest -ProjectDir $ProjectDir -ProjectFile $ProjectFile
    if (-not $compose) { $r = New-PluginActionResult -Status Skipped -Operation 'docker.test' -ReasonCode 'ComposeMissing' -Message 'compose.yaml was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'docker')) { $r = New-PluginActionResult -Status Skipped -Operation 'docker.test' -ReasonCode 'ToolMissing' -Message 'Docker is not available'; if ($Detailed) { return $r }; return $false }
    $hasTest = (Get-Content -LiteralPath $compose -Raw -ErrorAction SilentlyContinue) -match '(?im)^\s*test\s*:'
    if (-not $hasTest) { $r = New-PluginActionResult -Status Skipped -Operation 'docker.test' -ReasonCode 'TestServiceMissing' -Message 'Compose file does not define a test service'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($file) & docker compose -f $file up --exit-code-from test --abort-on-container-exit } -State $State -ProjectDir $ProjectDir -ArgumentList @($compose) -Label 'Running Docker compose tests...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomLint = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $compose = Get-ComposeManifest -ProjectDir $ProjectDir -ProjectFile $ProjectFile
    if (-not $compose) { $r = New-PluginActionResult -Status Skipped -Operation 'docker.lint' -ReasonCode 'ComposeMissing' -Message 'compose.yaml was not found'; if ($Detailed) { return $r }; return $false }
    if (-not (Test-ToolAvailable -ToolName 'docker')) { $r = New-PluginActionResult -Status Skipped -Operation 'docker.lint' -ReasonCode 'ToolMissing' -Message 'Docker is not available'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($file) & docker compose -f $file config --quiet } -State $State -ProjectDir $ProjectDir -ArgumentList @($compose) -Label 'Validating Docker compose file...'
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    $errors = @(); $warnings = @(); $cfg = Get-DockerBuildConfig -State $State
    $enabled = $true
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'enabled') { $enabled = [bool]$cfg.enabled }
    if (-not $enabled) { return @{ Passed = $true; Errors = @(); Warnings = @('Docker build disabled by configuration'); Skipped = $true } }
    if (-not (Test-ToolAvailable -ToolName 'docker')) { $errors += 'Missing tool: docker' }
    if (-not (Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('Dockerfile'))) { $errors += 'Missing manifest: Dockerfile' }
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
