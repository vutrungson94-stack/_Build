# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================


# ========================================================================
# PluginHelpers.psm1 — Shared helpers for single-tool language plugins
# ========================================================================
# Reduces duplication across Go, Rust, Elixir, Swift (and future plugins)
# by parameterizing the common skeleton: tool check → manifest check → invoke.
# ========================================================================

<#
.SYNOPSIS
    Resolves the build manifest file from ProjectFile or ProjectDir.
.PARAMETER ProjectFile
    Explicit project file path (from pipeline).
.PARAMETER ProjectDir
    Project directory root.
.PARAMETER ManifestFiles
    Ordered list of possible manifest filenames (e.g. @('go.mod')).
.OUTPUTS
    Full path to the resolved manifest, or $null if none found.
#>
function Resolve-PluginManifest {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$ProjectFile = '',
        [string]$ProjectDir,
        [string[]]$ManifestFiles
    )

Set-StrictMode -Version 1.0
    $patterns = @($ManifestFiles | Where-Object { $_ })
    $root = $null
    $scanRoot = $ProjectDir
    if ($ProjectDir) {
        try { $root = [System.IO.Path]::GetFullPath($ProjectDir) } catch { $root = $ProjectDir }
    }
    $allowed = {
        param([string]$Path)
        if (-not $Path) { return $false }
        $leaf = [System.IO.Path]::GetFileName($Path)
        foreach ($pattern in $patterns) {
            if ($leaf -like $pattern) { return $true }
            if ($pattern.Contains('*') -or $pattern.Contains('?')) {
                $patternExt = [System.IO.Path]::GetExtension($pattern)
                $fileExt = [System.IO.Path]::GetExtension($Path)
                if ($patternExt -and $fileExt -and $patternExt.Equals($fileExt, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
        }
        return $false
    }
    if ($ProjectFile -and (Test-Path -LiteralPath $ProjectFile -PathType Leaf) -and (& $allowed $ProjectFile)) {
        $full = $ProjectFile
        try { $full = [System.IO.Path]::GetFullPath($ProjectFile) } catch { }
        if ($root) {
            try {
                $rootWithSeparator = $root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
                # Manifest discovery must not accept a project file from outside
                # the project root. Comparing case-insensitively on a
                # case-sensitive volume let a caller pass /repo/App/App.csproj
                # while the project root was /repo/app, so the guard passed for a
                # different tree. Get-PathComparison is the single source; the
                # fallback keeps this helper importable standalone.
                $cmp = if (Get-Command Get-PathComparison -ErrorAction SilentlyContinue) { Get-PathComparison }
                       elseif (Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) { if (Test-IsWindowsHost) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal } }
                       else { [System.StringComparison]::Ordinal }
                if (-not $full.StartsWith($rootWithSeparator, $cmp)) { $full = $null }
            } catch { $full = $null }
        }
        if ($full) { return $ProjectFile }
    }
    if ($ProjectFile) { return $null }
    if (-not $root) { return $null }
    foreach ($pattern in $patterns) {
        if ($pattern.Contains('*') -or $pattern.Contains('?')) {
            $found = Get-ChildItem -LiteralPath $scanRoot -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return $found.FullName }
        } else {
            $candidate = Join-Path $scanRoot $pattern
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    return $null
}

<#
.SYNOPSIS
    Shared preflight check: tool availability + manifest existence.
.PARAMETER ToolName
    Primary tool name (e.g. 'go', 'cargo').
.PARAMETER ManifestFiles
    Ordered list of manifest filenames.
.PARAMETER ManifestLabel
    Human-readable manifest name for warnings (e.g. 'go.mod').
.PARAMETER State
    Build state object.
.PARAMETER ProjectDir
    Project directory root.
.PARAMETER ProjectFile
    Explicit project file path (optional).
#>
function Get-PluginLocaleText {
    param([string]$Key, [string[]]$MessageArgs = @(), [string]$Fallback)
    # PS5.1-safe + standalone-safe: Locale may not be loaded inside a plugin
    # runspace. Fall back to English text so behaviour never depends on i18n.
    try {
        if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) {
            $t = Get-LocaleMessage -Key $Key -MessageArgs $MessageArgs -Fallback $Fallback
            if ($t -and $t -ne $Key) { return $t }
        }
    } catch { }
    $out = $Fallback
    if ($MessageArgs.Count -gt 0) {
        try { $out = [string]::Format($Fallback, [object[]]$MessageArgs) } catch { $out = $Fallback }
    }
    return $out
}

function Get-SimplePluginPreflight {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [string[]]$FallbackToolNames = @(),
        [string[]]$AnyToolNames = @(),
        [string[]]$SecondaryToolNames = @(),
        [Parameter(Mandatory)][string[]]$ManifestFiles,
        [Parameter(Mandatory)][string]$ManifestLabel,
        [PSCustomObject]$State,
        [string]$ProjectDir,
        [string]$ProjectFile = ''
    )
    $errors = @(); $warnings = @(); $skipped = $false
    $toolOk = Test-ToolAvailable -ToolName $ToolName
    if (-not $toolOk) {
        foreach ($t in $FallbackToolNames) { if (Test-ToolAvailable -ToolName $t) { $toolOk = $true; break } }
    }
    if (-not $toolOk -and $AnyToolNames.Count -gt 0) {
        foreach ($t in $AnyToolNames) { if (Test-ToolAvailable -ToolName $t) { $toolOk = $true; break } }
    }
    if (-not $toolOk) {
        $skipped = $true
        $msg = Get-PluginLocaleText -Key 'log.plugin.missingTool' -MessageArgs @($ToolName) -Fallback ("Missing tool: {0} (graceful - build will skip this plugin, not fail)" -f $ToolName)
        $warnings += $msg
        if ($State) { Write-Log $msg 'Warn' $State }
    }
    if ($SecondaryToolNames.Count -gt 0) {
        $secOk = $false
        foreach ($t in $SecondaryToolNames) { if (Test-ToolAvailable -ToolName $t) { $secOk = $true; break } }
        if (-not $secOk) {
            $secMsg = Get-PluginLocaleText -Key 'log.plugin.recommendedToolMissing' -MessageArgs @(($SecondaryToolNames -join '/')) -Fallback ("Recommended tool not found: {0}" -f ($SecondaryToolNames -join '/'))
            $warnings += $secMsg
            if ($State) { Write-Log $secMsg 'Warn' $State }
        }
    }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles $ManifestFiles
    if (-not $manifest) {
        $skipped = $true
        $noMan = Get-PluginLocaleText -Key 'log.plugin.noManifest' -MessageArgs @($ManifestLabel) -Fallback ("No {0} found" -f $ManifestLabel)
        $warnings += $noMan
        if ($State) { Write-Log $noMan 'Warn' $State }
    }
    return @{ Passed = ($errors.Count -eq 0); Errors = $errors; Warnings = $warnings; Skipped = $skipped }
}

