#Requires -Version 5.1

# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================
# FlakeLedger.Tests.ps1 - the L5 flake ledger, falsifiability harness.
#
# qpm-ledger.json records defects that reached a green state (escapes).
# This file gates Tests/flake-ledger.json, which records tests that FAILED a
# scope and passed on re-run. An untracked flake looks like a crash that
# self-healed; the ledger makes it visible and fixable.
#
# THE PROBLEM THIS SOLVES: reruns in the CI diagnose step print a scope green
# next to a red shard verdict. Without a ledger, nobody writes down that the
# test is intermittent, so the next failure costs the same re-run detective
# work and the intermittent test lives on. A flake that reaches green is an
# escaped defect in the TEST.
#
# THE GATE (deterministic, small, falsifiable):
#   1. The committed ledger must validate: every entry carries the fields the
#      diagnostic depends on (which scope, which test, what verdict, why).
#   2. No entry may stay status=open longer than maxOpenDays (from the ledger).
#   3. At most maxNewPerRolling30Days entries may appear in any rolling
#      30-day window ending today. A spike means tests are flaking faster
#      than they are being fixed.
#   4. The gate itself must fail: the fixtures below prove each rule detects
#      the violation it exists for. A detector that never fires is dead weight.
# ============================================================================

Set-StrictMode -Version 1.0

