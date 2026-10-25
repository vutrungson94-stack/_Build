# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

. (Join-Path $PSScriptRoot 'BasePlugin.ps1')
$null = Import-Module (Join-Path $PSScriptRoot 'helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
# Import PathUtils with Join-Path, NOT a hardcoded '..\PathUtils.psm1'. On Linux and
# macOS a backslash is a legal FILENAME character, so the literal path never resolved
# and the drifted fallback below was used on every non-Windows host.
$null = Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'PathUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

# Exclude-dir regex: single source PathUtils.Get-ExcludeDirPattern. The old inline
# fallback listed only 6 directories (missing .git, TestResults, publish-output,
# .gbuildcache and .tools) and left '.' unescaped, so it matched ANY character
# instead of a literal dot. BuildConstants.SyntaxCheckExcludeDirs is the owner.
$script:ExcludeDirPattern = if (Get-Command Get-ExcludeDirPattern -ErrorAction SilentlyContinue) {
    Get-ExcludeDirPattern -FromConstant 'SyntaxCheckExcludeDirs' -Extra @('_Sync', '_Tests', '_Launch')
} else {
    $__ex = @('obj', 'bin', '.git', 'node_modules', 'TestResults', 'publish-output', '.gbuildcache', 'build-reports', 'logs', '_Build', '.tools', '_Sync', '_Tests', '_Launch')
    '[\\/](' + (($__ex | ForEach-Object { [regex]::Escape([string]$_) }) -join '|') + ')[\\/]'
}

Set-PluginMetadata @{
    Name = 'PowerShell'
    SupportedLanguages = @('PowerShell')
    Priority = 1
    ToolName = 'pwsh'
    FallbackToolNames = @('powershell.exe', 'powershell', 'pwsh')
    ManifestFiles = @('*.psm1', '*.ps1')
    BuildCommand = 'Parser syntax check'
    TestCommand = 'Pester'
    LintCommand = 'PSScriptAnalyzer'
    CleanCommand = ''
    RunCommand = ''
    MissingToolLevel = 'Warn'
}

function Resolve-PowerShellHostPath {
    <#
    .SYNOPSIS
        Full PATH of the PowerShell host, or '' when none is installed.
    .DESCRIPTION
        Deliberately a DIFFERENT NAME from SharedUtils.Resolve-PowerShellHost.
        The shared resolver owns the preference ORDER and returns a command
        NAME; this plugin spawns a child host and therefore needs a path. It
        used to be called Resolve-PowerShellHost and re-wrote the candidate
        list, which meant the local definition shadowed the shared one inside
        this module - the shared resolver could not be reached from here at all,
        so the order lived in two places with no way to keep them in step.
        A distinct name makes the delegation explicit and reversible.
    #>
    param()

Set-StrictMode -Version 1.0
    $name = ''
    if (Get-Command Resolve-PowerShellHost -ErrorAction SilentlyContinue) {
        try { $name = [string](Resolve-PowerShellHost) } catch { $name = '' }
    }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'pwsh' }
    $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { if ($command.Source) { return [string]$command.Source }; return [string]$command.Path }
    return ''
}

function Get-PesterInfo {
    $module = Get-Module -ListAvailable -Name Pester -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) { return $null }
    return [PSCustomObject]@{ Module = $module; Version = [version]$module.Version }
}

