# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


# ========================================================================
# BasePlugin.ps1 — Abstract base for all language plugins (Level 5 DRY)
# ========================================================================
# IMPORTANT: this is a .ps1 precisely because it is DOT-SOURCED by every
# language plugin:
#
#     . (Join-Path $PSScriptRoot 'BasePlugin.ps1')
#
# Dot-sourcing a .psm1 file is a SILENT NO-OP in PowerShell (the dot operator
# only executes .ps1 scripts), which is why the previous BasePlugin.psm1
# arrangement left every plugin without Set-PluginMetadata/Get-PluginInfo and
# broke Register-Plugins with "Set-PluginMetadata is not recognized".
# This file therefore MUST stay a .ps1 and MUST NOT contain
# Export-ModuleMember (illegal outside a module, and it would hijack the
# host plugin's export list when dot-sourced).
#
# Each plugin gets its OWN copy of the metadata + functions in its own module
# session state ($script: scope binds to the host plugin), so per-plugin
# Set-PluginMetadata calls never collide with each other.
#
# Wiring contract (fixed):
#   - Each plugin sets its metadata via Set-PluginMetadata @{...} and MAY
#     define $script:CustomBuild / CustomTest / CustomLint / CustomPreflight
#     scriptblocks for tool-specific logic.
#   - The standard Invoke-PluginBuild/Test/Lint/Preflight wrappers below first
#     look for the host plugin's $script:Custom* override; when absent they
#     fall back to the generic metadata-driven implementation
#     (Invoke-BasePlugin*), so metadata-only plugins still satisfy the full
#     5-function Loader contract (Get-PluginInfo + 4x Invoke-*).
# ========================================================================

# --- Plugin metadata (must be set by derived plugin) ---
$script:PluginMetadata = @{
    Name                = ''          # e.g. 'Go', 'Rust'
    SupportedLanguages  = @()         # e.g. @('go')
    Priority            = 5           # 1..10
    ToolName            = ''          # Primary tool (e.g. 'go')
    FallbackToolNames   = @()         # Alternative tools
    AnyToolNames        = @()         # Any of these tools satisfies
    SecondaryToolNames  = @()         # Recommended but optional tools
    ManifestFiles       = @()         # e.g. @('go.mod')
    BuildCommand        = ''          # e.g. 'go build ./...'
    TestCommand         = ''          # e.g. 'go test ./...'
    LintCommand         = ''          # e.g. 'go vet'
    LintToolName        = ''          # If different from ToolName
    CleanCommand        = ''          # P3 optional: e.g. 'go clean ./...' (empty = no-op $true)
    RunCommand          = ''          # P3 optional: e.g. 'go run .' (empty = $false graceful)
    MissingToolLevel    = 'Warn'      # 'Warn' | 'Error' | 'Gray'
    SoftFailLint        = $false      # Missing lint tool/manifest returns $true
}

function Set-PluginMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Metadata
    )

Set-StrictMode -Version 1.0
    foreach ($k in $Metadata.Keys) {
        if ($script:PluginMetadata.ContainsKey($k)) {
            $script:PluginMetadata[$k] = $Metadata[$k]
        } else {
            Write-PluginLog -Message "BasePlugin: Unknown metadata key '$k'" -Color 'Warn' -State $null
        }
    }
}

function Get-PluginMetadata {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return $script:PluginMetadata.Clone()
}

# --- Internal helpers (StrictMode-safe: never touch an undeclared variable) ---

function Write-PluginLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Color = 'Gray',
        $State = $null
    )
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log $Message $Color $State
    }
}

# Returns the host plugin's $script:<Name> override scriptblock, or $null.
# Get-Variable -Scope Script binds to the HOST plugin's session state (the
# scope this file was dot-sourced into), so overrides never leak across plugins.
function Get-PluginCustomOverride {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )
    $v = Get-Variable -Name $Name -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($v -is [scriptblock]) { return $v }
    return $null
}