<#
.SYNOPSIS
    Shared test runner: tool check → manifest check → invoke command.
.PARAMETER ToolName
    Tool to check.
.PARAMETER ToolNotFoundMsg
    Log message when tool is missing.
.PARAMETER ManifestFiles
    Manifest filenames to look for.
.PARAMETER TestCommand
    Command string to execute (e.g. 'go test ./...').
.PARAMETER State
    Build state.
.PARAMETER ProjectDir
    Project directory.
#>
function Invoke-SimplePluginTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][string]$ToolNotFoundMsg,
        [Parameter(Mandatory)][string[]]$ManifestFiles,
        [Parameter(Mandatory)][string]$TestCommand,
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Detailed
    )
    if (-not (Test-ToolAvailable -ToolName $ToolName)) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.test' -ReasonCode 'ToolMissing' -Message $ToolNotFoundMsg -Details $ToolName }
        return $false
    }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles $ManifestFiles
    if (-not $manifest) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.test' -ReasonCode 'ManifestMissing' -Message 'Test manifest was not found' -Details $ProjectDir }
        return $false
    }
    $label = "Running $TestCommand..."
    $sb = [scriptblock]::Create($TestCommand)
    $result = Invoke-PluginCommandResult -ScriptBlock $sb -State $State -ProjectDir $ProjectDir -ArgumentList @($manifest, $Configuration) -Label $label
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

<#
.SYNOPSIS
    Shared lint runner: tool check → manifest check → invoke command.
.PARAMETER SoftFail
    When $true, missing tool or manifest returns $true (pass) instead of $false.
#>
function Invoke-SimplePluginLint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [string]$LintToolName = '',
        [Parameter(Mandatory)][string]$ToolNotFoundMsg,
        [Parameter(Mandatory)][string[]]$ManifestFiles,
        [Parameter(Mandatory)][string]$LintCommand,
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [string]$MissingToolLevel = 'Warn',
        [switch]$SoftFail,
        [switch]$Detailed
    )
    $checkName = if ($LintToolName) { $LintToolName } else { $ToolName }
    if (-not (Test-ToolAvailable -ToolName $checkName)) {
        $status = if ($SoftFail) { 'Skipped' } else { 'Failed' }
        $result = New-PluginActionResult -Status $status -Operation 'plugin.lint' -ReasonCode 'ToolMissing' -Message $ToolNotFoundMsg -Details $checkName
        if ($Detailed) { return $result }
        return ([bool]$SoftFail)
    }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles $ManifestFiles
    if (-not $manifest) {
        $status = if ($SoftFail) { 'Skipped' } else { 'Failed' }
        $result = New-PluginActionResult -Status $status -Operation 'plugin.lint' -ReasonCode 'ManifestMissing' -Message 'Lint manifest was not found' -Details $ProjectDir
        if ($Detailed) { return $result }
        return ([bool]$SoftFail)
    }
    $label = "Running $LintCommand..."
    $sb = [scriptblock]::Create($LintCommand)
    $result = Invoke-PluginCommandResult -ScriptBlock $sb -State $State -ProjectDir $ProjectDir -ArgumentList @($manifest, $Configuration) -Label $label
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

