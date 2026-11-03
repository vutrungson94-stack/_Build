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

Describe 'ProcessMetrics - control limits (SPC gate)' {
    BeforeAll {
        function New-SyntheticTrend {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][double[]]$AdoptionAlpha,
                [datetime]$Start = (Get-Date '2026-10-01T00:00:00Z')
            )
            $dir = Join-Path $Root 'Tests/TestResults'
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir 'process-trend.jsonl'
            $lines = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $AdoptionAlpha.Count; $i++) {
                $a = [double]$AdoptionAlpha[$i]
                $at = $Start.AddMinutes(5 * $i)
                $rec = [ordered]@{
                    schema = 'gbuild.process-trend.v2'; runId = ('s{0:D3}' -f $i); recordedAtUtc = $at.ToString('o'); channel = 'test'; projectType = 'unknown'; host = 'test'
                    psVersion = '7.0.0'; os = 'test'; filesScanned = 10; classCount = 1; classesAtParity = $(if ($a -ge 1.0) { 1 } else { 0 }); meanAdoption = $a; totalRemaining = 0; atParity = ($a -ge 1.0)
                    classes = @([ordered]@{ class = 'alpha'; adopted = [int]([math]::Round($a * 10)); total = 10; adoption = $a; remaining = (10 - [int]([math]::Round($a * 10))) })
                }
                $lines.Add(([PSCustomObject]$rec | ConvertTo-Json -Compress -Depth 6)) | Out-Null
            }
            [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
            return $path
        }
        function New-SyntheticMetrics {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Classes
            )
            $list = @()
            foreach ($c in $Classes) { $list += [PSCustomObject]$c }
            return [PSCustomObject]@{
                ToolRoot = 'synthetic'; FilesScanned = 10; ClassCount = $list.Count
                ClassesAtParity = @($list | Where-Object { $_.Adoption -ge 1.0 }).Count
                MeanAdoption = 1.0; TotalRemaining = 0; AtParity = ($list.Count -gt 0 -and @($list | Where-Object { $_.Adoption -lt 1.0 }).Count -eq 0)
                Classes = $list
            }
        }
        function New-SyntheticLedger {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][string]$Json
            )
            $dir = Join-Path $Root 'Tests'
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir 'qpm-ledger.json'
            [System.IO.File]::WriteAllText($path, $Json, (New-Object System.Text.UTF8Encoding($false)))
            return $path
        }
        $script:MinimalLedger = '{ "$schema": "./qpm-ledger.schema.json", "description": "test", "entries": [ { "id": "QPM-2026-001", "detectedAtUtc": "2026-10-01T00:00:00+00:00", "resolvedAtUtc": "2026-10-01T00:05:00+00:00", "class": "escaped-defect", "severity": "high", "scope": "synthetic", "summary": "synthetic entry for test" } ] }'
    }

    It 'fails when the current run falls below the LCL computed from history (downward shift)' {
        $tmp = Join-Path $TestDrive 'ooc'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        [void](New-SyntheticTrend -Root $tmp -AdoptionAlpha (@(1.0) * 20))
        $m = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=7; Total=10; Adoption=0.7; Remaining=3 })
        $r = Compare-BuildProcessControl -Metrics $m -ToolRoot $tmp -Window 50 -MinSamples 12
        $r.HasLimits | Should -BeTrue
        $r.Passed | Should -BeFalse -Because 'a run below the effective LCL is a process shift down'
        @($r.OutOfControl).Class | Should -Contain 'alpha'
    }

    It 'keeps a single slipped item in control in a perfect process; two fail' {
        $tmp = Join-Path $TestDrive 'quantum'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        [void](New-SyntheticTrend -Root $tmp -AdoptionAlpha (@(1.0) * 20))
        $one = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=9; Total=10; Adoption=0.9; Remaining=1 })
        $r1 = Compare-BuildProcessControl -Metrics $one -ToolRoot $tmp
        $r1.Passed | Should -BeTrue -Because 'one item in a perfect process is noise, not a signal'
        $two = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=8; Total=10; Adoption=0.8; Remaining=2 })
        $r2 = Compare-BuildProcessControl -Metrics $two -ToolRoot $tmp
        $r2.Passed | Should -BeFalse -Because 'two items below a zero-variance mean is a signal'
    }

    It 'passes when the current run stays inside the limits' {
        $tmp = Join-Path $TestDrive 'inside'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        [void](New-SyntheticTrend -Root $tmp -AdoptionAlpha (@(1.0, 0.9, 1.0, 0.9, 1.0, 0.9, 1.0, 0.9, 1.0, 0.9, 1.0, 0.9)))
        $m = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=10; Total=10; Adoption=1.0; Remaining=0 })
        $r = Compare-BuildProcessControl -Metrics $m -ToolRoot $tmp
        $r.Passed | Should -BeTrue
    }

    It 'fails open without a verdict when history is thinner than MinSamples' {
        $tmp = Join-Path $TestDrive 'thin'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        [void](New-SyntheticTrend -Root $tmp -AdoptionAlpha (@(1.0) * 3))
        $m = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=2; Total=10; Adoption=0.2; Remaining=8 })
        $r = Compare-BuildProcessControl -Metrics $m -ToolRoot $tmp -MinSamples 12
        $r.HasLimits | Should -BeFalse
        $r.Passed | Should -BeTrue -Because 'a thin history never fails a build'
    }

    It 'fails open when the trend file does not exist' {
        $tmp = Join-Path $TestDrive 'empty'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $m = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=1; Total=10; Adoption=0.1; Remaining=9 })
        $r = Compare-BuildProcessControl -Metrics $m -ToolRoot $tmp
        $r.HasLimits | Should -BeFalse
        $r.Passed | Should -BeTrue
    }

    It 'reports a class missing from history as insufficient instead of failing it' {
        $tmp = Join-Path $TestDrive 'missingclass'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        [void](New-SyntheticTrend -Root $tmp -AdoptionAlpha (@(1.0) * 15))
        $m = New-SyntheticMetrics -Classes @(
            @{ Class='alpha'; Metric='m'; Description='d'; Adopted=10; Total=10; Adoption=1.0; Remaining=0 }
            @{ Class='omega'; Metric='m'; Description='d'; Adopted=0; Total=10; Adoption=0.0; Remaining=10 }
        )
        $r = Compare-BuildProcessControl -Metrics $m -ToolRoot $tmp
        $r.Passed | Should -BeTrue -Because 'a never-seen class cannot be out of control against its own history'
        @($r.Insufficient) | Should -Contain 'omega'
    }

    It 'reports an above-UCL run without failing it' {
        $tmp = Join-Path $TestDrive 'ucl'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        [void](New-SyntheticTrend -Root $tmp -AdoptionAlpha (@(0.8,0.8,0.8,0.8,0.8,0.8,0.8,0.8,0.8,0.9) * 2))
        $m = New-SyntheticMetrics -Classes @(@{ Class='alpha'; Metric='m'; Description='d'; Adopted=10; Total=10; Adoption=1.0; Remaining=0 })
        $r = Compare-BuildProcessControl -Metrics $m -ToolRoot $tmp
        $r.Passed | Should -BeTrue -Because 'above the UCL is improvement, never a failure'
        @($r.Classes | Where-Object { $_.Class -eq 'alpha' })[0].Notes | Should -Match 'above UCL'
    }
}

