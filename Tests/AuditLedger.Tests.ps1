Set-StrictMode -Version 1.0

$modulePath = Join-Path $PSScriptRoot '../Modules/AuditLedger.psm1'
Import-Module $modulePath -Force -DisableNameChecking

Describe 'AuditLedger' {
    BeforeAll {
        $script:LedgerTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuildledgertest_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:LedgerTmp -Force | Out-Null
        # Explicit unsigned-ledger acceptance: this fixture exercises the hash
        # chain, not signatures (L5 fail-closed requires the opt-out to be
        # explicit - see 'Signing fail-closed' Describe below).
        $alCfg = [PSCustomObject]@{ enabled = $true; backend = 'ledger'; signing = [PSCustomObject]@{ enabled = $false } }
        $script:LedgerState = [PSCustomObject]@{
            ProjectRoot   = $script:LedgerTmp
            ScriptRoot    = (Join-Path $PSScriptRoot '..')
            TenantId      = 'default'
            CorrelationId = 'ledger-test'
            BuildConfig   = [PSCustomObject]@{ security = [PSCustomObject]@{ auditLedger = $alCfg } }
        }
        Initialize-AuditLedger -State $script:LedgerState
    }

    AfterAll {
        Remove-Item -Path $script:LedgerTmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Writes entries and verifies the hash chain' {
        Write-AuditLedgerEntry -State $script:LedgerState -Entry @{ Type = 'RBAC'; Action = 'test:allow'; Allowed = $true; Permission = 'build' } | Out-Null
        Write-AuditLedgerEntry -State $script:LedgerState -Entry @{ Type = 'RBAC'; Action = 'test:deny'; Allowed = $false; Permission = 'deploy' } | Out-Null
        $v = Test-AuditLedger -State $script:LedgerState -FullChain
        $v.Valid | Should -BeTrue
        $v.VerifiedEntries | Should -Be 2
        $v.MerkleRoot | Should -Not -BeNullOrEmpty
    }

    It 'Hashes PSCustomObject and hashtable entries identically' {
        $h = @{ Sequence = 7; Timestamp = 't'; Type = 'X'; Action = 'a'; Allowed = $true; User = 'u'; Roles = 'r'; Permission = 'p'; Resource = 'res'; CorrelationId = 'c'; TenantId = 't'; Detail = 'd' }
        $o = [PSCustomObject]$h.Clone()
        Get-EntryHash -Entry $h -PreviousHash 'prev' | Should -Be (Get-EntryHash -Entry $o -PreviousHash 'prev')
    }
}

Describe 'AuditLedger - integrity regressions' {
    It 'includes the signature in the integrity input' {
        $a = [ordered]@{ Sequence = 1; Timestamp = 't'; Type = 'X'; Action = 'a'; Allowed = $true; Signature = 'first'; SignAlgorithm = 'RSA-SHA256' }
        $b = [ordered]@{ Sequence = 1; Timestamp = 't'; Type = 'X'; Action = 'a'; Allowed = $true; Signature = 'second'; SignAlgorithm = 'RSA-SHA256' }
        (Get-EntryHash -Entry $a) | Should -Not -Be (Get-EntryHash -Entry $b)
    }
    It 'reports filesystem storage honestly rather than claiming WORM' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('worm-status-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $state = [PSCustomObject]@{ ProjectRoot = $tmp; TenantId = 'default'; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{ auditLedger = [PSCustomObject]@{ enabled = $true; backend = 'file'; file = [PSCustomObject]@{ path = 'ledger.jsonl'; immutable = $true }; signing = [PSCustomObject]@{ enabled = $false } } } } }
            Initialize-AuditLedger -State $state
            $status = Get-AuditLedgerWormStatus -State $state
            $status.Enforced | Should -BeFalse
            $status.Honest | Should -BeTrue
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'AuditLedger - L5 signing fail-closed' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../Modules/AuditLedger.psm1') -Force -DisableNameChecking
    }
    It 'Throws when ledger is enabled with signing on but no key' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuildledgertest_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $st = [PSCustomObject]@{
            ProjectRoot   = $tmp
            ScriptRoot    = (Join-Path $PSScriptRoot '..')
            TenantId      = 'default'
            CorrelationId = 'ledger-failclosed'
            BuildConfig   = [PSCustomObject]@{ security = [PSCustomObject]@{ auditLedger = [PSCustomObject]@{ enabled = $true; backend = 'ledger' } } }
        }
        try {
            { Initialize-AuditLedger -State $st } | Should -Throw -ExpectedMessage '*signing*key*'
        } finally {
            Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Get-AuditLedgerRoot throws instead of anchoring the ledger on the CWD' {
        # Both ledger-file call sites used to fall back to the process CWD (and
        # dropped ScriptRoot entirely), silently splitting the tamper-evident
        # chain across whatever directory the launcher ran from.
        { Get-AuditLedgerRoot -State ([PSCustomObject]@{}) } | Should -Throw
        { Get-AuditLedgerRoot -State $null } | Should -Throw
        Get-AuditLedgerRoot -State ([PSCustomObject]@{ ProjectRoot = $TestDrive }) | Should -Be $TestDrive
    }
}