<#
.SYNOPSIS
    Shared clean runner: tool check → manifest check → invoke command.
#>
function Invoke-SimplePluginClean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][string]$ToolNotFoundMsg,
        [Parameter(Mandatory)][string[]]$ManifestFiles,
        [Parameter(Mandatory)][string]$CleanCommand,
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [switch]$Detailed
    )
    if (-not (Test-ToolAvailable -ToolName $ToolName)) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.clean' -ReasonCode 'ToolMissing' -Message $ToolNotFoundMsg -Details $ToolName }
        return $false
    }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles $ManifestFiles
    if (-not $manifest) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.clean' -ReasonCode 'ManifestMissing' -Message 'Clean manifest was not found' -Details $ProjectDir }
        return $false
    }
    $label = "Running $CleanCommand..."
    $sb = [scriptblock]::Create($CleanCommand)
    $result = Invoke-PluginCommandResult -ScriptBlock $sb -State $State -ProjectDir $ProjectDir -ArgumentList @($manifest, $Configuration) -Label $label
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

<#
.SYNOPSIS
    Shared run runner: tool check → manifest check → invoke command.
#>
function Invoke-SimplePluginRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][string]$ToolNotFoundMsg,
        [Parameter(Mandatory)][string[]]$ManifestFiles,
        [Parameter(Mandatory)][string]$RunCommand,
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [string]$Arguments = '',
        [switch]$Detailed
    )
    if (-not (Test-ToolAvailable -ToolName $ToolName)) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.run' -ReasonCode 'ToolMissing' -Message $ToolNotFoundMsg -Details $ToolName }
        return $false
    }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles $ManifestFiles
    if (-not $manifest) {
        if ($Detailed) { return New-PluginActionResult -Status Skipped -Operation 'plugin.run' -ReasonCode 'ManifestMissing' -Message 'Run manifest was not found' -Details $ProjectDir }
        return $false
    }
    $commandText = $RunCommand
    if ($Arguments) { $commandText = "$commandText $Arguments" }
    $label = "Running $commandText..."
    $sb = [scriptblock]::Create($commandText)
    $result = Invoke-PluginCommandResult -ScriptBlock $sb -State $State -ProjectDir $ProjectDir -ArgumentList @($manifest, $Configuration) -Label $label
    if ($Detailed) { return $result }
    return [bool]$result.Succeeded
}

<#
.SYNOPSIS
    Resolves a user-supplied run entry inside its project directory.
.DESCRIPTION
    Central guard for plugin Run implementations that execute an explicit
    script/source file. A Run entry outside ProjectDir, a missing file, or an
    unexpected extension fails closed to ''. This prevents `ProjectFile`
    traversal from becoming an arbitrary-file execution primitive while letting
    each language accept only its own executable file kinds.
#>
function Resolve-PluginRunEntry {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProjectFile,
        [Parameter(Mandatory)][string[]]$AllowedExtensions
    )
    if ([string]::IsNullOrWhiteSpace($ProjectFile)) { return '' }
    $contained = ''
    if (Get-Command Resolve-BuildContainedPath -ErrorAction SilentlyContinue) {
        try { $contained = Resolve-BuildContainedPath -Path $ProjectFile -Base $ProjectDir } catch { $contained = '' }
    } elseif (Get-Command Test-PathUnderRoots -ErrorAction SilentlyContinue) {
        try {
            $candidate = if ([System.IO.Path]::IsPathRooted($ProjectFile)) { [System.IO.Path]::GetFullPath($ProjectFile) } else { [System.IO.Path]::GetFullPath((Join-Path $ProjectDir $ProjectFile)) }
            if (Test-PathUnderRoots -Path $candidate -AllowedRoots @($ProjectDir)) { $contained = $candidate }
        } catch { $contained = '' }
    }
    if (-not $contained -or -not (Test-Path -LiteralPath $contained -PathType Leaf)) { return '' }
    $extension = [System.IO.Path]::GetExtension($contained)
    if (@($AllowedExtensions | Where-Object { $_ }) -notcontains $extension) { return '' }
    return $contained
}

<#
.SYNOPSIS
    Shared build preamble: tool check → manifest resolve → return manifest path.
    Returns the manifest path if ready, or $null if tool/manifest missing.
#>
function Resolve-PluginBuild {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][string]$ToolNotFoundMsg,
        [Parameter(Mandatory)][string[]]$ManifestFiles,
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$ProjectFile = ''
    )
    if (-not (Test-ToolAvailable -ToolName $ToolName)) {
        Write-Log $ToolNotFoundMsg 'Warn' $State; return $null
    }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles $ManifestFiles
    return $manifest
}

<#
.SYNOPSIS
    Checks whether a package.json defines a given npm script (build/test/lint...).