Describe 'ProcessMetrics - QPM measures' {
    BeforeAll {
        function Write-QpmTrend {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][bool[]]$Parity, [datetime]$Start = (Get-Date '2026-10-01T00:00:00Z'))
            $dir = Join-Path $Root 'Tests/TestResults'
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir 'process-trend.jsonl'
            $lines = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $Parity.Count; $i++) {
                $p = [bool]$Parity[$i]
                $at = $Start.AddMinutes(10 * $i)
                $rec = [ordered]@{
                    schema = 'gbuild.process-trend.v2'; runId = ('q{0:D3}' -f $i); recordedAtUtc = $at.ToString('o'); channel = 'test'; projectType = 'unknown'; host = 'test'
                    filesScanned = 10; classCount = 1; classesAtParity = $(if ($p) { 1 } else { 0 }); meanAdoption = $(if ($p) { 1.0 } else { 0.5 }); atParity = $p
                    classes = @([ordered]@{ class = 'alpha'; adopted = $(if ($p) { 10 } else { 5 }); total = 10; adoption = $(if ($p) { 1.0 } else { 0.5 }); remaining = $(if ($p) { 0 } else { 5 }) })
                }
                $lines.Add(([PSCustomObject]$rec | ConvertTo-Json -Compress -Depth 6)) | Out-Null
            }
            [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
        }
        $script:QpmLedger = '{ "$schema": "./qpm-ledger.schema.json", "description": "test", "entries": [ { "id": "QPM-2026-001", "detectedAtUtc": "2026-10-01T00:00:00+00:00", "resolvedAtUtc": "2026-10-01T00:10:00+00:00", "class": "escaped-defect", "severity": "high", "scope": "synthetic", "summary": "synthetic escaped defect" }, { "id": "QPM-2026-002", "detectedAtUtc": "2026-10-02T00:00:00+00:00", "class": "near-miss", "severity": "low", "scope": "synthetic", "summary": "synthetic near miss" } ] }'
    }

    It 'computes change failure rate and MTTR from a failing streak that recovers' {
        $tmp = Join-Path $TestDrive 'qpm'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        Write-QpmTrend -Root $tmp -Parity (@($true,$true,$true) + @($false,$false) + @($true,$true,$true,$true,$true,$true,$true,$true,$true,$true,$true,$true,$true,$true,$true))
        $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'Tests') -Force
        [System.IO.File]::WriteAllText((Join-Path $tmp 'Tests/qpm-ledger.json'), $script:QpmLedger, (New-Object System.Text.UTF8Encoding($false)))
        $q = Get-BuildQpmMeasures -ToolRoot $tmp -WindowSamples 50
        $q.Samples | Should -Be 20
        $q.Failures | Should -Be 2
        $q.ChangeFailureRate | Should -Be 0.1
        $q.RecoveryIncidents | Should -Be 1 -Because 'one failing streak recovers at the first passing sample'
        $q.MeanRecoveryTimeSeconds | Should -BeGreaterThan 0
        $q.EscapedDefects | Should -Be 1
        $q.DataQuality | Should -Be 'measured'
    }

    It 'reports insufficient history and no fabricated numbers on an empty trend' {
        $tmp = Join-Path $TestDrive 'qpmthin'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'Tests') -Force
        [System.IO.File]::WriteAllText((Join-Path $tmp 'Tests/qpm-ledger.json'), $script:QpmLedger, (New-Object System.Text.UTF8Encoding($false)))
        $q = Get-BuildQpmMeasures -ToolRoot $tmp -WindowSamples 50
        $q.Samples | Should -Be 0
        $q.ChangeFailureRate | Should -BeNullOrEmpty
        $q.DataQuality | Should -Be 'insufficient-history'
        $q.LedgerValid | Should -BeTrue
    }

    It 'flags an invalid ledger with readable errors' {
        $tmp = Join-Path $TestDrive 'qpmbad'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'Tests') -Force
        $bad = '{ "$schema": "x", "description": "bad", "entries": [ { "id": "WRONG-1", "detectedAtUtc": "not-a-date", "class": "nope", "severity": "nope" }, { "id": "WRONG-1", "detectedAtUtc": "2026-10-01T00:00:00+00:00", "class": "escaped-defect", "severity": "high", "scope": "s", "summary": "s" } ] }'
        [System.IO.File]::WriteAllText((Join-Path $tmp 'Tests/qpm-ledger.json'), $bad, (New-Object System.Text.UTF8Encoding($false)))
        $l = Test-BuildQpmLedger -ToolRoot $tmp
        $l.Passed | Should -BeFalse
        @($l.Errors).Count | Should -BeGreaterThan 3
    }

    It 'the shipped escaped-defect ledger validates' {
        $l = Test-BuildQpmLedger -ToolRoot $script:ToolRoot
        $l.Passed | Should -BeTrue -Because "the ledger is evidence; it must never drift: $(@($l.Errors) -join '; ')"
        @($l.Entries).Count | Should -BeGreaterOrEqual 2
    }

    It 'the committed baseline carries the QPM ceiling as a ratchet' {
        $b = Get-Content -LiteralPath (Join-Path $script:ToolRoot 'Tests/process-baseline.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $b.qpm | Should -Not -BeNullOrEmpty
        [double]$b.qpm.maxChangeFailureRate | Should -BeGreaterThan 0
        [double]$b.qpm.maxChangeFailureRate | Should -BeLessOrEqual 1
        $b.qpm.windowSamples | Should -BeGreaterOrEqual 20
        $b.qpm.note | Should -Match 'never raise'
    }
}