# Invokes an override scriptblock with only the parameters it declares, so a
# wrapper can always splat its full $PSBoundParameters without risking
# "parameter cannot be found" when an override declares a subset (e.g. custom
# test blocks taking only -State/-ProjectDir while the wrapper also knows
# -ProjectFile).
function Invoke-PluginCustomOverride {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Override,
        [Parameter(Mandatory)][hashtable]$Arguments
    )
    $declared = @()
    try {
        if ($null -ne $Override.Ast -and $null -ne $Override.Ast.ParamBlock) {
            $declared = @($Override.Ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
        }
    } catch { $declared = @() }
    if ($declared.Count -eq 0) { return & $Override }
    $filtered = @{}
    foreach ($k in $Arguments.Keys) {
        if ($declared -contains $k) { $filtered[$k] = $Arguments[$k] }
    }
    return & $Override @filtered
}

<#
.SYNOPSIS
    Single owner for the plugin build configuration default.
.DESCRIPTION
    Every language plugin resolved an empty -Configuration with the same
    276-character one-liner (Get-BuildConstant 'DefaultConfiguration', fallback
    'Release') - 16 copies, and every one of them SKIPPED the ActiveProfile
    override that Loader.Resolve-PluginDispatchConfiguration applies. Result:
    a profile-scoped configuration was silently ignored on every plugin path
    that went through a $script:Custom* scriptblock.

    This function delegates to Loader's resolver when it is available and
    carries the same logic as its fallback, so the 16 copies collapse to one
    call that honours profiles. It is defined here (not in a module) because
    BasePlugin.ps1 is dot-sourced into every plugin: each plugin gets its own
    copy in its own session state, and a Loader-side helper is not reliably
    visible from a standalone-imported plugin module.
#>
function Resolve-PluginConfiguration {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [PSCustomObject]$State,
        [string]$Configuration = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($Configuration)) { return $Configuration }
    if (Get-Command Resolve-PluginDispatchConfiguration -ErrorAction SilentlyContinue) {
        return [string](Resolve-PluginDispatchConfiguration -State $State -Configuration $Configuration)
    }
    # Standalone fallback (Loader not loaded). Mirrors
    # Loader.Resolve-PluginDispatchConfiguration: constant first, then the
    # active profile's configuration, then 'Release'. A bare constant read
    # here would reintroduce the exact ActiveProfile bug this function exists
    # to kill, so the profile arm is not optional.
    $resolved = 'Release'
    try {
        if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
            $resolved = [string](Get-BuildConstant -Key 'DefaultConfiguration' -State $State -Fallback 'Release')
        }
    } catch { $resolved = 'Release' }
    try {
        if ($State -and $State.PSObject.Properties.Name -contains 'ActiveProfile' -and $State.ActiveProfile -and $State.BuildConfig -and $State.BuildConfig.profiles) {
            $profile = $State.BuildConfig.profiles.($State.ActiveProfile)
            if ($profile -and $profile.PSObject.Properties.Name -contains 'configuration' -and $profile.configuration) {
                $resolved = [string]$profile.configuration
            }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = 'Release' }
    return $resolved
}

function ConvertTo-BasePluginResult {
    [CmdletBinding()]
    param([AllowNull()][object]$Value, [string]$Operation = 'plugin.action')
    if (Get-Command ConvertTo-PluginActionResult -ErrorAction SilentlyContinue) {
        return ConvertTo-PluginActionResult -Value $Value -Operation $Operation
    }
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    return $Value
}

function ConvertTo-BasePluginBoolean {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Value, [string]$Operation = 'plugin.action')
    if (Get-Command ConvertTo-PluginBoolean -ErrorAction SilentlyContinue) { return (ConvertTo-PluginBoolean -Value $Value -Operation $Operation) }
    return [bool]$Value
}

# --- Generic metadata-driven implementations (fallback when no override) ---
#
# LIVENESS LEDGER (do not "clean up" these as dead code without re-verifying):
#   - Invoke-BasePluginTest / Invoke-BasePluginLint -> LIVE via Rust.psm1, the
#     only plugin without $script:CustomTest/CustomLint. Removing them breaks
#     `cargo test` / `cargo clippy` dispatch.
#   - Invoke-BasePluginBuild / Get-BasePluginPreflight -> no in-tree caller today
#     (all 14 plugins override CustomBuild/CustomPreflight), but they are the
#     documented extension path for third-party plugins and are pinned by
#     Tests/PluginHelpers.Tests.ps1. Delete only together with the metadata
#     fields no plugin consumes (CleanCommand/RunCommand) and the tests above.

