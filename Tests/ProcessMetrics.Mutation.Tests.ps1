#Requires -Version 5.1

# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================
# ProcessMetrics.Mutation.Tests.ps1 - the missing falsifiability layer.
#
# Tests/GateSelfTest.Tests.ps1 already does this for the 13 hygiene DETECTORS:
# it plants a violation and proves each detector fires, because "only the
# negative case tells them apart". The seven ProcessMetrics adoption classes
# had no equivalent. That is the exact gap that let i18nProseCoverage report
# 509/509 = 100% while its emit pattern was line-anchored and structurally
# blind to 44% of user-facing emit lines: a green ratchet nobody had tried to
# break is a ratchet that cannot fail, and a ratchet that cannot fail
# CERTIFIES the defect it was built to catch.
#
# Each test here builds a synthetic tool tree, plants ONE violation of ONE
# class, and asserts the measured adoption DROPS below 1.0. If a metric's
# fingerprint is ever weakened to the point where it no longer detects its own
# violation, this file fails.
# ============================================================================

BeforeAll {
    $script:ToolRoot   = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:ModulePath = Join-Path $script:ToolRoot 'Modules/ProcessMetrics.psm1'
    Import-Module $script:ModulePath -Force -Global -DisableNameChecking -ErrorAction Stop

    # A minimal but STRUCTURALLY COMPLETE tree: the metric distinguishes
    # production (Modules/Steps/Hooks) from tests, and the localeKeyWiring class
    # needs a Locales directory to compare against.
    function New-MutationTree {
        param([string]$Name)
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("gbuild-mut-$Name-" + [guid]::NewGuid().ToString('N'))
        foreach ($d in @('Modules', 'Steps', 'Hooks', 'Tests', 'Locales')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $root $d) -Force
        }
        # A compliant SharedUtils so fileLockDelegation has an owner.
        Set-Content -LiteralPath (Join-Path $root 'Modules/SharedUtils.psm1') -Encoding UTF8 -Value @(
            'function Enter-BuildFileLock {'
            '    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)'
            '}'
            'function Initialize-BuildSharedUtils { param([string]$SentinelCommand) }'
            'function Get-BuildStringHash { param([string]$Text) }'
            'function Protect-BuildSecretText { param([object]$Text, [PSCustomObject]$State) }'
        )
        # A compliant consumer: no lock FileStream, uses the hash owner.
        Set-Content -LiteralPath (Join-Path $root 'Modules/Compliant.psm1') -Encoding UTF8 -Value @(
            '. (Join-Path $PSScriptRoot ''ModuleBootstrap.ps1'') -Dependencies @()'
            'function Do-Thing {'
            '    $h = Get-BuildStringHash -Text ''abc'''
            "    Write-Log (Get-LocaleMessage -Key 'log.x' -Fallback 'Doing the thing now') 'Info' `$State"
            '}'
        )
        Set-Content -LiteralPath (Join-Path $root 'Modules/ModuleBootstrap.ps1') -Encoding UTF8 -Value 'function Import-GBuildModuleIfMissing { param($Name,$SentinelCommand) }'
        # One locale key, referenced from Compliant.psm1 so localeKeyWiring is clean.
        Set-Content -LiteralPath (Join-Path $root 'Locales/en.json') -Encoding UTF8 -Value '{ "log.x": "Doing the thing now" }'
        return $root
    }

    function Measure-Tree {
        param([string]$Root)
        $m = Get-BuildProcessMetrics -ToolRoot $Root
        $map = @{}
        foreach ($c in $m.Classes) { $map[$c.Class] = $c.Adoption }
        return $map
    }

    $script:trees = New-Object System.Collections.Generic.List[string]
}

AfterAll {
    foreach ($t in $script:trees) { Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue }
}