Describe 'Flake ledger (Tests/flake-ledger.json)' {
    BeforeAll {
        $script:LedgerPath = Join-Path $PSScriptRoot 'flake-ledger.json'
        $script:FixedFields = @('id', 'date', 'scope', 'test', 'detectedIn', 'firstOutcome', 'rerunOutcome', 'rootCause', 'fix', 'status')
        $script:StatusSet   = @('fixed', 'accepted', 'open')
        $script:OutcomeSet  = @('pass', 'fail', 'killed', 'unknown')
        $script:Fixtures    = New-Object System.Collections.Generic.List[string]

        function Get-FlakeLedgerFindings {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$Path,
                [DateTime]$Now = [DateTime]::UtcNow
            )
            $findings = New-Object System.Collections.Generic.List[string]
            $raw = $null
            try { $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
            catch { return @('ledger file is not valid JSON: ' + $_.Exception.Message) }
            if ($null -eq $raw) { return @('ledger file parsed to nothing') }

            foreach ($key in @('maxOpenDays', 'maxNewPerRolling30Days', 'entries')) {
                if ($raw.PSObject.Properties.Name -notcontains $key) { $findings.Add("ledger root is missing '$key'") }
            }
            if ($findings.Count -gt 0) { return @($findings) }

            $maxOpenDays = 30
            if (-not [int]::TryParse([string]$raw.maxOpenDays, [ref]$maxOpenDays) -or $maxOpenDays -le 0) {
                $findings.Add("maxOpenDays must be a positive integer (got '$($raw.maxOpenDays)')")
                $maxOpenDays = 30
            }
            $maxNew = 4
            if (-not [int]::TryParse([string]$raw.maxNewPerRolling30Days, [ref]$maxNew) -or $maxNew -le 0) {
                $findings.Add("maxNewPerRolling30Days must be a positive integer (got '$($raw.maxNewPerRolling30Days)')")
                $maxNew = 4
            }

            $entries = @($raw.entries)
            $i = 0
            foreach ($e in $entries) {
                $i++
                $props = @{}
                foreach ($p in $e.PSObject.Properties) { $props[$p.Name] = $p.Value }
                $label = if ($props.ContainsKey('id') -and $props['id']) { [string]$props['id'] } else { "entry #$i" }
                foreach ($f in $script:FixedFields) {
                    if (-not $props.ContainsKey($f)) { $findings.Add("${label}: missing required field '$f'"); continue }
                    $v = $props[$f]
                    if ($null -eq $v) { $findings.Add("${label}: field '$f' is null") }
                    elseif ($v -isnot [System.Array] -and [string]::IsNullOrWhiteSpace([string]$v)) { $findings.Add("${label}: field '$f' is empty") }
                }
                $dateValue = $null
                if ($props.ContainsKey('date') -and $props['date']) {
                    try { $dateValue = [DateTime]::Parse([string]$props['date'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime() }
                    catch { $findings.Add("${label}: date '$($props['date'])' is not parseable") }
                }
                if ($props.ContainsKey('status') -and $props['status'] -and ($script:StatusSet -notcontains [string]$props['status'])) {
                    $findings.Add("${label}: status '$($props['status'])' is not one of: $($script:StatusSet -join ', ')")
                }
                foreach ($k in @('firstOutcome', 'rerunOutcome')) {
                    if ($props.ContainsKey($k) -and $props[$k] -and ($script:OutcomeSet -notcontains [string]$props[$k])) {
                        $findings.Add("${label}: $k '$($props[$k])' is not one of: $($script:OutcomeSet -join ', ')")
                    }
                }
                if ($dateValue -and $dateValue -gt $now) {
                    $findings.Add("${label}: date $($props['date']) is in the future")
                }
                if ($dateValue -and $props.ContainsKey('status') -and [string]$props['status'] -eq 'open') {
                    $age = ($now - $dateValue).TotalDays
                    if ($age -gt $maxOpenDays) { $findings.Add(("{0}: open for {1:F0} day(s) (limit {2}) - an untriaged flake" -f $label, $age, $maxOpenDays)) }
                }
            }

            # Rolling 30-day window: a spike means flakiness is growing faster
            # than it is being triaged, i.e. process noise is compounding.
            $cutoff = $now.AddDays(-30)
            $inWindow = 0
            foreach ($e in $entries) {
                $d = $null
                try { $d = [DateTime]::Parse([string]$e.date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime() } catch { $d = $null }
                if ($d -and $d -ge $cutoff) { $inWindow++ }
            }
            if ($inWindow -gt $maxNew) {
                $findings.Add(("{0} flakes in the last 30 days (limit {1}) - flakiness is compounding faster than triage" -f $inWindow, $maxNew))
            }

            return @($findings)
        }

        function New-FlakeLedgerFixture {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$Name,
                [Parameter(Mandatory)]$Document
            )
            $path = Join-Path ([System.IO.Path]::GetTempPath()) ("gbuild-flake-" + $Name + '-' + [guid]::NewGuid().ToString('N') + '.json')
            $Document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
            return $path
        }
    }

    AfterAll {
        foreach ($f in $script:Fixtures) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    It 'the committed ledger passes the gate' {
        Test-Path -LiteralPath $script:LedgerPath -PathType Leaf | Should -BeTrue -Because 'the ledger is the artefact the gate reads; a fresh checkout needs it'
        $findings = @(Get-FlakeLedgerFindings -Path $script:LedgerPath -Now ([DateTime]::UtcNow))
        ($findings -join '; ') | Should -BeNullOrEmpty -Because 'the committed ledger must validate clean; edit the ledger, not this test'
    }

    It 'detects an entry missing a required field' {
        $bad = [ordered]@{
            maxOpenDays = 30
            maxNewPerRolling30Days = 4
            entries = @([ordered]@{ id = 'x'; date = '2026-11-10'; scope = 'PathUtils'; test = 't'; detectedIn = 'd'; firstOutcome = 'fail'; rerunOutcome = 'pass'; rootCause = 'r'; fix = ''; status = 'fixed' })
        }
        $f = New-FlakeLedgerFixture -Name 'missing-fix' -Document $bad
        $script:Fixtures.Add($f)
        $findings = @(Get-FlakeLedgerFindings -Path $f -Now ([DateTime]::UtcNow))
        ($findings -join '; ') | Should -Match 'fix' -Because 'the ledger exists so a flake is actionable; a field-less entry is not'
    }

    It 'flags an open entry that has outlived the budget' {
        $stale = ([DateTime]::UtcNow.AddDays(-60)).ToString('yyyy-MM-dd')
        $bad = [ordered]@{
            maxOpenDays = 30
            maxNewPerRolling30Days = 4
            entries = @([ordered]@{ id = 'old'; date = $stale; scope = 'Runner'; test = 'some test'; detectedIn = 'd'; firstOutcome = 'fail'; rerunOutcome = 'pass'; rootCause = 'unknown'; fix = 'none yet'; status = 'open' })
        }
        $f = New-FlakeLedgerFixture -Name 'stale-open' -Document $bad
        $script:Fixtures.Add($f)
        $findings = @(Get-FlakeLedgerFindings -Path $f -Now ([DateTime]::UtcNow))
        ($findings -join '; ') | Should -Match 'open' -Because 'an intermittent test nobody fixed for 60 days is exactly what the ledger exists to catch'
    }

    It 'flags a month with more flakes than the budget' {
        $today = [DateTime]::UtcNow
        $entries = 1..6 | ForEach-Object {
            [ordered]@{
                id = "burst-$_"; date = $today.AddDays(-1 * $_).ToString('yyyy-MM-dd')
                scope = 'Runner'; test = "t$_"; detectedIn = 'd'
                firstOutcome = 'fail'; rerunOutcome = 'pass'; rootCause = 'r'; fix = 'f'; status = 'fixed'
            }
        }
        $bad = [ordered]@{ maxOpenDays = 30; maxNewPerRolling30Days = 4; entries = @($entries) }
        $f = New-FlakeLedgerFixture -Name 'burst' -Document $bad
        $script:Fixtures.Add($f)
        $findings = @(Get-FlakeLedgerFindings -Path $f -Now ([DateTime]::UtcNow))
        ($findings -join '; ') | Should -Match '30 days' -Because 'a growing flake rate means unstable process, not unlucky runs'
    }

    It 'a clean synthetic ledger passes' {
        $good = [ordered]@{
            maxOpenDays = 30
            maxNewPerRolling30Days = 4
            entries = @(
                [ordered]@{ id = 'ok-1'; date = [DateTime]::UtcNow.ToString('yyyy-MM-dd'); scope = 'PathUtils'; test = 't'; detectedIn = 'd'; firstOutcome = 'fail'; rerunOutcome = 'pass'; rootCause = 'r'; fix = 'f'; status = 'fixed' }
            )
        }
        $f = New-FlakeLedgerFixture -Name 'clean' -Document $good
        $script:Fixtures.Add($f)
        $findings = @(Get-FlakeLedgerFindings -Path $f -Now ([DateTime]::UtcNow))
        ($findings -join '; ') | Should -BeNullOrEmpty
    }
}