.DESCRIPTION
    Single implementation of the try/ConvertFrom-Json/scripts.<name> idiom that
    was duplicated in Node.psm1 (build + test) and DotnetHelpers.psm1 (build).
    Returns $false on missing file or malformed JSON (benign by contract).
#>
function Test-NpmScriptDefined {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$PackageJsonPath,
        [Parameter(Mandatory)][ValidateSet('build','test','lint','pack','ci')][string]$ScriptName
    )
    if (-not (Test-Path $PackageJsonPath)) { return $false }
    try {
        $pkg = if (Get-Command Read-JsonSafe -ErrorAction SilentlyContinue) { Read-JsonSafe -FilePath $PackageJsonPath } else { Get-Content $PackageJsonPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        if (-not $pkg) { return $false }
        return [bool]($pkg.scripts -and $pkg.scripts.$ScriptName)
    } catch {
        # Benign — malformed JSON leaves $false default, safe
        return $false
    }
}

<#
.SYNOPSIS
    Resolves an interpreter/tool exe from a priority list (Level 5 DRY).
.DESCRIPTION
    Single implementation of the `python3 -> python` probe idiom duplicated
    in Python.psm1. Returns the first tool found on PATH, or '' when none.
#>
function Resolve-ToolExe {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]]$Candidates
    )
    foreach ($c in $Candidates) {
        $command = Get-Command $c -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { continue }
        if ($c -match '^python(?:3)?(?:\.exe)?$') {
            try {
                $source = if ($command.Source) { [string]$command.Source } else { [string]$command.Path }
                $null = @(& $source --version 2>&1)
                if ($LASTEXITCODE -ne 0) { continue }
            } catch { continue }
        }
        return $c
    }
    return ''
}

<#
.SYNOPSIS
    Runs a scriptblock with a temporary environment variable.
.DESCRIPTION
    Replaces the hand-rolled `NODE_ENV` / `MIX_ENV` save/restore blocks in the
    Node and Elixir plugins. This helper existed with a comment claiming four
    such blocks in Node/PHP/Ruby/Elixir and had ZERO callers.

    It is also strictly safer than the blocks it replaces: those decided
    whether to restore with `if ($null -eq $previous)`, which is false whenever
    the variable existed but was empty, so an initially-empty NODE_ENV was
    removed instead of restored. Invoke-WithEnv uses Test-Path "env:$Name", which
    distinguishes "unset" from "set to empty".
#>
function Invoke-WithEnv {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Value = '',
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    $had = Test-Path "env:$Name"; $prev = $null
    if ($had) { $prev = (Get-Item "env:$Name").Value }
    try {
        if ($Value) { Set-Item "env:$Name" $Value } elseif ($had) { Remove-Item "env:$Name" -ErrorAction SilentlyContinue }
        return (& $ScriptBlock @ArgumentList)
    } finally {
        try {
            if ($had) { Set-Item "env:$Name" $prev } elseif (Test-Path "env:$Name") { Remove-Item "env:$Name" -ErrorAction SilentlyContinue }
        } catch { }
    }
}

<#
.SYNOPSIS
    Tests whether any well-known config file exists in a project dir (P1 DRY).
#>
function Test-ConfigFilePresent {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$ProjectDir, [Parameter(Mandatory)][string[]]$Patterns)
    foreach ($p in $Patterns) { if (@(Get-ChildItem -Path $ProjectDir -Filter $p -File -ErrorAction SilentlyContinue).Count -gt 0) { return $true } }
    return $false
}

function Test-PluginTestRequired {
    [CmdletBinding()]
    [OutputType([bool])]
    param([object]$State)
    if (-not $State -or -not $State.BuildConfig) { return $false }
    try {
        $test = $State.BuildConfig.build.test
        if ($test -and $test.PSObject.Properties.Name -contains 'required') { return [bool]$test.required }
        if ($test -and $test.PSObject.Properties.Name -contains 'failOnMissing') { return [bool]$test.failOnMissing }
    } catch { }
    return $false
}

function New-PluginActionResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Succeeded', 'Failed', 'Skipped', 'Blocked')]
        [string]$Status = 'Succeeded',
        [string]$Operation = 'plugin.action',
        [string]$ReasonCode = '',
        [string]$Message = '',
        [int]$ExitCode = 0,
        [object]$Details = $null,
        [string]$OutputPath = ''
    )
    $effectiveExit = if ($Status -in @('Failed', 'Blocked') -and $ExitCode -eq 0) { 1 } else { $ExitCode }
    $effectiveReason = if ($ReasonCode) { $ReasonCode } else { switch ($Status) { 'Succeeded' { 'OK' } 'Failed' { 'Failed' } 'Skipped' { 'Skipped' } 'Blocked' { 'Blocked' } } }
    $effectiveMessage = if ($Message) { $Message } else { "$Operation $Status" }
    return [PSCustomObject]@{
        Status      = [string]$Status
        Operation   = [string]$Operation
        ReasonCode  = [string]$effectiveReason
        Message     = [string]$effectiveMessage
        ExitCode    = [int]$effectiveExit
        DurationMs  = 0
        Details     = $Details
        OutputPath  = [string]$OutputPath
        Skipped     = ([string]$Status -eq 'Skipped')
        Succeeded   = ([string]$Status -eq 'Succeeded')
    }
}

