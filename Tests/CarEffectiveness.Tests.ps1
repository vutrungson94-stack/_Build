#Requires -Version 5.1
#Requires -Module Pester
# CAR closure-effectiveness gate for this repository.
#
# The core runner opens a CAR per failed scope into TestResults/car
# (ephemeral, gitignored). That is the generation half. This gate asks the
# next question an L5 process must answer: did the fix actually hold?
# A Resolved record in Tests/car-ledger.json must carry verified evidence of
# at least 2 consecutive executions of the affected scope that stayed green
# AFTER the fix sha - plus mttrMinutes == closedAt - openedAt, and a fix
# commit you can name. A promise is not evidence; the ledger records the
# evidence. Open records still answer to the same 14-day staleness budget
# enforced by Tests/Hygiene.Tests.ps1.
#
# This is NOT an escape-rate/MTTR SLO for consumers of this tool - there is
# no consumer-side incident feed, and inventing a target would be aspiration,
# not SLO. The internal objective-derived SLO lives in
# Tests/process-baseline.json .slo (see Docs/Escape-Rate-SLO.md).
# The falsifiability fixtures below plant records that break each rule and
# assert the validator reports them, so the gate fails when it should.
#
# The committed ledger is empty as of 2026-11-16 - zero records is a true
# statement about this repository, not a missing mechanism.
Set-StrictMode -Version 1.0

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:LedgerPath = Join-Path $script:Root 'Tests/car-ledger.json'

    $script:Validate = {
        param([string]$Path, [DateTime]$Now, [int]$MaxOpenDays)

        $findings = New-Object System.Collections.Generic.List[string]
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @('car ledger is missing') }
        $doc = $null
        try { $doc = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
        catch { return @('car ledger is not valid JSON') }
        if ([string]$doc.schema -ne 'gbuild.car-ledger.v1') { $findings.Add('unexpected ledger schema') }

        $seen = @{}
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $parse = { param($s) $d = [DateTimeOffset]::MinValue; if ([DateTimeOffset]::TryParse([string]$s, $inv, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d } ; return $null }
        foreach ($rec in @($doc.records)) {
            $id = [string]$rec.id
            if ([string]::IsNullOrWhiteSpace($id)) { $findings.Add('record without id'); continue }
            if ($seen.ContainsKey($id)) { $findings.Add("duplicate record id: $id") } else { $seen[$id] = $true }

            foreach ($req in @('openedAt', 'severity', 'scope', 'rootCause', 'summary')) {
                if ([string]::IsNullOrWhiteSpace([string]$rec.$req)) { $findings.Add("${id}: missing ${req}") }
            }
            $opened = & $parse $rec.openedAt
            if (-not $opened) { $findings.Add("${id}: openedAt is not a date") }

            if ([string]$rec.severity -notmatch '^SEV[1-4]$') { $findings.Add("${id}: invalid severity '$([string]$rec.severity)'") }
            $fix = [string]$rec.fixCommit
            if ($fix -notmatch '^[0-9a-f]{7,40}$') { $findings.Add("${id}: fixCommit is not a commit sha ('$fix')") }
            if ($rec.PSObject.Properties.Name -notcontains 'escaped') { $findings.Add("${id}: missing escaped") }

            $status = [string]$rec.status
            if ($status -eq 'Open') {
                if ($opened -and ($Now - $opened.DateTime).TotalDays -gt $MaxOpenDays) { $findings.Add("${id}: open longer than $MaxOpenDays days") }
                continue
            }
            if ($status -ne 'Resolved') { $findings.Add("${id}: unknown status '$status'"); continue }

            $closed = & $parse $rec.closedAt
            if (-not $closed) { $findings.Add("${id}: closedAt missing/invalid"); continue }
            if ($opened -and $closed -lt $opened) { $findings.Add("${id}: closedAt before openedAt") }

            if ($rec.PSObject.Properties.Name -notcontains 'mttrMinutes') {
                $findings.Add("${id}: resolved without mttrMinutes")
            } else {
                $expected = [int][math]::Round(($closed - $opened).TotalMinutes)
                if ([int]$rec.mttrMinutes -ne $expected) { $findings.Add("${id}: mttrMinutes $([int]$rec.mttrMinutes) does not match openedAt..closedAt ($expected)") }
            }
            if (@($rec.verifiedRunIds).Count -lt 2) { $findings.Add("${id}: resolved with fewer than 2 verified green executions after the fix") }
            if ([int]$rec.verifiedConsecutiveGreen -lt 2) { $findings.Add("${id}: verifiedConsecutiveGreen below 2") }
        }
        return @($findings)
    }
}

