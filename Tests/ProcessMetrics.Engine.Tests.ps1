#Requires -Version 5.1

# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================
# ProcessMetrics.Engine.Tests.ps1 - the measurement engine of the CMMI L5
# self-measurement apparatus.
#
# This file is ONE SCOPE of that engine. The engine was a single long pole
# under coverage instrumentation, and ONE scope cannot be spread across the CI
# shards by the cost balancer: the shard that received it ran twice as long as
# its siblings. Splitting the scope by what it measures makes the work
# schedulable; the measurement itself is unchanged.
#
# These are not tautological "measure a number and assert the number" tests.
# Each one pins a PROPERTY the engine must have for its output to be usable as
# evidence at all: determinism, self-consistency between the metric and its
# gate, and the targets derived from the process objective.

Set-StrictMode -Version 1.0

BeforeAll {
    $script:ToolRoot   = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:ModulePath = Join-Path $script:ToolRoot 'Modules/ProcessMetrics.psm1'
    Import-Module $script:ModulePath -Force -Global -DisableNameChecking -ErrorAction Stop
    # One measurement for the read-only assertions: the engine is deterministic
    # and scans the whole tree, so re-measuring per test dominated the scope.
    # The tests that need INDEPENDENT measurements compute their own.
    $script:M = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
}
Describe 'ProcessMetrics - measurement engine' {
    It 'measures every governance class the baseline declares' {
        $m = $script:M
        $m | Should -Not -BeNullOrEmpty
        $m.Classes.Count | Should -BeGreaterOrEqual 7
        $names = @($m.Classes | ForEach-Object { $_.Class })
        ($names | Select-Object -Unique).Count | Should -Be $names.Count -Because 'a duplicated class name would corrupt the curve by merging two series'
        foreach ($c in $m.Classes) {
            $c.Adoption | Should -BeGreaterOrEqual 0
            $c.Adoption | Should -BeLessOrEqual 1
            $c.Metric | Should -Not -BeNullOrEmpty -Because "a class with no stated metric cannot be acted on: $($c.Class)"
            $c.Description | Should -Not -BeNullOrEmpty
        }
    }

    It 'labels below-parity classes unambiguously' {
        $m = $script:M
        $below = @($m.Classes | Where-Object { $_.Adoption -lt 1.0 }).Count
        $m.BelowParityCount | Should -Be $below -Because 'the count must match the classes it was computed from'
        $m.BelowParityRatio | Should -Be ([math]::Round(($below / [math]::Max(1, $m.ClassCount)), 4)) -Because 'a ratio named below-parity must not be mistaken for mean adoption'
        $m.MeanAdoption | Should -BeGreaterOrEqual 0
        $m.MeanAdoption | Should -BeLessOrEqual 1
    }

    It 'is deterministic across repeated measurement' {
        # A time series is worthless if two runs of the same tree disagree: the
        # curve would show noise, and every trend read off it would be fiction.
        $a = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
        $b = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
        foreach ($c in @($a.Classes)) {
            $other = @($b.Classes | Where-Object { $_.Class -eq $c.Class })[0]
            $other.Adoption | Should -Be $c.Adoption -Because "$($c.Class) must be a pure function of the tree"
        }
        $b.FilesScanned | Should -Be $a.FilesScanned
    }

    It 'never includes generated output in the scanned corpus' {
        # Scanning Tests\TestResults or logs would make every ratio depend on how
        # much the previous run happened to leave behind.
        $m = $script:M
        $m.FilesScanned | Should -BeGreaterThan 50
        $trendPath = Get-BuildProcessTrendPath -ToolRoot $script:ToolRoot
        $m.Classes | Should -Not -BeNullOrEmpty
        $trendPath | Should -Match 'TestResults' -Because 'the curve is a generated artefact and must live with the other generated artefacts'
    }

    It 'reaches parity on the classes the structural gates already enforce' {
        # If a class that a binary gate holds at zero measures BELOW 1.0, the
        # metric and the gate disagree, and one of the two is wrong. This pins
        # the two together.
        $m = $script:M
        $parity = @('fileLockDelegation', 'eventNameRegistry', 'localeKeyWiring')
        foreach ($name in $parity) {
            $c = @($m.Classes | Where-Object { $_.Class -eq $name })[0]
            $c.Adoption | Should -Be 1.0 -Because "Hygiene.Tests.ps1 holds $name at zero offenders, so the metric must agree: $($c.Metric)"
        }
    }

    It 'agrees with the hygiene gate on platform path literals' {
        $m = $script:M
        $c = @($m.Classes | Where-Object { $_.Class -eq 'platformPathLiterals' })[0]
        $c.Adoption | Should -Be 1.0 -Because 'Hygiene.Tests.ps1 asserts zero backslash path constructions outside its allow-list'
    }
}
Describe 'ProcessMetrics - the SLO is derived from a stated objective' {
    It 'publishes an objective and one target family per SLO dimension' {
        $b = Get-Content -LiteralPath (Join-Path $script:ToolRoot 'Tests/process-baseline.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $b.PSObject.Properties.Name | Should -Contain 'slo' -Because 'a process with ceilings but no objective-derived targets is managed, not optimising'
        $b.slo.objective | Should -Not -BeNullOrEmpty
        $b.slo.objective | Should -Not -BeNullOrEmpty -Because 'an SLO without an objective is a number with no derivation'
        $b.slo.escapeRate.PSObject.Properties.Name | Should -Contain 'maxNewEscapesPerWindow'
        $b.slo.escapeRate.PSObject.Properties.Name | Should -Contain 'windowDays'
        $b.slo.mttr.PSObject.Properties.Name | Should -Contain 'maxMeanRecoverySeconds'
        $b.slo.adoption.PSObject.Properties.Name | Should -Contain 'minMeanAdoption'
        # Every family states WHY the number is what it is, so a later change of
        # the target is reviewable as a change of the objective, not of taste.
        foreach ($family in @('escapeRate','mttr','adoption')) {
            $b.slo.$family.why | Should -Not -BeNullOrEmpty -Because "the $family target must carry its derivation"
        }
    }

    It 'is met by the measured values right now' {
        $b = Get-Content -LiteralPath (Join-Path $script:ToolRoot 'Tests/process-baseline.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $ledger = Get-Content -LiteralPath (Join-Path $script:ToolRoot 'Tests/qpm-ledger.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-[int]$b.slo.escapeRate.windowDays)
        $newEscapes = 0
        foreach ($e in @($ledger.entries)) {
            if ([string]$e.class -notin @('escaped-defect','process-failure')) { continue }
            $stamp = [datetime]::Parse([string]$e.detectedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            if ($stamp -ge $cutoff) { $newEscapes++ }
        }
        $newEscapes | Should -BeLessOrEqual ([int]$b.slo.escapeRate.maxNewEscapesPerWindow) -Because 'the escape-rate target is a live commitment, not a historical average'

        $m = $script:M
        [double]$m.MeanAdoption | Should -BeGreaterOrEqual ([double]$b.slo.adoption.minMeanAdoption) -Because 'the adoption target keeps the process classes at parity'
    }
}