<#
.SYNOPSIS
    Config-node accessor. Single source: ConfigProvider.Get-SectionValue.
.DESCRIPTION
    The local implementation used `$Object.Contains($Name)` only, so an ordinal
    dictionary missed on a casing difference and returned the default. A plugin
    reading its own manifest with different key casing would silently take defaults.
#>
function Get-PluginObjectValue {
    param([object]$Object, [string]$Name, [object]$Default = $null)
    # Unconditional delegation; see AuditLedger.Get-LedgerField for why the
    # guarded inline fallback this replaced could never execute.
    return Get-SectionValue -Section $Object -Key $Name -Default $Default
}

function ConvertTo-PluginActionResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][object]$Value,
        [string]$Operation = 'plugin.action',
        [string]$OutputPath = ''
    )
    if ($null -eq $Value) {
        $lower = $Operation.ToLowerInvariant()
        $status = if ($lower -match 'test|lint|clean|run') { 'Skipped' } else { 'Failed' }
        $code = if ($status -eq 'Skipped') { 'NoImplementation' } else { 'NullResult' }
        return New-PluginActionResult -Status $status -Operation $Operation -ReasonCode $code -OutputPath $OutputPath
    }
    if ($Value -is [bool]) {
        return New-PluginActionResult -Status $(if ($Value) { 'Succeeded' } else { 'Failed' }) -Operation $Operation -ReasonCode $(if ($Value) { 'OK' } else { 'FalseResult' }) -Details $Value -OutputPath $OutputPath
    }
    if ($Value -is [System.Management.Automation.ErrorRecord] -or $Value -is [System.Exception]) {
        $message = if ($Value -is [System.Management.Automation.ErrorRecord]) { $Value.Exception.Message } else { $Value.Message }
        return New-PluginActionResult -Status Failed -Operation $Operation -ReasonCode 'Exception' -Message $message -Details $Value -OutputPath $OutputPath
    }
    $props = @()
    if ($Value -is [System.Collections.IDictionary]) { $props = @($Value.Keys) } else { $props = @($Value.PSObject.Properties.Name) }
    if ($props -contains 'Status') {
        $status = [string](Get-PluginObjectValue -Object $Value -Name 'Status' -Default 'Failed')
        if ($status -notin @('Succeeded', 'Failed', 'Skipped', 'Blocked')) {
            return New-PluginActionResult -Status Failed -Operation $Operation -ReasonCode 'InvalidResult' -Message "Invalid plugin status: $status" -Details $Value -OutputPath $OutputPath
        }
        $reason = [string](Get-PluginObjectValue -Object $Value -Name 'ReasonCode' -Default '')
        $message = [string](Get-PluginObjectValue -Object $Value -Name 'Message' -Default '')
        $exit = [int](Get-PluginObjectValue -Object $Value -Name 'ExitCode' -Default 0)
        $details = Get-PluginObjectValue -Object $Value -Name 'Details' -Default $Value
        $path = [string](Get-PluginObjectValue -Object $Value -Name 'OutputPath' -Default $OutputPath)
        return New-PluginActionResult -Status $status -Operation $Operation -ReasonCode $reason -Message $message -ExitCode $exit -Details $details -OutputPath $path
    }
    if ($props -contains 'Passed' -or $props -contains 'Success') {
        $passed = [bool](Get-PluginObjectValue -Object $Value -Name 'Passed' -Default (Get-PluginObjectValue -Object $Value -Name 'Success' -Default $false))
        $skipped = [bool](Get-PluginObjectValue -Object $Value -Name 'Skipped' -Default $false)
        $status = if ($skipped) { 'Skipped' } elseif ($passed) { 'Succeeded' } else { 'Failed' }
        $reason = [string](Get-PluginObjectValue -Object $Value -Name 'ReasonCode' -Default $(if ($status -eq 'Skipped') { 'Skipped' } elseif ($status -eq 'Succeeded') { 'OK' } else { 'FalseResult' }))
        $message = [string](Get-PluginObjectValue -Object $Value -Name 'Message' -Default '')
        $path = [string](Get-PluginObjectValue -Object $Value -Name 'OutputPath' -Default $OutputPath)
        return New-PluginActionResult -Status $status -Operation $Operation -ReasonCode $reason -Message $message -ExitCode ([int](Get-PluginObjectValue -Object $Value -Name 'ExitCode' -Default 0)) -Details $Value -OutputPath $path
    }
    if ($Value -is [System.Array] -or ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary])) {
        $items = @($Value)
        if ($items.Count -eq 0) { return New-PluginActionResult -Status Skipped -Operation $Operation -ReasonCode 'NoImplementation' -OutputPath $OutputPath }
        $converted = @($items | ForEach-Object { ConvertTo-PluginActionResult -Value $_ -Operation $Operation -OutputPath $OutputPath })
        $failed = @($converted | Where-Object { $_.Status -eq 'Failed' })
        $blocked = @($converted | Where-Object { $_.Status -eq 'Blocked' })
        $skipped = @($converted | Where-Object { $_.Status -eq 'Skipped' })
        $status = if ($failed.Count -gt 0) { 'Failed' } elseif ($blocked.Count -gt 0) { 'Blocked' } elseif ($skipped.Count -gt 0) { 'Skipped' } else { 'Succeeded' }
        $reason = if ($failed.Count -gt 0) { $failed[0].ReasonCode } elseif ($blocked.Count -gt 0) { $blocked[0].ReasonCode } elseif ($skipped.Count -gt 0) { $skipped[0].ReasonCode } else { 'OK' }
        return New-PluginActionResult -Status $status -Operation $Operation -ReasonCode $reason -Details $Value -OutputPath $OutputPath
    }
    return New-PluginActionResult -Status Failed -Operation $Operation -ReasonCode 'UnexpectedResult' -Message 'Plugin returned a non-boolean result without a status' -Details $Value -OutputPath $OutputPath
}

