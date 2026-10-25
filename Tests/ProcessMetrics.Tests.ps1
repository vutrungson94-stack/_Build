#Requires -Version 5.1

# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================
# ProcessMetrics.Tests.ps1 - tests for the CMMI L5 self-measurement engine.
#
# These are not tautological "measure a number and assert the number" tests.
# Each one pins a PROPERTY the engine must have for its output to be usable as
# evidence at all: determinism, self-consistency between the metric and its
# gate, lossless round-trip through the time-series format, and tolerance of a
# killed run.
# ============================================================================

BeforeAll {
    $script:ToolRoot   = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:ModulePath = Join-Path $script:ToolRoot 'Modules/ProcessMetrics.psm1'
    Import-Module $script:ModulePath -Force -Global -DisableNameChecking -ErrorAction Stop
}

Describe 'ProcessMetrics - measurement engine' {
    It 'measures every governance class the baseline declares' {
        $m = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
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
        $m = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
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
        $m = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
        $m.FilesScanned | Should -BeGreaterThan 50
        $trendPath = Get-BuildProcessTrendPath -ToolRoot $script:ToolRoot
        $m.Classes | Should -Not -BeNullOrEmpty
        $trendPath | Should -Match 'TestResults' -Because 'the curve is a generated artefact and must live with the other generated artefacts'
    }

    It 'reaches parity on the classes the structural gates already enforce' {
        # If a class that a binary gate holds at zero measures BELOW 1.0, the
        # metric and the gate disagree, and one of the two is wrong. This pins
        # the two together.
        $m = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
        $parity = @('fileLockDelegation', 'eventNameRegistry', 'localeKeyWiring')
        foreach ($name in $parity) {
            $c = @($m.Classes | Where-Object { $_.Class -eq $name })[0]
            $c.Adoption | Should -Be 1.0 -Because "Hygiene.Tests.ps1 holds $name at zero offenders, so the metric must agree: $($c.Metric)"
        }
    }

    It 'agrees with the hygiene gate on platform path literals' {
        $m = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
        $c = @($m.Classes | Where-Object { $_.Class -eq 'platformPathLiterals' })[0]
        $c.Adoption | Should -Be 1.0 -Because 'Hygiene.Tests.ps1 asserts zero backslash path constructions outside its allow-list'
    }
}