function Invoke-BasePluginBuild {
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
    $meta = Get-PluginMetadata
    if ([string]::IsNullOrWhiteSpace($meta.BuildCommand)) {
        if ($Detailed) { return New-PluginActionResult -Status Failed -Operation 'plugin.build' -ReasonCode 'NoImplementation' -Message 'Build command is not implemented' }
        return $false
    }
    if (-not (Get-Command Resolve-PluginBuild -ErrorAction SilentlyContinue) -or -not (Get-Command Invoke-PluginCommandResult -ErrorAction SilentlyContinue)) {
        if ($Detailed) { return New-PluginActionResult -Status Failed -Operation 'plugin.build' -ReasonCode 'HelperUnavailable' -Message 'Plugin build helpers are unavailable' }
        return $false
    }
    $manifest = Resolve-PluginBuild -ToolName $meta.ToolName -ToolNotFoundMsg ("{0} not found in PATH" -f $meta.ToolName) -ManifestFiles $meta.ManifestFiles -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile
    if (-not $manifest) {
        if ($Detailed) { return New-PluginActionResult -Status Failed -Operation 'plugin.build' -ReasonCode 'BuildPrerequisiteMissing' -Message 'Required tool or manifest is missing' }
        return $false
    }
    $label = "Running {0}..." -f $meta.BuildCommand
    $sb = [scriptblock]::Create($meta.BuildCommand)
    $result = Invoke-PluginCommandResult -ScriptBlock $sb -State $State -ProjectDir $ProjectDir -ArgumentList @($manifest, $Configuration) -Label $label
    if ($Detailed) { return $result }
    return (ConvertTo-BasePluginBoolean -Value $result -Operation 'plugin.build')
}

function Invoke-BasePluginTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Incremental,
        [switch]$Detailed
    )
    $meta = Get-PluginMetadata
    if ([string]::IsNullOrWhiteSpace($meta.TestCommand)) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.test' -ReasonCode 'NoImplementation' -Message 'Test command is not implemented' }
        return $false
    }
    if (-not (Get-Command Invoke-SimplePluginTest -ErrorAction SilentlyContinue)) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.test' -ReasonCode 'HelperUnavailable' -Message 'Test helper is unavailable' }
        return $false
    }
    return Invoke-SimplePluginTest -ToolName $meta.ToolName -ToolNotFoundMsg ("{0} not found in PATH" -f $meta.ToolName) -ManifestFiles $meta.ManifestFiles -TestCommand $meta.TestCommand -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Detailed:$Detailed
}

function Invoke-BasePluginLint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Incremental,
        [switch]$Detailed
    )
    $meta = Get-PluginMetadata
    if ([string]::IsNullOrWhiteSpace($meta.LintCommand)) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.lint' -ReasonCode 'NoImplementation' -Message 'Lint command is not implemented' }
        return $false
    }
    if (-not (Get-Command Invoke-SimplePluginLint -ErrorAction SilentlyContinue)) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.lint' -ReasonCode 'HelperUnavailable' -Message 'Lint helper is unavailable' }
        return $false
    }
    $lintTool = if ($meta.LintToolName) { $meta.LintToolName } else { $meta.ToolName }
    return Invoke-SimplePluginLint -ToolName $meta.ToolName -LintToolName $lintTool -ToolNotFoundMsg ("{0} not found in PATH" -f $meta.ToolName) -ManifestFiles $meta.ManifestFiles -LintCommand $meta.LintCommand -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -MissingToolLevel $meta.MissingToolLevel -SoftFail:$meta.SoftFailLint -Detailed:$Detailed
}