function ConvertTo-PluginBoolean {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Value, [string]$Operation = 'plugin.action')
    $result = ConvertTo-PluginActionResult -Value $Value -Operation $Operation
    return ($result.Status -eq 'Succeeded')
}

function Invoke-PluginCommandResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object]$State,
        [string]$ProjectDir,
        [string]$WorkingDir,
        [object[]]$ArgumentList = @(),
        [string]$Label
    )
    $target = if ($WorkingDir) { $WorkingDir } else { $ProjectDir }
    if (-not $target) { $target = (Get-Location).ProviderPath }
    if ($Label -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) { Write-Log $Label 'Info' $State }
    $output = @()
    $errors = @()
    $exitCode = 0
    $failure = $null
    $commandSuccess = $true
    $hadExit = Test-Path Variable:global:LASTEXITCODE
    $oldExit = $null
    if ($hadExit) { $oldExit = $global:LASTEXITCODE }
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        $global:LASTEXITCODE = 0
        Push-Location -LiteralPath $target -ErrorAction Stop
        try {
            $rawOutput = & $ScriptBlock @ArgumentList 2>&1
            $commandSuccess = $?
            $output = @($rawOutput)
            $exitCode = [int]$global:LASTEXITCODE
        } finally {
            Pop-Location
        }
    } catch {
        $failure = $_
        if ($_.Exception) { $errors += $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $oldPreference
        if ($hadExit) { $global:LASTEXITCODE = $oldExit } else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    }
    foreach ($item in @($output)) {
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            $errors += $item
        }
    }
    $hardErrors = @($errors | Where-Object {
        $item = $_
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            try { return ([string]$item.FullyQualifiedErrorId -ne 'NativeCommandError') } catch { return $true }
        }
        return $true
    })
    $structuredOutput = @($output | Where-Object { $_ -isnot [string] -and $_ -isnot [System.Management.Automation.ErrorRecord] -and (Get-PluginObjectValue -Object $_ -Name 'Status' -Default '') -in @('Succeeded', 'Failed', 'Skipped', 'Blocked') })
    $structuredStatus = ''
    $structuredMessage = ''
    $structuredExit = 0
    if ($structuredOutput.Count -eq 1) {
        $structuredStatus = [string](Get-PluginObjectValue -Object $structuredOutput[0] -Name 'Status' -Default '')
        $structuredMessage = [string](Get-PluginObjectValue -Object $structuredOutput[0] -Name 'Message' -Default '')
        $structuredExit = [int](Get-PluginObjectValue -Object $structuredOutput[0] -Name 'ExitCode' -Default 0)
    }
    $status = if ($structuredStatus) { $structuredStatus } elseif ($failure -or -not $commandSuccess -or $exitCode -ne 0 -or $hardErrors.Count -gt 0) { 'Failed' } else { 'Succeeded' }
    $message = if ($structuredMessage) { $structuredMessage } elseif ($failure) { [string]$failure.Exception.Message } elseif ($status -eq 'Failed' -and $exitCode -ne 0) { "Command failed with exit code $exitCode" } elseif ($status -eq 'Failed') { 'Command emitted an error' } else { 'Command completed' }
    $details = if ($output.Count -eq 0) { $null } else { $output }
    $effectiveExit = if ($structuredStatus) { $structuredExit } else { $exitCode }
    $reason = if ($status -eq 'Succeeded') { 'ExitCodeZero' } elseif ($effectiveExit -ne 0) { 'NonZeroExit' } else { 'CommandError' }
    return New-PluginActionResult -Status $status -Operation 'plugin.command' -ReasonCode $reason -Message $message -ExitCode $effectiveExit -Details $details
}