Describe 'AuditLedger - torn-tail repair (fail-closed writes)' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../Modules/AuditLedger.psm1') -Force -DisableNameChecking
    }

    It 'repairs a torn tail instead of forking the chain with a duplicate sequence' {
        # A crash mid-append leaves a partial last line. The old Sync kept stale
        # EntryCount/CurrentHash, so the next write reused a sequence number and
        # chained from the wrong hash. Repair must truncate the torn tail and
        # resync from the last VALID entry.
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuildledgertorn_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $st = [PSCustomObject]@{
                ProjectRoot   = $tmp
                ScriptRoot    = (Join-Path $PSScriptRoot '..')
                TenantId      = 'default'
                CorrelationId = 'ledger-torn'
                BuildConfig   = [PSCustomObject]@{ security = [PSCustomObject]@{ auditLedger = [PSCustomObject]@{ enabled = $true; backend = 'file'; signing = [PSCustomObject]@{ enabled = $false } } } }
            }
            Initialize-AuditLedger -State $st
            Write-AuditLedgerEntry -State $st -Entry @{ Type = 'T'; Action = 'one' } | Out-Null
            Write-AuditLedgerEntry -State $st -Entry @{ Type = 'T'; Action = 'two' } | Out-Null
            $path = Get-LedgerPath -State $st
            # Simulate the crash: append a partial line.
            Add-Content -LiteralPath $path -Value '{"Sequence":3,"Timestamp":"2026-01-01T00:00:00","Type":"T","Action":"par' -NoNewline -Encoding UTF8
            $repaired = Repair-LedgerTornTail -Path $path -State $st
            $repaired | Should -Not -BeNullOrEmpty
            [int]$repaired.Sequence | Should -Be 2
            # Torn bytes are gone; the next write continues at 3, not 1.
            Write-AuditLedgerEntry -State $st -Entry @{ Type = 'T'; Action = 'three' } | Out-Null
            $v = Test-AuditLedger -State $st -FullChain
            $v.Valid | Should -BeTrue
            $v.VerifiedEntries | Should -Be 3
        } finally {
            Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses to sign a partial anchor when leaf collection is incomplete' {
        # A checkpoint written after a partial read carried merkleRoot='' and
        # silently disabled rollback detection. Now the checkpoint is skipped
        # instead of signed hollow.
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuildledgeranchor_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $st = [PSCustomObject]@{
                ProjectRoot   = $tmp
                ScriptRoot    = (Join-Path $PSScriptRoot '..')
                TenantId      = 'default'
                CorrelationId = 'ledger-anchor'
                BuildConfig   = [PSCustomObject]@{ security = [PSCustomObject]@{ auditLedger = [PSCustomObject]@{ enabled = $true; backend = 'file'; signing = [PSCustomObject]@{ enabled = $false }; ledger = [PSCustomObject]@{ checkpointInterval = 1 } } } }
            }
            Initialize-AuditLedger -State $st
            Write-AuditLedgerEntry -State $st -Entry @{ Type = 'T'; Action = 'one' } | Out-Null
            $path = Get-LedgerPath -State $st
            Add-Content -LiteralPath $path -Value 'NOT-JSON-GARBAGE' -Encoding UTF8
            # Checkpoint with a garbage line present must be skipped, not hollow.
            Save-AuditLedgerCheckpoint -State $st -Sequence 1
            $anchor = $null
            try { $anchor = Get-AuditLedgerAnchor -State $st } catch { $anchor = $null }
            $anchorPresent = [bool]($anchor -and $anchor.Present)
            $anchorPresent | Should -BeFalse -Because 'a partial leaf set must not produce a signed anchor'
        } finally {
            Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