function Get-BasePluginPreflight {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = ''
    )
    $meta = Get-PluginMetadata
    if (-not (Get-Command Get-SimplePluginPreflight -ErrorAction SilentlyContinue)) {
        return @{ Passed = $true; Errors = @(); Warnings = @('Preflight helper unavailable; skipped'); Skipped = $true }
    }
    $label = if ($meta.ManifestFiles.Count -gt 0) { $meta.ManifestFiles[0] } else { 'manifest' }
    return Get-SimplePluginPreflight -ToolName $meta.ToolName -FallbackToolNames $meta.FallbackToolNames -AnyToolNames $meta.AnyToolNames -SecondaryToolNames $meta.SecondaryToolNames -ManifestFiles $meta.ManifestFiles -ManifestLabel $label -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile
}

# --- P3 optional Clean/Run (backward-compat: absent = safe default) ---
function Invoke-BasePluginClean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Detailed
    )
    $meta = Get-PluginMetadata
    if ([string]::IsNullOrWhiteSpace($meta.CleanCommand)) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.clean' -ReasonCode 'NoImplementation' -Message 'Clean command is not implemented' }
        return $false
    }
    if (-not (Get-Command Invoke-SimplePluginClean -ErrorAction SilentlyContinue)) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.clean' -ReasonCode 'HelperUnavailable' -Message 'Clean helper is unavailable' }
        return $false
    }
    return Invoke-SimplePluginClean -ToolName $meta.ToolName -ToolNotFoundMsg ("{0} not found in PATH" -f $meta.ToolName) -ManifestFiles $meta.ManifestFiles -CleanCommand $meta.CleanCommand -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Detailed:$Detailed
}
function Invoke-BasePluginRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [string]$Arguments = '',
        [switch]$Detailed
    )
    $meta = Get-PluginMetadata
    if ([string]::IsNullOrWhiteSpace($meta.RunCommand)) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.run' -ReasonCode 'NoImplementation' -Message 'Run command is not implemented' }
        return $false
    }
    if (-not (Get-Command Invoke-SimplePluginRun -ErrorAction SilentlyContinue)) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.run' -ReasonCode 'HelperUnavailable' -Message 'Run helper is unavailable' }
        return $false
    }
    return Invoke-SimplePluginRun -ToolName $meta.ToolName -ToolNotFoundMsg ("{0} not found in PATH" -f $meta.ToolName) -ManifestFiles $meta.ManifestFiles -RunCommand $meta.RunCommand -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Arguments $Arguments -Detailed:$Detailed
}

# --- Standard Get-PluginInfo implementation ---
# Returns the full metadata portfolio (not just the 3 routing fields) so
# registry consumers, the PluginSDK manifest merge and metadata tests can
# inspect ToolName/BuildCommand/... without reaching into module internals.
# The Loader contract only requires Name/SupportedLanguages/Priority; extra
# properties are backward compatible.
function Get-PluginInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $meta = Get-PluginMetadata
    return [PSCustomObject]@{
        Name                = $meta.Name
        SupportedLanguages  = $meta.SupportedLanguages
        Priority            = $meta.Priority
        ToolName            = $meta.ToolName
        FallbackToolNames   = $meta.FallbackToolNames
        AnyToolNames        = $meta.AnyToolNames
        SecondaryToolNames  = $meta.SecondaryToolNames
        ManifestFiles       = $meta.ManifestFiles
        BuildCommand        = $meta.BuildCommand
        TestCommand         = $meta.TestCommand
        LintCommand         = $meta.LintCommand
        LintToolName        = $meta.LintToolName
        Capabilities        = @('build', 'test', 'lint', 'preflight', 'clean', 'run')
    }
}

# --- Standard contract wrappers: override first, generic fallback second ---
# Signatures intentionally match the Loader contract: Invoke-PluginBuild/Test/
# Lint accept -ProjectDir and -State (verified by Test-PluginInterface), and
# the extra build/preflight parameters mirror Loader's call sites.