function Resolve-PluginOutputDir {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [object]$State,
        [string]$ProjectDir,
        [string]$Subdirectory = ''
    )
    $root = ''
    if ($State) { $root = [string](Get-PluginObjectValue -Object $State -Name 'ProjectRoot' -Default '') }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [string]$ProjectDir }
    if ([string]::IsNullOrWhiteSpace($root)) { return '' }
    $publish = 'publish-output'
    if (Get-Command Resolve-PublishOutputDir -ErrorAction SilentlyContinue) {
        try { $publish = [string](Resolve-PublishOutputDir -State $State) } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($publish)) { $publish = 'publish-output' }
    $path = Join-Path $root $publish
    if (-not [string]::IsNullOrWhiteSpace($Subdirectory)) { $path = Join-Path $path $Subdirectory }
    try { return [System.IO.Path]::GetFullPath($path) } catch { return $path }
}

function New-PluginOutputDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [object]$State,
        [string]$ProjectDir,
        [string]$Subdirectory = ''
    )
    $path = Resolve-PluginOutputDir -State $State -ProjectDir $ProjectDir -Subdirectory $Subdirectory
    if ($path) { New-Item -ItemType Directory -Path $path -Force -ErrorAction SilentlyContinue | Out-Null }
    return $path
}

function Publish-PluginArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Result,
        [object]$State,
        [string]$ProjectDir,
        [string]$Subdirectory = '',
        [string[]]$CandidatePaths = @()
    )
    $destination = New-PluginOutputDirectory -State $State -ProjectDir $ProjectDir -Subdirectory $Subdirectory
    foreach ($candidate in @($CandidatePaths)) {
        if (-not $candidate) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Copy-Item -LiteralPath $candidate -Destination (Join-Path $destination ([System.IO.Path]::GetFileName($candidate))) -Force -ErrorAction SilentlyContinue
        } elseif (Test-Path -LiteralPath $candidate -PathType Container) {
            Copy-Item -Path (Join-Path $candidate '*') -Destination $destination -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $Result | Add-Member -MemberType NoteProperty -Name OutputPath -Value $destination -Force
    return $Result
}

function Get-CanonicalPathHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { $full = $Path }
    $full = $full.TrimEnd('\', '/') -replace '\\', '/'
    if (Get-Command Test-IsWindowsHost -ErrorAction SilentlyContinue) { if (Test-IsWindowsHost) { $full = $full.ToLowerInvariant() } } else { $full = $full.ToLowerInvariant() }
    # UTF8 -> SHA256 -> lowercase hex over a STRING is exactly what
    # SharedUtils.Get-BuildStringHash owns, and it produces the identical digest.
    # The inline block this replaces was a real duplicate that the
    # stringHashDelegation ratchet failed to see (its fingerprint required
    # UTF8.GetBytes to sit inside the ComputeHash call on one line, which is not
    # how this - or any - site is written).
    if (-not (Get-Command Get-BuildStringHash -ErrorAction SilentlyContinue)) {
        [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildStringHash')
    }
    if (-not (Get-Command Get-BuildStringHash -ErrorAction SilentlyContinue)) {
        # Owner unreachable (fully stripped import): fail closed to a distinct,
        # obviously-not-a-cache-key value rather than silently emitting a
        # constant that would collide across every plugin.
        return ''
    }
    $hex = [string](Get-BuildStringHash -Text $full)
    # build.cache.pluginHashLength (shipped as 12) was declared and mapped to
    # config but nothing read it, so shortening the cache-key path hash - an
    # explicit tuning knob for cache index size and collision resistance -
    # had no effect. 0 (or >= the full length) means "use the full hash".
    $hashLen = 0
    if (Get-Command Get-BuildConstant -ErrorAction SilentlyContinue) {
        try { $hashLen = [int](Get-BuildConstant -Key 'PluginCacheHashLength' -Fallback 0) } catch { $hashLen = 0 }
    }
    if ($hashLen -gt 0 -and $hashLen -lt $hex.Length) { return $hex.Substring(0, $hashLen) }
    return $hex
}

function Get-PluginFileHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $text = [string]$Path
        # SharedUtils.Get-BuildStringHash owns UTF8 -> SHA256 -> lowercase hex.
        # Same digest as the inline copy this replaces, so plugin cache keys
        # derived from a missing path stay stable.
        [void](Initialize-BuildSharedUtils -SentinelCommand 'Get-BuildStringHash')
        return (Get-BuildStringHash -Text $text)
    }
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction SilentlyContinue
    if ($hash) { return ([string]$hash.Hash).ToLowerInvariant() }
    return ''
}