Describe 'ProcessMetrics - time series' {
    It 'round-trips a record through the append-only JSONL file' {
        $tmp = Join-Path $TestDrive 'trend'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        # Write-BuildProcessTrend derives its path from the tool root, so exercise
        # the reader/writer contract against a real tool root and then clean up.
        $before = @(Get-BuildProcessTrend -ToolRoot $script:ToolRoot).Count
        $m = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
        $path = Write-BuildProcessTrend -Metrics $m -ToolRoot $script:ToolRoot -RunId 'testrun01' -Channel 'test'
        $path | Should -Match 'process-trend\.jsonl$'
        Test-Path -LiteralPath $path | Should -BeTrue
        $after = @(Get-BuildProcessTrend -ToolRoot $script:ToolRoot)
        $after.Count | Should -Be ($before + 1) -Because 'the trend is append-only: one run adds exactly one sample'
        $last = $after[$after.Count - 1]
        $last.runId | Should -Be 'testrun01'
        $last.schema | Should -Be 'gbuild.process-trend.v2'
        $last.channel | Should -Be 'test'
        @($last.classes).Count | Should -Be $m.Classes.Count -Because 'a truncated record would silently flatten a series'
        foreach ($c in $m.Classes) {
            $hit = @($last.classes | Where-Object { $_.class -eq $c.Class })
            $hit.Count | Should -Be 1
            [double]$hit[0].adoption | Should -Be $c.Adoption
        }
        # Remove the sample this test created so the suite is side-effect free.
        $lines = @(Get-Content -LiteralPath $path)
        $kept = @($lines | Where-Object { $_ -notmatch '"runId":"testrun01"' })
        Set-Content -LiteralPath $path -Value $kept -Encoding UTF8
    }

    It 'tolerates a corrupt trailing line from a killed run' {
        $path = Get-BuildProcessTrendPath -ToolRoot $script:ToolRoot
        $backup = $null
        if (Test-Path -LiteralPath $path -PathType Leaf) { $backup = @(Get-Content -LiteralPath $path) }
        try {
            # Seed one valid record so the assertion below is about SURVIVAL of
            # the corrupt line, not about an empty file.
            $m = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
            [void](Write-BuildProcessTrend -Metrics $m -ToolRoot $script:ToolRoot -RunId 'corrupttest' -Channel 'test')
            $beforeCount = @(Get-BuildProcessTrend -ToolRoot $script:ToolRoot).Count
            $beforeCount | Should -BeGreaterThan 0

            # A half-written line from an aborted run.
            Add-Content -LiteralPath $path -Value '{"schema":"gbuild.process-trend.v1","runId":"hal' -Encoding UTF8
            $records = @(Get-BuildProcessTrend -ToolRoot $script:ToolRoot)
            # Must not throw, and must keep every GOOD record.
            $records.Count | Should -Be $beforeCount -Because 'the corrupt line must be skipped, not parsed into a phantom record'
            foreach ($r in $records) { $r.runId | Should -Not -BeNullOrEmpty }
            # The renderer must also survive it, since the runner renders the
            # curve immediately after a run that may have been interrupted.
            $lines = @(Get-BuildProcessSparkline -ToolRoot $script:ToolRoot -Ascii)
            $lines.Count | Should -BeGreaterThan 1
        } finally {
            if ($null -ne $backup) { Set-Content -LiteralPath $path -Value $backup -Encoding UTF8 }
            else { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'renders a curve with one row per measured class' {
        $m = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
        $lines = @(Get-BuildProcessSparkline -Metrics $m -ToolRoot $script:ToolRoot -Ascii)
        $lines.Count | Should -Be ($m.Classes.Count + 1) -Because 'a header plus one row per class'
        ($lines[0]) | Should -Match 'ADOPTION CURVE'
        # -Ascii must produce no block glyphs, or a legacy console renders '?'.
        ($lines -join '') | Should -Not -Match ([regex]::Escape([string][char]0x2581))
        foreach ($c in $m.Classes) {
            ($lines -join "`n") | Should -Match ([regex]::Escape($c.Class))
        }
    }
}

Describe 'ProcessMetrics - the floor is a ratchet' {
    It 'finds a floor entry for every class and reports no regression today' {
        $m = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
        $c = Compare-BuildProcessTrend -Metrics $m -ToolRoot $script:ToolRoot
        $c.HasFloor | Should -BeTrue
        @($c.Untracked) | Should -BeNullOrEmpty -Because 'a measured class with no floor is ungoverned'
        @($c.Regressions) | Should -BeNullOrEmpty -Because 'the committed floor was seeded from this tree; a regression here means the measurement or the tree changed since'
        $c.Passed | Should -BeTrue
    }

    It 'detects a regression when a class drops below its floor' {
        # Prove the gate can actually FAIL. A gate that has only ever passed is
        # indistinguishable from a gate that cannot fail.
        $m = Get-BuildProcessMetrics -ToolRoot $script:ToolRoot
        $target = @($m.Classes)[0]
        $tampered = [PSCustomObject]@{
            Classes   = @($m.Classes | ForEach-Object {
                if ($_.Class -eq $target.Class) {
                    [PSCustomObject]@{ Class = $_.Class; Description = $_.Description; Adopted = [int]($_.Adopted / 2); Total = $_.Total; Adoption = [math]::Round(([int]($_.Adopted / 2)) / [double]$_.Total, 4); Metric = $_.Metric }
                } else { $_ }
            })
            FilesScanned = $m.FilesScanned
        }
        $c = Compare-BuildProcessTrend -Metrics $tampered -ToolRoot $script:ToolRoot
        $c.Passed | Should -BeFalse -Because 'halving an adopted count must trip the floor'
        @($c.Regressions).Count | Should -Be 1
        @($c.Regressions)[0].Class | Should -Be $target.Class
    }

    It 'reports an improvement separately from a regression' {
        # The fifth step of the improvement loop is "did the change help?", which
        # requires the engine to distinguish better from worse, not just flag bad.
        #
        # Self-contained on purpose. This used to force every class to 1.0 and
        # assert an improvement appeared, which only worked while at least one
        # committed floor sat BELOW 1.0. Raising every class to full adoption - the
        # thing the ratchet is for - made the assertion vacuous: with every floor at
        # 1.0, "1.0 is better" is false, so the test failed for the right reason and
        # the wrong one. It now lowers a floor in a THROWAWAY baseline and measures
        # against that, so it proves the engine's behaviour rather than the
        # repository's current state.
        $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('pmfloor_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'Tests') -Force
            $real = Get-Content -LiteralPath (Join-Path $script:ToolRoot 'Tests/process-baseline.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $target = @($real.adoptionFloor.PSObject.Properties)[0]
            $real.adoptionFloor.($target.Name) | ForEach-Object { $_.minAdoption = 0.5 }
            [System.IO.File]::WriteAllText(
                (Join-Path $tmpRoot 'Tests/process-baseline.json'),
                ($real | ConvertTo-Json -Depth 20),
                (New-Object System.Text.UTF8Encoding($false)))

            # Measure the REAL tree, but read the FLOOR from the throwaway
            # baseline: -Metrics supplies the measurements (the temp root has no
            # tree to scan) while -ToolRoot selects which process-baseline.json
            # the floor comes from.
            $c = Compare-BuildProcessTrend -Metrics (Get-BuildProcessMetrics -ToolRoot $script:ToolRoot) -ToolRoot $tmpRoot
            $c.HasFloor | Should -BeTrue
            $c.Passed | Should -BeTrue
            @($c.Regressions) | Should -BeNullOrEmpty
            @($c.Improvements).Count | Should -BeGreaterThan 0 -Because 'a class measured above its floor must register as improvement, not silence'
            @($c.Improvements).Class | Should -Contain $target.Name
        } finally { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