function Invoke-PluginBuild {
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
    $override = Get-PluginCustomOverride -Name 'CustomBuild'
    if ($null -ne $override) {
        # The resolved value must be injected explicitly: $PSBoundParameters only
        # carries Configuration when the caller actually passed it, so a bare
        # splat would leave the override on its own (empty) parameter default.
        $arguments = @{}
        foreach ($key in $PSBoundParameters.Keys) { $arguments[$key] = $PSBoundParameters[$key] }
        $arguments['Configuration'] = $Configuration
        $raw = Invoke-PluginCustomOverride -Override $override -Arguments $arguments
        if ($Detailed) { return (ConvertTo-BasePluginResult -Value $raw -Operation 'plugin.build') }
        return (ConvertTo-BasePluginBoolean -Value $raw -Operation 'plugin.build')
    }
    return Invoke-BasePluginBuild -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Incremental:$Incremental -Detailed:$Detailed
}

function Invoke-PluginTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Incremental,
        [switch]$Detailed
    )
    $override = Get-PluginCustomOverride -Name 'CustomTest'
    if ($null -ne $override) {
        $raw = Invoke-PluginCustomOverride -Override $override -Arguments $PSBoundParameters
        if ($Detailed) { return (ConvertTo-BasePluginResult -Value $raw -Operation 'plugin.test') }
        return (ConvertTo-BasePluginBoolean -Value $raw -Operation 'plugin.test')
    }
    return Invoke-BasePluginTest -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Incremental:$Incremental -Detailed:$Detailed
}

function Invoke-PluginLint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Incremental,
        [switch]$Detailed
    )
    $override = Get-PluginCustomOverride -Name 'CustomLint'
    if ($null -ne $override) {
        $raw = Invoke-PluginCustomOverride -Override $override -Arguments $PSBoundParameters
        if ($Detailed) { return (ConvertTo-BasePluginResult -Value $raw -Operation 'plugin.lint') }
        return (ConvertTo-BasePluginBoolean -Value $raw -Operation 'plugin.lint')
    }
    return Invoke-BasePluginLint -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Incremental:$Incremental -Detailed:$Detailed
}

function Invoke-PluginPreflight {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = ''
    )
    $override = Get-PluginCustomOverride -Name 'CustomPreflight'
    if ($null -ne $override) {
        return Invoke-PluginCustomOverride -Override $override -Arguments $PSBoundParameters
    }
    return Get-BasePluginPreflight -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile
}

# P3: optional Clean/Run wrappers — override via $script:CustomClean/CustomRun,
# else metadata-driven. Missing command = graceful default (clean $true, run $false).
function Invoke-PluginClean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Detailed
    )
    $override = Get-PluginCustomOverride -Name 'CustomClean'
    if ($null -ne $override) {
        $raw = Invoke-PluginCustomOverride -Override $override -Arguments $PSBoundParameters
        if ($Detailed) { return (ConvertTo-BasePluginResult -Value $raw -Operation 'plugin.clean') }
        return (ConvertTo-BasePluginBoolean -Value $raw -Operation 'plugin.clean')
    }
    return Invoke-BasePluginClean -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Detailed:$Detailed
}
<#
.SYNOPSIS
    The canonical 5-function plugin contract, in export order.
.DESCRIPTION
    SINGLE SOURCE for the contract. This list was previously encoded 18 times:
    once here, once as a literal fallback in Loader, once more in
    Loader's signature check, once in each of the 14 plugins' Export-ModuleMember
    (all byte-identical), and twice in the test suite. A contract change
    therefore required up to 18 edits and any single missed one silently broke
    plugin loading. Plugins now derive their export list from this function.
#>
function Get-BasePluginContractFunctions {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @('Get-PluginInfo', 'Invoke-PluginBuild', 'Invoke-PluginTest', 'Invoke-PluginLint', 'Invoke-PluginPreflight')
}

function Invoke-PluginRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [string]$Arguments = '',
        [switch]$Detailed
    )
    $override = Get-PluginCustomOverride -Name 'CustomRun'
    if ($null -ne $override) {
        $raw = Invoke-PluginCustomOverride -Override $override -Arguments $PSBoundParameters
        if ($Detailed) { return (ConvertTo-BasePluginResult -Value $raw -Operation 'plugin.run') }
        return (ConvertTo-BasePluginBoolean -Value $raw -Operation 'plugin.run')
    }
    return Invoke-BasePluginRun -State $State -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Configuration $Configuration -Arguments $Arguments -Detailed:$Detailed
}