$script:CustomBuild = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = Resolve-PluginConfiguration -State $State -Configuration $Configuration }
    $hostPath = Resolve-PowerShellHostPath
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('*.psm1', '*.ps1')
    if (-not $manifest -or -not $hostPath) { $r = New-PluginActionResult -Status Failed -Operation 'powershell.build' -ReasonCode $(if (-not $hostPath) { 'ToolMissing' } else { 'ManifestMissing' }) -Message 'PowerShell host or project script was not found'; if ($Detailed) { return $r }; return $false }
    $files = @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { ($_.Extension -in @('.ps1', '.psm1')) -and ($_.FullName -notmatch $script:ExcludeDirPattern) })
    $errors = @()
    foreach ($file in $files) {
        $tokens = $null; $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors) { $errors += @($parseErrors | ForEach-Object { $_.Message }) }
    }
    if ($errors.Count -gt 0) { $r = New-PluginActionResult -Status Failed -Operation 'powershell.build' -ReasonCode 'ParseError' -Message "PowerShell syntax check failed with $($errors.Count) error(s)" -Details $errors; if ($Detailed) { return $r }; return $false }
    $output = New-PluginOutputDirectory -State $State -ProjectDir $ProjectDir -Subdirectory 'powershell'
    $r = New-PluginActionResult -Status Succeeded -Operation 'powershell.build' -ReasonCode 'OK' -Message "PowerShell syntax check passed for $($files.Count) file(s)" -Details $files.FullName -OutputPath $output
    if ($Detailed) { return $r }
    return $true
}

$script:CustomTest = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $pester = Get-PesterInfo
    $tests = @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -Filter '*.Tests.ps1' -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch $script:ExcludeDirPattern })
    if (-not $pester) { $r = New-PluginActionResult -Status Skipped -Operation 'powershell.test' -ReasonCode 'ToolMissing' -Message 'Pester is not installed'; if ($Detailed) { return $r }; return $false }
    if ($tests.Count -eq 0) { $r = New-PluginActionResult -Status Skipped -Operation 'powershell.test' -ReasonCode 'NoTests' -Message 'No Pester test files were found'; if ($Detailed) { return $r }; return $false }
    try {
        if ($pester.Version.Major -ge 5) {
            $cfg = New-PesterConfiguration
            $cfg.Run.Path = @($tests.FullName)
            $cfg.Run.PassThru = $true
            $cfg.Run.Exit = $false
            $raw = Invoke-Pester -Configuration $cfg
            $failed = if ($raw) { [int]$raw.FailedCount } else { 0 }
        } else {
            $raw = Invoke-Pester -Path @($tests.FullName) -PassThru
            $failed = if ($raw) { [int]$raw.FailedCount } else { 0 }
        }
        if ($failed -gt 0) { $r = New-PluginActionResult -Status Failed -Operation 'powershell.test' -ReasonCode 'TestFailed' -Message "Pester reported $failed failed test(s)" -Details $raw; if ($Detailed) { return $r }; return $false }
        $r = New-PluginActionResult -Status Succeeded -Operation 'powershell.test' -ReasonCode 'OK' -Message 'Pester tests passed' -Details $raw
        if ($Detailed) { return $r }
        return $true
    } catch { $r = New-PluginActionResult -Status Failed -Operation 'powershell.test' -ReasonCode 'Exception' -Message $_.Exception.Message -Details $_; if ($Detailed) { return $r }; return $false }
}

# Ensure the analyzer exists before reporting the plugin's lint/preflight as
# degraded. Single call site of the platform resolver in this plugin: the analyzer
# ships inside _Build itself, so a missing one is a platform supply question, not a
# prerequisite for the project. Returns $true when Invoke-ScriptAnalyzer resolves.
$script:EnsureScriptAnalyzer = {
    param($State)
    if (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue) { return $true }
    if (Get-Command Resolve-VendoredToolModule -ErrorAction SilentlyContinue) {
        try { $null = Resolve-VendoredToolModule -EntryPoint 'Invoke-ScriptAnalyzer' -State $State } catch { }
    }
    return [bool](Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)
}