Describe 'CAR closure-effectiveness ledger (Tests/car-ledger.json)' {
    It 'committed ledger passes the effectiveness gate' {
        $findings = @(& $script:Validate $script:LedgerPath ([DateTime]::UtcNow) 14)
        if ($findings.Count -gt 0) { $findings | ForEach-Object { Write-Host "EFFECTIVENESS: $_" } }
        $findings.Count | Should -Be 0
    }

    It 'every committed Resolved record reconciles mttrMinutes against openedAt..closedAt (trivially true at zero records, binding once they exist)' {
        $doc = Get-Content -LiteralPath $script:LedgerPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        foreach ($rec in @($doc.records | Where-Object { $_.status -eq 'Resolved' })) {
            $opened = [DateTimeOffset]::Parse([string]$rec.openedAt, $inv, [System.Globalization.DateTimeStyles]::AssumeUniversal)
            $closed = [DateTimeOffset]::Parse([string]$rec.closedAt, $inv, [System.Globalization.DateTimeStyles]::AssumeUniversal)
            [int][math]::Round(($closed - $opened).TotalMinutes) | Should -Be ([int]$rec.mttrMinutes)
        }
        $true | Should -BeTrue
    }

    It 'fails loudly on a Resolved record missing post-fix verification (falsifiability)' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-car-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $junk = @{
                schema = 'gbuild.car-ledger.v1'
                records = @(
                    @{ id = 'x-1'; openedAt = '2026-11-16T00:00:00Z'; closedAt = '2026-11-16T00:10:00Z'; status = 'Resolved'; severity = 'SEV2'; scope = 's'; escaped = $false; rootCause = 'r'; fixCommit = 'abc1234'; summary = 'x'; verifiedRunIds = @('run-1'); verifiedConsecutiveGreen = 1; mttrMinutes = 10 }
                )
            } | ConvertTo-Json -Depth 5
            Set-Content -LiteralPath $tmp -Value $junk -Encoding UTF8
            $findings = @(& $script:Validate $tmp ([DateTime]::UtcNow) 14)
            $findings.Count | Should -BeGreaterThan 0
            (($findings -join "`n")) | Should -Match 'verified green executions'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails loudly on mttrMinutes mismatch (falsifiability)' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-car-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $junk = @{
                schema = 'gbuild.car-ledger.v1'
                records = @(
                    @{ id = 'x-2'; openedAt = '2026-11-16T00:00:00Z'; closedAt = '2026-11-16T00:10:00Z'; status = 'Resolved'; severity = 'SEV2'; scope = 's'; escaped = $false; rootCause = 'r'; fixCommit = 'abc1234'; summary = 'x'; verifiedRunIds = @('run-1', 'run-2'); verifiedConsecutiveGreen = 2; mttrMinutes = 999 }
                )
            } | ConvertTo-Json -Depth 5
            Set-Content -LiteralPath $tmp -Value $junk -Encoding UTF8
            $findings = @(& $script:Validate $tmp ([DateTime]::UtcNow) 14)
            (($findings -join "`n")) | Should -Match 'mttrMinutes'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails loudly on a stale Open record older than the budget (falsifiability)' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-car-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $junk = @{
                schema = 'gbuild.car-ledger.v1'
                records = @(
                    @{ id = 'x-3'; openedAt = '2026-10-01T00:00:00Z'; status = 'Open'; severity = 'SEV3'; scope = 's'; escaped = $false; rootCause = 'r'; fixCommit = 'abc1234'; summary = 'stale open' }
                )
            } | ConvertTo-Json -Depth 5
            Set-Content -LiteralPath $tmp -Value $junk -Encoding UTF8
            $findings = @(& $script:Validate $tmp ([DateTime]::UtcNow) 14)
            (($findings -join "`n")) | Should -Match 'open longer than 14 days'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects an invalid severity (falsifiability)' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-car-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $junk = @{
                schema = 'gbuild.car-ledger.v1'
                records = @(
                    @{ id = 'x-4'; openedAt = '2026-11-16T00:00:00Z'; status = 'Open'; severity = 'SEV9'; scope = 's'; escaped = $false; rootCause = 'r'; fixCommit = 'abc1234'; summary = 'bad severity' }
                )
            } | ConvertTo-Json -Depth 5
            Set-Content -LiteralPath $tmp -Value $junk -Encoding UTF8
            $findings = @(& $script:Validate $tmp ([DateTime]::UtcNow) 14)
            (($findings -join "`n")) | Should -Match 'invalid severity'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

