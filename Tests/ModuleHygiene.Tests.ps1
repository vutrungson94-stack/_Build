#Requires -Version 5.1
Set-StrictMode -Version 1.0

# Tripwire for the PS 5.1 module-scope orphan incident:
#   [FATAL] Invoke-EnsureDirectory not recognized in Save-BuildState.
# Root cause (proven by repro on powershell.exe 5.1): a nested
#   Import-Module <shared> -Force   (WITHOUT -Global)
# executed from inside a module orphans the global copy on PS 5.1, so the
# command vanishes from every module scope. Trigger was
# Modules/Plugins/PowerShell.psm1 re-importing ..\PathUtils.psm1 this way
# during Test-PluginContracts, before Resolve-BuildSdk -> Save-BuildState.
# These tests fail the build if the pattern ever returns. They must stay
# PS 5.1-parseable themselves (no `(if)` subexpressions, no ?. / ??).
# NOTE (Pester 5): helpers live inside BeforeAll — file-level functions are
# not visible to Describe blocks under Pester 5 discovery.

Describe 'ModuleHygiene - PS 5.1 orphan prevention' {
BeforeAll {
$script:HygieneModulesRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules'
# The shared detector library. This file previously carried its own inline
# copies of the -Force/-Global import rule - twice, byte-identical - which is
# why 0 of its 7 gates were detector-routed and why both copies shared one blind
# spot. Importing the library is what routes them.
. (Join-Path $PSScriptRoot 'GateDetectors.ps1')

        function Get-HygieneCodeText {
            [CmdletBinding()]
            [OutputType([string])]
            param(
                [Parameter(Mandatory)][string]$Path,
                [switch]$KeepStrings
            )
            $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not $lines) { return '' }
            $out = New-Object System.Collections.Generic.List[string]
            $inBlock = $false
            $inHere = $false
            foreach ($raw in $lines) {
                $line = [string]$raw
                if ($inHere) {
                    if ($line -match '^\s*"@\s*$') { $inHere = $false }
                    continue
                }
                if ($line -match '^\s*@"\s*$') { $inHere = $true; continue }
                $code = $line
                $guard = 0
                while ($true) {
                    $guard++
                    if ($guard -gt 20) { break }
                    if ($inBlock) {
                        $e = $code.IndexOf('#>')
                        if ($e -ge 0) { $code = $code.Substring($e + 2); $inBlock = $false } else { $code = ''; break }
                    } else {
                        $s = $code.IndexOf('<#')
                        if ($s -lt 0) { break }
                        $e = $code.IndexOf('#>', $s + 2)
                        if ($e -ge 0) { $code = $code.Substring(0, $s) + ' ' + $code.Substring($e + 2) } else { $code = $code.Substring(0, $s); $inBlock = $true; break }
                    }
                }
                $sb = New-Object System.Text.StringBuilder
                $sq = $false
                $dq = $false
                $subDepth = 0
                $i = 0
                while ($i -lt $code.Length) {
                    $ch = $code[$i]
                    if ($sq) {
                        if ($KeepStrings) { [void]$sb.Append($ch) }
                        if ($ch -eq "'") {
                            if (($i + 1) -lt $code.Length -and $code[$i + 1] -eq "'") {
                                if ($KeepStrings) { [void]$sb.Append("'") }
                                $i += 2
                            } else { $sq = $false; $i++ }
                        } else { $i++ }
                        continue
                    }
                    if ($dq) {
                        if ($KeepStrings) { [void]$sb.Append($ch) }
                        if ($ch -eq '`' -and ($i + 1) -lt $code.Length) {
                            if ($KeepStrings) { [void]$sb.Append($code[$i + 1]) }
                            $i += 2
                            continue
                        }
                        # $() inside "..." EXECUTES at runtime: scan it as code.
                        # Skipped when -KeepStrings (the whole string is kept
                        # verbatim anyway, so its $() content is already visible).
                        # Twin logic lives in PS51Compat.Tests.ps1.
                        if (-not $KeepStrings -and $ch -eq '$' -and ($i + 1) -lt $code.Length -and $code[$i + 1] -eq '(') {
                            [void]$sb.Append('$(')
                            $i += 2
                            $subDepth++
                            continue
                        }
                        if ($subDepth -gt 0) {
                            [void]$sb.Append($ch)
                            if ($ch -eq '(') { $subDepth++ }
                            elseif ($ch -eq ')') { $subDepth-- }
                            $i++
                            continue
                        }
                        if ($ch -eq '"') {
                            if (($i + 1) -lt $code.Length -and $code[$i + 1] -eq '"') { $i += 2 } else { $dq = $false; $i++ }
                        } else { $i++ }
                        continue
                    }
                    if ($ch -eq '#') { break }
                    if ($ch -eq "'") { if ($KeepStrings) { [void]$sb.Append($ch) }; $sq = $true; $i++; continue }
                    if ($ch -eq '"') { if ($KeepStrings) { [void]$sb.Append($ch) }; $dq = $true; $i++; continue }
                    [void]$sb.Append($ch)
                    $i++
                }
                $out.Add($sb.ToString())
            }
            return ($out -join "`n")
        }

        function Get-HygieneTierOneModules {
            [CmdletBinding()]
            [OutputType([string[]])]
            param()
            # SINGLE SOURCE: Modules/Tier1Modules.ps1. This helper used to
            # regex-match the first `foreach ($dep in @(...))` in
            # Orchestrator.psm1, which meant it validated only the FIRST of the
            # two inline copies (gbuild.ps1 -SelfTest carried the second) and a
            # drifted copy was invisible to CI. Both consumers dot-source the
            # same data file now, so the test reads the data file itself.
            $dataFile = Join-Path $script:HygieneModulesRoot 'Tier1Modules.ps1'
            if (-not (Test-Path -LiteralPath $dataFile -PathType Leaf)) { return @() }
            . $dataFile
            $list = Get-Tier1ModuleList
            if (-not $list -or -not $list.Core) { return @() }
            return @($list.Core)
        }

        $script:TierOne = @(Get-HygieneTierOneModules | Where-Object { $_ -ne $null })
        $script:ModuleDiscoveryErrors = New-Object System.Collections.Generic.List[string]
        if (-not (Test-Path -LiteralPath $script:HygieneModulesRoot -PathType Container)) {
            $script:ModuleDiscoveryErrors.Add("missing root: $script:HygieneModulesRoot")
            $script:ModuleFiles = @()
        } else {
            try {
                $script:ModuleFiles = @(Get-ChildItem -LiteralPath $script:HygieneModulesRoot -Recurse -File -Force -ErrorAction Stop | Where-Object {
                    $extension = $_.Extension.ToLowerInvariant()
                    return ($extension -eq '.ps1' -or $extension -eq '.psm1' -or $extension -eq '.psd1')
                } | Sort-Object -Property FullName)
            } catch {
                $script:ModuleDiscoveryErrors.Add("${script:HygieneModulesRoot}: $($_.Exception.Message)")
                $script:ModuleFiles = @()
            }
        }
    }

    It 'discovers all nested module files and fails closed on discovery errors' {
        $script:ModuleDiscoveryErrors | Should -BeNullOrEmpty
        $script:ModuleFiles.Count | Should -BeGreaterThan 70
        $script:ModuleFiles.FullName | Should -Contain (Join-Path $script:HygieneModulesRoot 'Plugins/helpers/PluginHelpers.psm1')
        $script:ModuleFiles.FullName | Should -Contain (Join-Path $script:HygieneModulesRoot 'Providers/AndroidSdkProvider.psm1')
    }

    It 'Tier-1 module set parses from Tier1Modules.ps1 (single source, >= 10 modules)' {
        $script:TierOne.Count | Should -BeGreaterThan 10
        $script:TierOne | Should -Contain 'PathUtils'
        $script:TierOne | Should -Contain 'ErrorHandling'
    }

    It 'Tier-1 list is not inlined in a second place (Orchestrator + gbuild.ps1 share the data file)' {
        # The drift this guards: an inline @('PathUtils',...) copy in either
        # consumer that the other consumer - and this file's own reader above -
        # cannot see. Both must dot-source Tier1Modules.ps1 instead.
        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($pair in @(
            @{ File = 'Orchestrator.psm1'; Root = $script:HygieneModulesRoot },
            @{ File = 'gbuild.ps1'; Root = (Split-Path -Parent $script:HygieneModulesRoot) }
        )) {
            $p = Join-Path $pair.Root $pair.File
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
            $t = Get-Content -LiteralPath $p -Raw -Encoding UTF8
            if ($t -match "foreach\s*\(\s*\$dep\s+in\s+@\(\s*'") { $offenders.Add("$($pair.File): inline Tier-1 foreach list") }
            if ($t -match "@\(\s*'Logging'\s*,\s*'PathUtils'") { $offenders.Add("$($pair.File): inline Tier-1 name list") }
        }
        $orchText = Get-Content -LiteralPath (Join-Path $script:HygieneModulesRoot 'Orchestrator.psm1') -Raw -Encoding UTF8
        $launcherText = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $script:HygieneModulesRoot) 'gbuild.ps1') -Raw -Encoding UTF8
        if ($orchText -notmatch 'Tier1Modules\.ps1') { $offenders.Add('Orchestrator.psm1: does not consume Tier1Modules.ps1') }
        if ($launcherText -notmatch 'Tier1Modules\.ps1') { $offenders.Add('gbuild.ps1: does not consume Tier1Modules.ps1') }
        $offenders | Should -BeNullOrEmpty
    }

    It 'no nested non-global -Force import of a shared module' {
        $violations = New-Object System.Collections.Generic.List[string]
        foreach ($f in $script:ModuleFiles) {
            # -KeepStrings: literal target paths live inside quotes; the
            # stripped form would hide them and misclassify every helper import
            # as variable-target. Start-Job scriptblocks run in an isolated
            # child process and cannot orphan parent-session modules.
            $code = Get-HygieneCodeText -Path $f.FullName -KeepStrings
            # Routed through the shared detector. This gate and the one below used
            # to carry byte-identical private copies of the rule, so both had the
            # same blind spot (a literal `./Foo.psm1` or a `$var` target was
            # classified by the regex, not by what the code means) and a fix to
            # either would not have reached the other.
            foreach ($hit in @(Find-GateNonGlobalForceImports -CodeText $code -FileName $f.Name)) {
                if (-not $hit.IsLiteral) { continue }
                if ($script:TierOne -contains $hit.Target) {
                    $violations.Add(('{0}:{1} nested -Force import of shared module ''{2}'' without -Global' -f $f.Name, $hit.Line, $hit.Target))
                }
            }
        }
        $violations | Should -BeNullOrEmpty
    }

    It 'variable-target non-global -Force imports are explicitly allowlisted' {
        # Static analysis cannot resolve $variables: every variable-target
        # `Import-Module -Force` WITHOUT -Global must be registered here with
        # its safety reason, otherwise the PS 5.1 orphan family can return
        # through a new call site unnoticed.
        $allowed = @{
            'Loader.psm1::Register-Plugins' = 'plugin files only ($p.FullName from Plugins/pluginDirs); Tier-1 name collisions are skipped at runtime by the anti-shadow guard, portable same-name reloads still proceed'
            'DotnetHelpers.psm1::<top-level>' = 'sibling helper ($pluginHelpersPath = helpers/PluginHelpers.psm1); helper modules are never Tier-1/global so nothing can be orphaned'
            'Orchestrator.Targets.ps1::Invoke-GuildChoice' = 'Start-Job scriptblock (background health monitor) runs in an isolated child process; cannot orphan parent-session modules'
        }
        $violations = New-Object System.Collections.Generic.List[string]
        foreach ($f in $script:ModuleFiles) {
            $code = Get-HygieneCodeText -Path $f.FullName -KeepStrings
            $fn = '<top-level>'
            $lines = @($code -split "`n")
            # Map each hit back to its enclosing function so the allowlist key
            # stays File::Function, unchanged from before.
            foreach ($hit in @(Find-GateNonGlobalForceImports -CodeText $code -FileName $f.Name)) {
                for ($k = $hit.Line; $k -ge 1; $k--) {
                    $fm = [regex]::Match($lines[$k - 1], '^\s*function\s+([\w-]+)')
                    if ($fm.Success) { $fn = $fm.Groups[1].Value; break }
                }
                if ($hit.IsLiteral) { continue }
                $key = '{0}::{1}' -f $f.Name, $fn
                if (-not $allowed.ContainsKey($key)) {
                    $violations.Add(('{0}:{1} unregistered variable-target -Force import without -Global (in {2})' -f $f.Name, $hit.Line, $fn))
                }
            }
        }
        $violations | Should -BeNullOrEmpty
    }

    It 'no literal Remove-Module of a shared module' {
        $violations = New-Object System.Collections.Generic.List[string]
        foreach ($f in $script:ModuleFiles) {
            $code = Get-HygieneCodeText -Path $f.FullName
            $idx = 0
            foreach ($ln in ($code -split "`n")) {
                $idx++
                if ($ln -notmatch 'Remove-Module') { continue }
                foreach ($tm in $script:TierOne) {
                    if ($ln -match ('Remove-Module\s+(?:-Name\s+)?[''"]?' + [regex]::Escape($tm) + '[''"]?(\s|$)')) {
                        $violations.Add(('{0}:{1} literal Remove-Module of shared module ''{2}''' -f $f.Name, $idx, $tm))
                    }
                }
            }
        }
        $violations | Should -BeNullOrEmpty
    }

    It 'plugin imports do not orphan core PathUtils commands (chaos regression)' {        Import-Module (Join-Path $script:HygieneModulesRoot 'PathUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
        Import-Module (Join-Path $script:HygieneModulesRoot 'ErrorHandling.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        Import-Module (Join-Path $script:HygieneModulesRoot 'IContract.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        Get-Module ErrorHandling -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $core = @('Invoke-EnsureDirectory', 'Get-ExcludeDirPattern', 'Get-BuildRootDirectory', 'Resolve-BuildRootedPath', 'Test-PathUnderRoots', 'Find-ProjectManifest')
        # Production-faithful trigger: Test-PluginContracts imports every
        # Plugins/*.psm1 exactly like Start-GBuild does before Resolve-BuildSdk.
        if (Get-Command Test-PluginContracts -ErrorAction SilentlyContinue) {
            Test-PluginContracts | Out-Null
        }
        $missingGlobal = @()
        $missingModule = @()
        foreach ($cmd in $core) {
            if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $missingGlobal += $cmd }
            $inEh = & (Get-Module ErrorHandling) { param($n) Get-Command $n -ErrorAction SilentlyContinue } $cmd
            if (-not $inEh) { $missingModule += $cmd }
        }
        $missingGlobal | Should -BeNullOrEmpty
        $missingModule | Should -BeNullOrEmpty
    }

    It 'no NEW inline ProjectRoot/ScriptRoot/CWD root ternary appears outside the registered set' {
        # Get-BuildRootDirectory is the single source for ProjectRoot > ScriptRoot
        # > CWD. Its doc comment registers the KNOWN intentional divergences
        # (report/history roots preferring WorkingDir, Clean preferring $PSScriptRoot,
        # Standalone's ScriptRoot-only emission). A fresh inline ternary anywhere
        # else is drift: it must either call Get-BuildRootDirectory or be registered
        # in PathUtils with justification. This test fails on the new site, not on
        # the registered ones.
        $registered = @(
            'AnomalyDetector.psm1', 'AutoTuner.psm1', 'RootCause.psm1',
            'HealthCheck.psm1', 'Metrics.psm1', 'Siem.psm1', 'Sast.psm1',
            'Clean.psm1', 'Standalone.psm1', 'Deploy.psm1', 'DeployTargets.psm1',
            'Distributed.psm1', 'InfraVerification.psm1', 'Loader.psm1',
            'SharedUtils.psm1', 'CacheProvider.psm1', 'Cache.psm1',
            'AuditLedger.psm1', 'ClusterOrchestrator.psm1', 'ConfigProvider.psm1',
            'SDK.psm1', 'Policy.psm1', 'Preflight.psm1', 'Parallel.psm1',
            'ErrorHandling.psm1', 'SupplyChain.psm1', 'Versioning.psm1',
            'Report.psm1', 'Security.psm1', 'Orchestrator.psm1', 'Environment.psm1',
            'Orchestrator.Config.ps1', 'Orchestrator.Deploy.ps1', 'Orchestrator.Environment.ps1',
            'Orchestrator.Modules.ps1', 'Orchestrator.Pipeline.ps1', 'Orchestrator.Sdk.ps1',
            'Orchestrator.Standalone.ps1', 'Orchestrator.Targets.ps1',
            'PathUtils.psm1', 'publish-artifact.ps1', 'pipeline-diagram.ps1',
            'manage-githooks.ps1', '01-post-build.ps1', '01-env-validation.ps1',
            'sign-gpg.ps1'
        )
        $violations = [System.Collections.Generic.List[string]]::new()
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:HygieneModulesRoot '..') -Recurse -File -Include '*.psm1', '*.ps1' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' -and $_.FullName -notmatch '[\\/]\.git[\\/]' })
        foreach ($f in $files) {
            if ($registered -contains $f.Name) { continue }
            $text = [System.IO.File]::ReadAllText($f.FullName)
            # An inline ternary mentions ProjectRoot AND ScriptRoot AND a CWD source
            # in the same breath without delegating to the canonical.
            if ($text -match 'ProjectRoot' -and $text -match 'ScriptRoot' -and
                ($text -match 'Get-Location' -or $text -match '\$PWD') -and
                $text -notmatch 'Get-BuildRootDirectory') {
                $violations.Add(('{0} has an inline root ternary outside the registered set' -f $f.Name))
            }
        }
        $violations | Should -BeNullOrEmpty
    }
}