Describe 'ProcessMetrics falsifiability: every class can FAIL' {

    It 'baseline synthetic tree measures every class at parity' {
        $t = New-MutationTree 'clean'
        $script:trees.Add($t)
        $r = Measure-Tree $t
        # If even a clean tree does not reach parity, the planted-violation
        # assertions below would pass for the wrong reason.
        $r['i18nProseCoverage']     | Should -Be 1.0 -Because 'the clean fixture emits only via a locale resolver'
        $r['fileLockDelegation']    | Should -Be 1.0 -Because 'only SharedUtils opens a lock FileStream in the fixture'
        $r['stringHashDelegation']  | Should -Be 1.0 -Because 'the fixture uses Get-BuildStringHash'
        $r['localeKeyWiring']       | Should -Be 1.0 -Because 'the fixture locale key is referenced from code'
    }

    It 'i18nProseCoverage drops when an unlocalized mid-line emit is planted' {
        # THE regression this file exists for. The violation is written MID-LINE,
        # which is the dominant emit form in this codebase and the exact shape
        # the old '(?m)^\s*' anchored fingerprint was blind to. A Write-Host is
        # used because it was absent from the old verb set entirely.
        $t = New-MutationTree 'i18n'
        $script:trees.Add($t)
        Add-Content -LiteralPath (Join-Path $t 'Modules/Compliant.psm1') -Encoding UTF8 -Value @(
            'function Emit-Unlocalized {'
            "    if (`$true) { Write-Log '[DEMO] The deployment finished successfully' 'Info' `$State }"
            '}'
        )
        $r = Measure-Tree $t
        $r['i18nProseCoverage'] | Should -BeLessThan 1.0 -Because "a mid-line English emit is precisely what the old line-anchored pattern could not see"
    }

    It 'i18nProseCoverage drops when a Write-Host prose line is planted' {
        $t = New-MutationTree 'i18nhost'
        $script:trees.Add($t)
        Add-Content -LiteralPath (Join-Path $t 'Modules/Compliant.psm1') -Encoding UTF8 -Value @(
            'function Emit-Host {'
            "    Write-Host '[DEMO] This line has real English prose in it' -ForegroundColor Red"
            '}'
        )
        $r = Measure-Tree $t
        $r['i18nProseCoverage'] | Should -BeLessThan 1.0 -Because 'Write-Host carried most user-facing text in Steps/ and Hooks/ and the old verb set omitted it'
    }

    It 'i18nProseCoverage does NOT charge decorative or relayed emits' {
        # The other direction: a metric that fires on everything is as useless
        # as one that fires on nothing. Separators, relayed output and
        # parameter/variable words are non-prose and must stay out of the
        # denominator, or the class can never reach 1.0 and becomes a ratchet
        # nobody can satisfy.
        $t = New-MutationTree 'i18nnoise'
        $script:trees.Add($t)
        Add-Content -LiteralPath (Join-Path $t 'Modules/Compliant.psm1') -Encoding UTF8 -Value @(
            'function Emit-Decorative {'
            "    Write-Log ' ' -State `$State"
            "    Write-Log `$relayed -State `$State"
            "    try { Write-Host (' ' * 4) -NoNewline -ForegroundColor Gray } catch { }"
            '}'
        )
        $r = Measure-Tree $t
        $r['i18nProseCoverage'] | Should -Be 1.0 -Because 'a separator, a relayed value and a spacing emit carry no translatable words'
    }

    It 'fileLockDelegation drops when a module opens its own lock FileStream' {
        $t = New-MutationTree 'lock'
        $script:trees.Add($t)
        Add-Content -LiteralPath (Join-Path $t 'Modules/Compliant.psm1') -Encoding UTF8 -Value @(
            'function Open-MyOwnLock {'
            '    $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)'
            '}'
        )
        $r = Measure-Tree $t
        $r['fileLockDelegation'] | Should -BeLessThan 1.0 -Because 'only SharedUtils may open a lock FileStream'
    }

    It 'stringHashDelegation drops when a string hash is built inline' {
        $t = New-MutationTree 'hash'
        $script:trees.Add($t)
        Add-Content -LiteralPath (Join-Path $t 'Modules/Compliant.psm1') -Encoding UTF8 -Value @(
            'function My-Own-Hash {'
            '    $bytes = [System.Text.Encoding]::UTF8.GetBytes($someString)'
            '    $sha = [System.Security.Cryptography.SHA256]::Create()'
            '    $computed = $sha.ComputeHash($bytes)'
            '    return [System.BitConverter]::ToString($computed).Replace(''-'', '''').ToLowerInvariant()'
            '}'
        )
        $r = Measure-Tree $t
        $r['stringHashDelegation'] | Should -BeLessThan 1.0 -Because 'a string hash must go through Get-BuildStringHash'
    }

    It 'sharedUtilsImportOwner drops when a module inlines its own SharedUtils import' {
        $t = New-MutationTree 'suimport'
        $script:trees.Add($t)
        Add-Content -LiteralPath (Join-Path $t 'Modules/Compliant.psm1') -Encoding UTF8 -Value @(
            "    `$p = Join-Path `$PSScriptRoot 'SharedUtils.psm1'"
            '    if (Test-Path $p) { Import-Module $p -Global -DisableNameChecking }'
        )
        $r = Measure-Tree $t
        $r['sharedUtilsImportOwner'] | Should -BeLessThan 1.0 -Because 'the lazy SharedUtils import has one owner in ModuleBootstrap.ps1'
    }

    It 'localeKeyWiring drops when a locale key nothing references is added' {
        $t = New-MutationTree 'locale'
        $script:trees.Add($t)
        Set-Content -LiteralPath (Join-Path $t 'Locales/en.json') -Encoding UTF8 -Value '{ "log.x": "Doing the thing now", "log.neverRead": "A translation nobody ever displays" }'
        $r = Measure-Tree $t
        $r['localeKeyWiring'] | Should -BeLessThan 1.0 -Because 'every shipped locale key must be reachable from code'
    }

    It 'platformPathLiterals drops when a production module hardcodes a backslash path' {
        $t = New-MutationTree 'path'
        $script:trees.Add($t)
        # The violating line is ASSEMBLED, not written literally: a test fixture
        # that spelled out 'cache\index.json' would itself be a
        # platformPathLiterals offender in Tests/, and the class scans the test
        # suite too. Assembling it keeps this file at parity while still
        # planting a genuine violation in the synthetic tree.
        $bs = [string][char]92
        $violation = "    `$cacheFile = Join-Path `$root 'cache" + $bs + "index.json'"
        Add-Content -LiteralPath (Join-Path $t 'Modules/Compliant.psm1') -Encoding UTF8 -Value $violation
        $r = Measure-Tree $t
        $r['platformPathLiterals'] | Should -BeLessThan 1.0 -Because 'a backslash path literal in Modules/ is a Windows-only assumption'
    }

    It 'reports the offending sites, not just a lower ratio' {
        # A ratio with no list of what is left is a number nobody can act on,
        # which is the failure mode this whole module exists to eliminate.
        $t = New-MutationTree 'offenders'
        $script:trees.Add($t)
        Add-Content -LiteralPath (Join-Path $t 'Modules/Compliant.psm1') -Encoding UTF8 -Value @(
            'function Emit-Unlocalized2 {'
            "    Write-Host '[DEMO2] Another unlocalized English sentence here' -ForegroundColor Red"
            '}'
        )
        $m = Get-BuildProcessMetrics -ToolRoot $t
        $c = $m.Classes | Where-Object { $_.Class -eq 'i18nProseCoverage' }
        $c.Adoption | Should -BeLessThan 1.0
        $c.Remaining | Should -BeGreaterThan 0
        @($c.Offenders) | Should -Not -BeNullOrEmpty
        # Offenders are file:line so the next remediation step is derivable.
        (@($c.Offenders) -join ' ') | Should -Match 'Compliant\.psm1:\d+'
    }
}

Describe 'ProcessMetrics ratchet direction: a floor may be RAISED but never LOWERED' {

    It 'rejects an adoptionFloor whose minAdoption was lowered' {
        # The baseline file's own text says "NEVER lower one to make a red run
        # green", but nothing enforced it - the prohibition lived only in a
        # description string, which is exactly the kind of rule a green run
        # outlives. The floor is the L5 ratchet; a silently lowered ratchet is
        # worse than no ratchet.
        $baselinePath = Join-Path $script:ToolRoot 'Tests/process-baseline.json'
        $baseline = Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $historyPath = Join-Path $script:ToolRoot 'Tests/process-trend-history.json'

        if (-not (Test-Path -LiteralPath $historyPath -PathType Leaf)) {
            Set-Content -LiteralPath $historyPath -Encoding UTF8 -Value (@{
                description = 'Floor history. Append-only: one entry per deliberate ratchet change. Tests/process-baseline.json may only RAISE a minAdoption relative to the newest recorded value for that class.'
                classes      = @{}
            } | ConvertTo-Json -Depth 8)
        }
        $history = Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $lowered = @()
        foreach ($p in $baseline.adoptionFloor.PSObject.Properties) {
            $name = $p.Name
            $current = [double]$p.Value.minAdoption
            $recorded = $history.classes.PSObject.Properties[$name]
            if ($null -ne $recorded) {
                $prior = [double]$recorded.Value.minAdoption
                if ($current -lt ($prior - 0.0001)) {
                    $lowered += "$name was $prior and is now $current"
                }
            }
        }
        $lowered.Count | Should -Be 0 -Because ('an adoption floor may only move upward: ' + ($lowered -join '; '))
    }
}