$script:CustomLint = {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Incremental, [switch]$Detailed)
    $files = @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { ($_.Extension -in @('.ps1', '.psm1')) -and ($_.FullName -notmatch $script:ExcludeDirPattern) })
    if (-not (& $script:EnsureScriptAnalyzer $State)) { $r = New-PluginActionResult -Status Skipped -Operation 'powershell.lint' -ReasonCode 'ToolMissing' -Message 'PSScriptAnalyzer is unavailable: it is not bundled with this _Build copy and not on PATH'; if ($Detailed) { return $r }; return $false }
    if ($files.Count -eq 0) { $r = New-PluginActionResult -Status Skipped -Operation 'powershell.lint' -ReasonCode 'NoFiles' -Message 'No PowerShell files were found'; if ($Detailed) { return $r }; return $false }
    $issues = @()
    foreach ($file in $files) { $issues += @(Invoke-ScriptAnalyzer -Path $file.FullName -ErrorAction SilentlyContinue | Where-Object { $_.Severity -in @('Error', 'Warning') }) }
    if ($issues.Count -gt 0) { $r = New-PluginActionResult -Status Failed -Operation 'powershell.lint' -ReasonCode 'LintFailed' -Message "PSScriptAnalyzer reported $($issues.Count) issue(s)" -Details $issues; if ($Detailed) { return $r }; return $false }
    $r = New-PluginActionResult -Status Succeeded -Operation 'powershell.lint' -ReasonCode 'OK' -Message 'PSScriptAnalyzer reported no issues'
    if ($Detailed) { return $r }
    return $true
}

$script:CustomPreflight = {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$ProjectDir, [string]$ProjectFile = '')
    $errors = @(); $warnings = @()
    if (-not (Resolve-PowerShellHostPath)) { $errors += 'No supported PowerShell host was found' }
    if (-not (Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('*.psm1', '*.ps1'))) { $warnings += 'No PowerShell manifest was found' }
    if (-not (Get-PesterInfo)) { $warnings += 'Pester is not installed' }
    if (-not (& $script:EnsureScriptAnalyzer $State)) { $warnings += 'PSScriptAnalyzer is unavailable (not bundled with this _Build copy and not on PATH) - lint and PowerShell SAST will not run' }
    return @{ Passed = ($errors.Count -eq 0); Errors = $errors; Warnings = $warnings }
}

$script:CustomClean = {
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [switch]$Detailed)
    # PowerShell generates no per-project compiled object tree; the safe
    # "clean" is a no-op success so a PS project is never force-deleted.
    $r = New-PluginActionResult -Status Succeeded -Operation 'powershell.clean' -ReasonCode 'NoObjects' -Message 'PowerShell projects have no compiled artifacts to clean'
    if ($Detailed) { return $r }
    return $true
}

$script:CustomRun = {
    param([Parameter(Mandatory)][PSCustomObject]$State, [Parameter(Mandatory)][string]$ProjectDir, [string]$ProjectFile = '', [string]$Configuration = '', [string]$Arguments = '', [switch]$Detailed)
    $hostPath = Resolve-PowerShellHostPath
    if (-not $hostPath) { $r = New-PluginActionResult -Status Skipped -Operation 'powershell.run' -ReasonCode 'ToolMissing' -Message 'PowerShell host is not available'; if ($Detailed) { return $r }; return $false }
    $manifest = Resolve-PluginManifest -ProjectFile $ProjectFile -ProjectDir $ProjectDir -ManifestFiles @('*.psm1', '*.ps1')
    if (-not $manifest) { $r = New-PluginActionResult -Status Skipped -Operation 'powershell.run' -ReasonCode 'ManifestMissing' -Message 'No PowerShell script was found'; if ($Detailed) { return $r }; return $false }
    $entry = Resolve-PluginRunEntry -ProjectDir $ProjectDir -ProjectFile $ProjectFile -AllowedExtensions @('.ps1')
    if (-not $entry) { $r = New-PluginActionResult -Status Skipped -Operation 'powershell.run' -ReasonCode 'NoEntryPoint' -Message 'Provide a .ps1 entry point via -ProjectFile'; if ($Detailed) { return $r }; return $false }
    $result = Invoke-PluginCommandResult -ScriptBlock { param($exe, $script, $extra) & $exe -NoProfile -ExecutionPolicy Bypass -File $script $extra } -State $State -ProjectDir $ProjectDir -ArgumentList @($hostPath, $entry, $Arguments) -Label "Running $(Split-Path -Leaf $entry)..."
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