function Get-PluginInputHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ProjectDir, [string]$ProjectFile = '')
    if (Get-Command Get-DirectoryHash -ErrorAction SilentlyContinue -and $ProjectDir) {
        try {
            $h = [string](Get-DirectoryHash -Directory $ProjectDir)
            if ($h) { return $h.ToLowerInvariant() }
        } catch { }
    }
    $paths = @()
    if ($ProjectFile -and (Test-Path -LiteralPath $ProjectFile -PathType Leaf)) { $paths += (Get-Item -LiteralPath $ProjectFile).FullName }
    if ($ProjectDir -and (Test-Path -LiteralPath $ProjectDir -PathType Container)) {
        $paths += @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules|target|dist|\.git|publish-output)[\\/]' } | Select-Object -ExpandProperty FullName)
    }
    $paths = @($paths | Sort-Object -Unique)
    if ($paths.Count -eq 0) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.MemoryStream]::new()
    try {
        foreach ($p in $paths) {
            $name = [System.Text.Encoding]::UTF8.GetBytes($p)
            $stream.Write($name, 0, $name.Length)
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                $bytes = [System.IO.File]::ReadAllBytes($p)
                $stream.Write($bytes, 0, $bytes.Length)
            }
            $stream.WriteByte(0xFF)
        }
        $stream.Position = 0
        return (([System.BitConverter]::ToString($sha.ComputeHash($stream.ToArray()))) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose(); $stream.Dispose() }
}

function Get-PluginToolVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ToolName, [object]$State)
    $name = [string]$ToolName
    if ((-not $name) -and $State) { $name = [string](Get-PluginObjectValue -Object $State -Name 'DotnetCmd' -Default '') }
    if ([string]::IsNullOrWhiteSpace($name)) { return 'unknown' }
    $command = $null
    try { $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { }
    if (-not $command) { return 'unknown' }
    try {
        $source = if ($command.Source) { [string]$command.Source } else { [string]$command.Path }
        $text = @(& $source --version 2>$null) -join ' '
        $text = ([string]$text).Trim()
        if ($text) { return (($text -replace '[\r\n|]+', ' ') -replace '\s+', ' ') }
    } catch { }
    return 'unknown'
}

function Get-PluginCacheKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [object]$Plugin,
        [string]$Language = '',
        [string]$ProjectDir = '',
        [string]$ProjectFile = '',
        [string]$Configuration = '',
        [string]$Toolchain = '',
        [string]$InputHash = ''
    )
    $info = Get-PluginObjectValue -Object $Plugin -Name 'Info' -Default $Plugin
    $pluginPath = [string](Get-PluginObjectValue -Object $Plugin -Name 'Path' -Default '')
    $version = [string](Get-PluginObjectValue -Object $info -Name 'Version' -Default '')
    if ([string]::IsNullOrWhiteSpace($version)) { $version = [string](Get-PluginObjectValue -Object $info -Name 'Name' -Default $Language) }
    $pathForKey = if ($ProjectFile) { $ProjectFile } else { $ProjectDir }
    $pathHash = Get-CanonicalPathHash -Path $pathForKey
    $pluginHash = if ($pluginPath) { Get-PluginFileHash -Path $pluginPath } else { Get-PluginFileHash -Path ([string](Get-PluginObjectValue -Object $info -Name 'Name' -Default $Language)) }
    $toolName = if ($Toolchain) { $Toolchain } else { [string](Get-PluginObjectValue -Object $info -Name 'ToolName' -Default 'unknown') }
    $toolVersion = Get-PluginToolVersion -ToolName $toolName
    if ([string]::IsNullOrWhiteSpace($InputHash)) { $InputHash = Get-PluginInputHash -ProjectDir $ProjectDir -ProjectFile $ProjectFile }
    $configuration = if ([string]::IsNullOrWhiteSpace($Configuration)) { 'default' } else { $Configuration }
    $parts = @('plugin-build-v2', $pathHash, $configuration, $version, $pluginHash, $toolName, $toolVersion, $InputHash) | ForEach-Object { ([string]$_).Replace('|', '_') }
    return ($parts -join '|')
}

Export-ModuleMember -Function @(
    'Resolve-PluginManifest',
    'Get-PluginLocaleText',
    'Get-SimplePluginPreflight',
    'Invoke-SimplePluginTest',
    'Invoke-SimplePluginLint',
    'Invoke-SimplePluginClean',
    'Invoke-SimplePluginRun',
    'Resolve-PluginRunEntry',
    'Resolve-PluginBuild',
    'Test-NpmScriptDefined',
    'Resolve-ToolExe',
    'Invoke-WithEnv',
    'Test-ConfigFilePresent',
    'Test-PluginTestRequired',
    'Get-PluginObjectValue',
    'New-PluginActionResult',
    'ConvertTo-PluginActionResult',
    'ConvertTo-PluginBoolean',
    'Invoke-PluginCommandResult',
    'Resolve-PluginOutputDir',
    'New-PluginOutputDirectory',
    'Publish-PluginArtifacts',
    'Get-CanonicalPathHash',
    'Get-PluginFileHash',
    'Get-PluginInputHash',
    'Get-PluginToolVersion',
    'Get-PluginCacheKey'
)
