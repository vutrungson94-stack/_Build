#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    L5 minimal roadmap: OPP control limits, fleet summary, CAR ledger,
    OPM pilot gate, transparency log, external plugin roots.
.DESCRIPTION
    One scope per roadmap pillar, all against temp dirs only. Every function
    under test is referenced here AND from production (same-module wiring),
    so the dead-export gate stays green without baseline changes.
#>

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe 'L5 Minimal: OPP control limits' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'ProcessMetrics.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'computes mean with UCL above and LCL below it' {
        $limits = Get-ProcessControlLimits -Values @(10, 11, 10, 11, 10) -Sigma 3
        $limits.Count | Should -Be 5
        $limits.Mean | Should -BeGreaterThan 10
        $limits.UCL | Should -BeGreaterThan $limits.Mean
        $limits.LCL | Should -BeLessThan $limits.Mean
    }

    It 'returns null without enough history (fail-open)' {
        Get-ProcessControlLimits -Values @(10) | Should -BeNullOrEmpty
        Get-ProcessControlLimits -Values @() | Should -BeNullOrEmpty
    }

    It 'flags out-of-control values and passes in-control ones' {
        $limits = Get-ProcessControlLimits -Values @(10, 10, 10, 10, 10, 10) -Sigma 3
        (Test-ProcessInControl -Value 10 -Limits $limits) | Should -BeTrue
        (Test-ProcessInControl -Value 999 -Limits $limits) | Should -BeFalse
        (Test-ProcessInControl -Value 999 -Limits $null) | Should -BeTrue
    }

    It 'summarizes a fleet of trend records with limits' {
        $recs = @(
            [PSCustomObject]@{ meanAdoption = 0.9; atParity = $true },
            [PSCustomObject]@{ meanAdoption = 0.8; atParity = $false }
        )
        $s = Get-FleetSLOSummary -Records $recs
        $s.Projects | Should -Be 2
        $s.AtParity | Should -Be 1
        $s.Limits.Count | Should -Be 2
        $s.PerType.unknown.Projects | Should -Be 2
    }

    It 'splits the fleet summary by project type when present' {
        $recs = @(
            [PSCustomObject]@{ meanAdoption = 1.0; atParity = $true; projectType = 'Web' },
            [PSCustomObject]@{ meanAdoption = 0.5; atParity = $false; projectType = 'Node' }
        )
        $s = Get-FleetSLOSummary -Records $recs
        $s.PerType.Web.Projects | Should -Be 1
        $s.PerType.Node.MeanAdoption | Should -Be 0.5
    }

    It 'returns a zero summary for empty input' {
        $s = Get-FleetSLOSummary -Records @()
        $s.Projects | Should -Be 0
        $s.AtParity | Should -Be 0
    }
}

Describe 'L5 Minimal: CAR ledger' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'RootCause.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:carTemp = New-IntegrationTempDir
        $global:carHist = Join-Path $global:carTemp 'rc.jsonl'
        $global:carState = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ rootCause = [PSCustomObject]@{ enabled = $true; historyPath = $global:carHist } }; WorkingDir = $global:carTemp }
    }

    It 'builds a record with severity and Open status' {
        $r = New-CARRecord -Category 'PortConflict' -Confidence 0.9 -Severity 'High' -Suggestion 'free the port' -State $global:carState
        $r.Schema | Should -Be 'car.record.v1'
        $r.Severity | Should -Be 'High'
        $r.Status | Should -Be 'Open'
        $r.Id.Length | Should -Be 32
    }

    It 'normalizes an unknown severity to Medium' {
        (New-CARRecord -Severity 'bogus').Severity | Should -Be 'Medium'
    }

    It 'writes a record and closes it with evidence' {
        $rec = New-CARRecord -Category 'DiskFull' -Confidence 0.95 -Severity 'Critical' -State $global:carState
        (Write-CARRecord -Record $rec -State $global:carState) | Should -BeTrue
        (Confirm-CARClosure -Id $rec.Id -Evidence 'freed 10GB' -State $global:carState) | Should -BeTrue
        $carPath = Resolve-CARPath -State $global:carState
        $last = Get-Content -LiteralPath $carPath -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
        $last.Status | Should -Be 'Closed'
        $last.Id | Should -Be $rec.Id
    }

    It 'returns false when closing an unknown id' {
        (Confirm-CARClosure -Id 'deadbeefdeadbeefdeadbeefdeadbeef' -Evidence 'x' -State $global:carState) | Should -BeFalse
    }
}

Describe 'L5 Minimal: OPM pilot gate' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'AutoTuner.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:pilotTemp = New-IntegrationTempDir
        $global:pilotHist = Join-Path $global:pilotTemp 'at.jsonl'
        $global:pilotState = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ autoTune = [PSCustomObject]@{ enabled = $true; historyPath = $global:pilotHist } }; WorkingDir = $global:pilotTemp }
    }

    It 'allows apply when no proposal exists (grandfather)' {
        (Test-AutoTunePilotApproved -State $global:pilotState) | Should -BeTrue
    }

    It 'blocks apply while a proposal is pending and allows after approval' {
        $prop = New-AutoTuneProposal -Changes @{ 'build.timeoutMinutes' = 30 } -State $global:pilotState -PilotScope 'pilot'
        $prop.Status | Should -Be 'Proposed'
        (Test-AutoTunePilotApproved -State $global:pilotState) | Should -BeFalse
        (Test-AutoTunePilotApproved -State $global:pilotState -ProposalId $prop.Id) | Should -BeFalse
        (Approve-AutoTuneProposal -Id $prop.Id -Decision 'Approved' -Evidence 'pilot green' -State $global:pilotState) | Should -BeTrue
        (Test-AutoTunePilotApproved -State $global:pilotState) | Should -BeTrue
        (Test-AutoTunePilotApproved -State $global:pilotState -ProposalId $prop.Id) | Should -BeTrue
    }

    It 'returns false when approving an unknown id' {
        (Approve-AutoTuneProposal -Id 'deadbeefdeadbeefdeadbeefdeadbeef' -State $global:pilotState) | Should -BeFalse
    }
}

Describe 'L5 Minimal: transparency log' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SupplyChain.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:trTemp = New-IntegrationTempDir
        $global:trState = [PSCustomObject]@{ ProjectRoot = $global:trTemp; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{} } }
        $global:trStmt = [PSCustomObject]@{ _type = 'https://in-toto.io/Statement/v0.1'; subject = @(); predicateType = 'https://slsa.dev/provenance/v0.2' }
    }

    It 'appends chained entries that link to each other' {
        (Write-TransparencyLogEntry -Statement $global:trStmt -State $global:trState) | Should -BeTrue
        (Write-TransparencyLogEntry -Statement $global:trStmt -State $global:trState) | Should -BeTrue
        $logPath = Resolve-TransparencyLogPath -State $global:trState
        $lines = @(Get-Content -LiteralPath $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 2
        $first = $lines[0] | ConvertFrom-Json
        $second = $lines[1] | ConvertFrom-Json
        $first.prevHash | Should -Be 'GENESIS'
        $second.prevHash | Should -Be $first.entryHash
        $second.index | Should -Be 1
    }

    It 'returns false for an unreachable report directory' {
        $bad = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{} } }
        (Write-TransparencyLogEntry -Statement $global:trStmt -State $bad) | Should -BeFalse
    }
}

Describe 'L5 Minimal: external plugin roots' {    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Loader.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'returns empty when the environment provides no path' {
        $old = [System.Environment]::GetEnvironmentVariable('GBUILD_PLUGIN_PATH')
        try {
            [System.Environment]::SetEnvironmentVariable('GBUILD_PLUGIN_PATH', $null)
            @(Get-ExternalPluginRoots).Count | Should -Be 0
        } finally {
            if ($null -ne $old) { [System.Environment]::SetEnvironmentVariable('GBUILD_PLUGIN_PATH', $old) }
        }
    }

    It 'resolves an existing dir and skips missing ones' {
        $d = New-IntegrationTempDir
        $missing = Join-Path $d 'nope'
        $sep = [System.IO.Path]::PathSeparator
        $old = [System.Environment]::GetEnvironmentVariable('GBUILD_PLUGIN_PATH')
        try {
            [System.Environment]::SetEnvironmentVariable('GBUILD_PLUGIN_PATH', ($d + $sep + $missing))
            $roots = @(Get-ExternalPluginRoots)
            $roots.Count | Should -Be 1
            $roots[0] | Should -Be ([System.IO.Path]::GetFullPath($d))
        } finally {
            if ($null -ne $old) { [System.Environment]::SetEnvironmentVariable('GBUILD_PLUGIN_PATH', $old) }
            else { [System.Environment]::SetEnvironmentVariable('GBUILD_PLUGIN_PATH', $null) }
        }
    }
}

Describe 'L5 Extended: trend v2 project type' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'ProcessMetrics.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:v2Temp = New-IntegrationTempDir
    }

    It 'records an explicit project type with the v2 schema' {
        $m = [PSCustomObject]@{ FilesScanned = 1; ClassCount = 0; ClassesAtParity = 0; MeanAdoption = 1.0; TotalRemaining = 0; AtParity = $true; Classes = @() }
        $p = Write-BuildProcessTrend -Metrics $m -ToolRoot $global:v2Temp -RunId 'v2type01' -Channel 'test' -ProjectType 'Web'
        $rec = Get-Content -LiteralPath $p -Encoding UTF8 | Where-Object { $_ -match '"runId":"v2type01"' } | Select-Object -First 1 | ConvertFrom-Json
        $rec.schema | Should -Be 'gbuild.process-trend.v2'
        $rec.projectType | Should -Be 'Web'
    }

    It 'falls back to unknown when the tree has no detectable language' {
        $m = [PSCustomObject]@{ FilesScanned = 1; ClassCount = 0; ClassesAtParity = 0; MeanAdoption = 1.0; TotalRemaining = 0; AtParity = $true; Classes = @() }
        $p = Write-BuildProcessTrend -Metrics $m -ToolRoot $global:v2Temp -RunId 'v2type02' -Channel 'test'
        $rec = Get-Content -LiteralPath $p -Encoding UTF8 | Where-Object { $_ -match '"runId":"v2type02"' } | Select-Object -First 1 | ConvertFrom-Json
        $rec.projectType | Should -Not -BeNullOrEmpty
    }

    It 'publishes a fleet SLO report artifact' {
        $st = [PSCustomObject]@{ ProjectRoot = $global:v2Temp; BuildConfig = [PSCustomObject]@{} }
        $recs = @([PSCustomObject]@{ meanAdoption = 1.0; atParity = $true })
        $out = Publish-FleetSLOSummary -Records $recs -State $st
        Test-Path -LiteralPath $out -PathType Leaf | Should -BeTrue
        $doc = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
        $doc.schema | Should -Be 'gbuild.fleet-slo.v1'
        $doc.summary.Projects | Should -Be 1
    }

    It 'returns empty when the report directory is undeterminable' {
        (Publish-FleetSLOSummary -Records @() -State $null) | Should -BeNullOrEmpty
    }
}

Describe 'L5 Extended: toolchain hermeticity' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Preflight.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:toolRoot = Split-Path -Parent $global:GBuildModuleRoot
    }

    It 'detects the digest-pinned Dockerfile' {
        $h = Test-ToolchainHermetic -ToolRoot $global:toolRoot
        $h.DockerfilePinned | Should -BeTrue
    }

    It 'reports the vendored analyzer drift instead of hiding it' {
        $h = Test-ToolchainHermetic -ToolRoot $global:toolRoot
        $h.VendoredToolsOk | Should -BeFalse
        $h.Hermetic | Should -BeFalse
        ($h.Reasons -join ' ') | Should -Match 'PSScriptAnalyzer'
    }

    It 'fails closed on a tool root without a Dockerfile' {
        $d = New-IntegrationTempDir
        $h = Test-ToolchainHermetic -ToolRoot $d
        $h.Hermetic | Should -BeFalse
        $h.DockerfilePinned | Should -BeFalse
    }

    It 'surfaces an advisory entry from preflight without failing the build' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $state = [PSCustomObject]@{
                BuildConfig = [PSCustomObject]@{
                    build = [PSCustomObject]@{ preflight = [PSCustomObject]@{ checkSyntax = $false; checkNetwork = $false; checkDiskSpace = $false; checkManifest = $false } }
                    health = [PSCustomObject]@{ endpoints = @() }
                }
            }
            $r = Invoke-PreflightValidation -State $state -ProjectDir $tmpDir
            $r.Passed | Should -BeTrue
            $r.Checks.Name | Should -Contain 'ToolchainHermetic'
        } finally { Remove-Item $tmpDir -Recurse -Force -EA SilentlyContinue }
    }
}

Describe 'L5 Extended: Rekor remote mirror' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SupplyChain.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:rekorStmt = [PSCustomObject]@{ _type = 'https://in-toto.io/Statement/v0.1'; subject = @() }
    }

    It 'skips without touching the network when no URL is configured' {
        $old = [System.Environment]::GetEnvironmentVariable('GBUILD_REKOR_URL')
        try {
            [System.Environment]::SetEnvironmentVariable('GBUILD_REKOR_URL', $null)
            $r = Send-TransparencyEntryToRekor -Entry $global:rekorStmt
            $r.Status | Should -Be 'Skipped'
        } finally {
            if ($null -ne $old) { [System.Environment]::SetEnvironmentVariable('GBUILD_REKOR_URL', $old) }
        }
    }

    It 'fails closed on an invalid URL without throwing' {
        $old = [System.Environment]::GetEnvironmentVariable('GBUILD_REKOR_URL')
        try {
            [System.Environment]::SetEnvironmentVariable('GBUILD_REKOR_URL', 'ftp://example.invalid/rekor')
            $r = Send-TransparencyEntryToRekor -Entry $global:rekorStmt
            $r.Status | Should -Be 'Failed'
        } finally {
            if ($null -ne $old) { [System.Environment]::SetEnvironmentVariable('GBUILD_REKOR_URL', $old) }
            else { [System.Environment]::SetEnvironmentVariable('GBUILD_REKOR_URL', $null) }
        }
    }
}

Describe 'L5 Extended: tenant usage and audit pack' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'RootCause.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:useTemp = New-IntegrationTempDir
        $global:useHist = Join-Path $global:useTemp 'rc.jsonl'
        $mkState = {
            param([string]$Tenant)
            [PSCustomObject]@{ TenantId = $Tenant; BuildConfig = [PSCustomObject]@{ rootCause = [PSCustomObject]@{ enabled = $true; historyPath = $global:useHist } }; WorkingDir = $global:useTemp }
        }
        $sa = & $mkState 'acme'
        $sb = & $mkState 'globex'
        $ra = New-CARRecord -Category 'DiskFull' -Confidence 0.95 -Severity 'Critical' -State $sa
        [void](Write-CARRecord -Record $ra -State $sa)
        $rb = New-CARRecord -Category 'PortConflict' -Confidence 0.85 -Severity 'Medium' -State $sb
        [void](Write-CARRecord -Record $rb -State $sb)
        [void](Confirm-CARClosure -Id $rb.Id -Evidence 'moved port' -State $sb)
        $global:useState = $sa
    }

    It 'meters usage per tenant from the ledger' {
        $u = Get-TenantUsageSummary -State $global:useState
        $u.Total | Should -Be 2
        $u.Open | Should -Be 1
        $u.Tenants.acme.Total | Should -Be 1
        $u.Tenants.acme.Critical | Should -Be 1
        $u.Tenants.globex.Closed | Should -Be 1
    }

    It 'returns a zero summary when no ledger exists' {
        $d = New-IntegrationTempDir
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ rootCause = [PSCustomObject]@{ enabled = $true; historyPath = (Join-Path $d 'rc.jsonl') } }; WorkingDir = $d }
        $u = Get-TenantUsageSummary -State $st
        $u.Total | Should -Be 0
    }

    It 'exports an auditable pack with a hash manifest' {
        $pack = Join-Path $global:useTemp 'audit-pack'
        $out = Export-CARAuditPack -State $global:useState -OutputPath $pack
        $out | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $out 'car-records.jsonl') -PathType Leaf | Should -BeTrue
        $mf = Get-Content -LiteralPath (Join-Path $out 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $mf.schema | Should -Be 'car.audit-pack.v1'
        $mf.verified | Should -BeTrue
        $mf.validRecords | Should -Be 2
    }

    It 'returns empty when there is nothing to export' {
        $d = New-IntegrationTempDir
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ rootCause = [PSCustomObject]@{ enabled = $true; historyPath = (Join-Path $d 'rc.jsonl') } }; WorkingDir = $d }
        (Export-CARAuditPack -State $st -OutputPath (Join-Path $d 'pack')) | Should -BeNullOrEmpty
    }
}

Describe 'L5 Beyond: transparency verification' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SupplyChain.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:tvTemp = New-IntegrationTempDir
        $global:tvState = [PSCustomObject]@{ ProjectRoot = $global:tvTemp; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{} } }
        $stmt = [PSCustomObject]@{ _type = 'https://in-toto.io/Statement/v0.1'; subject = @() }
        [void](Write-TransparencyLogEntry -Statement $stmt -State $global:tvState)
        [void](Write-TransparencyLogEntry -Statement $stmt -State $global:tvState)
        $global:tvPath = Resolve-TransparencyLogPath -State $global:tvState
    }

    It 'verifies an intact chain' {
        $v = Test-TransparencyLog -State $global:tvState
        $v.Valid | Should -BeTrue
        $v.Checked | Should -Be 2
        $v.Tip | Should -Not -BeNullOrEmpty
    }

    It 'detects a tampered entry' {
        $lines = @(Get-Content -LiteralPath $global:tvPath -Encoding UTF8)
        $evil = $lines[1] | ConvertFrom-Json
        $evil.statementHash = 'tampered'
        $lines[1] = ($evil | ConvertTo-Json -Compress)
        Set-Content -LiteralPath $global:tvPath -Value $lines -Encoding UTF8
        try {
            $v = Test-TransparencyLog -State $global:tvState
            $v.Valid | Should -BeFalse
            ($v.Reasons -join ' ') | Should -Match 'mismatch'
        } finally {
            $stmt = [PSCustomObject]@{ _type = 'https://in-toto.io/Statement/v0.1'; subject = @() }
            Remove-Item -LiteralPath $global:tvPath -Force -ErrorAction SilentlyContinue
            [void](Write-TransparencyLogEntry -Statement $stmt -State $global:tvState)
            [void](Write-TransparencyLogEntry -Statement $stmt -State $global:tvState)
        }
    }

    It 'detects truncation against a pinned tip' {
        $v = Test-TransparencyLog -State $global:tvState
        $tip = $v.Tip
        $lines = @(Get-Content -LiteralPath $global:tvPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Set-Content -LiteralPath $global:tvPath -Value @($lines[0]) -Encoding UTF8
        try {
            $short = Test-TransparencyLog -State $global:tvState
            $short.Valid | Should -BeTrue
            $pinned = Test-TransparencyLog -State $global:tvState -ExpectedTip $tip
            $pinned.Valid | Should -BeFalse
            ($pinned.Reasons -join ' ') | Should -Match 'tip mismatch'
        } finally {
            $stmt = [PSCustomObject]@{ _type = 'https://in-toto.io/Statement/v0.1'; subject = @() }
            Remove-Item -LiteralPath $global:tvPath -Force -ErrorAction SilentlyContinue
            [void](Write-TransparencyLogEntry -Statement $stmt -State $global:tvState)
            [void](Write-TransparencyLogEntry -Statement $stmt -State $global:tvState)
        }
    }

    It 'reports a missing log instead of throwing' {
        $d = New-IntegrationTempDir
        $st = [PSCustomObject]@{ ProjectRoot = $d; BuildConfig = [PSCustomObject]@{ security = [PSCustomObject]@{} } }
        $v = Test-TransparencyLog -State $st
        $v.Valid | Should -BeFalse
    }
}

Describe 'L5 Beyond: fleet rollup and billing' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'ProcessMetrics.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:roTemp = New-IntegrationTempDir
        $global:roFleet = Join-Path $global:roTemp 'fleet'
        New-Item -ItemType Directory -Path (Join-Path $global:roFleet 'web') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $global:roFleet 'node') -Force | Out-Null
        $sta = [PSCustomObject]@{ ProjectRoot = (Join-Path $global:roFleet 'web'); BuildConfig = [PSCustomObject]@{} }
        $stb = [PSCustomObject]@{ ProjectRoot = (Join-Path $global:roFleet 'node'); BuildConfig = [PSCustomObject]@{} }
        $ra = @([PSCustomObject]@{ meanAdoption = 1.0; atParity = $true })
        $rb = @([PSCustomObject]@{ meanAdoption = 0.5; atParity = $false })
        [void](Publish-FleetSLOSummary -Records $ra -State $sta)
        [void](Publish-FleetSLOSummary -Records $rb -State $stb)
    }

    It 'rolls up published fleet files into one view' {
        $out = Join-Path $global:roTemp 'rollup.json'
        $p = Invoke-FleetRollup -FleetDir $global:roFleet -OutputPath $out
        $p | Should -Not -BeNullOrEmpty
        $doc = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $doc.schema | Should -Be 'gbuild.fleet-rollup.v1'
        $doc.dirCount | Should -Be 2
        $doc.totalProjects | Should -Be 2
        $doc.meanAdoption | Should -Be 0.75
    }

    It 'returns empty for a missing fleet directory' {
        (Invoke-FleetRollup -FleetDir (Join-Path $global:roTemp 'absent') -OutputPath (Join-Path $global:roTemp 'r.json')) | Should -BeNullOrEmpty
    }

    It 'prices tenant usage with explicit rates' {
        $tenants = @(
            [PSCustomObject]@{ Tenant = 'acme'; Total = 10; Open = 2; Closed = 8; Critical = 1 },
            [PSCustomObject]@{ Tenant = 'globex'; Total = 4; Open = 0; Closed = 4; Critical = 0 }
        )
        $b = Get-FleetBillingSummary -Tenants $tenants -Rates @{ PerRecord = 1.0; PerCritical = 5.0; PerOpen = 0.5 }
        $b.Currency | Should -Be 'USD'
        $b.Lines.Count | Should -Be 2
        ($b.Lines | Where-Object { $_.Tenant -eq 'acme' }).Amount | Should -Be 16
        ($b.Lines | Where-Object { $_.Tenant -eq 'globex' }).Amount | Should -Be 4
        $b.Total | Should -Be 20
    }

    It 'skips unreadable tenant entries' {
        $b = Get-FleetBillingSummary -Tenants @($null, 'junk') -Rates @{}
        $b.Total | Should -Be 0
    }
}

Describe 'L5 Beyond: audit pack re-verification and floor ratchet' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'RootCause.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'ProcessMetrics.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:rpTemp = New-IntegrationTempDir
        $global:rpState = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ rootCause = [PSCustomObject]@{ enabled = $true; historyPath = (Join-Path $global:rpTemp 'rc.jsonl') } }; WorkingDir = $global:rpTemp }
        $rec = New-CARRecord -Category 'DiskFull' -Confidence 0.9 -Severity 'High' -State $global:rpState
        [void](Write-CARRecord -Record $rec -State $global:rpState)
        $global:rpPack = Export-CARAuditPack -State $global:rpState -OutputPath (Join-Path $global:rpTemp 'pack')
    }

    It 're-verifies an intact pack' {
        $v = Test-CARAuditPack -PackPath $global:rpPack
        $v.Verified | Should -BeTrue
    }

    It 'detects a tampered ledger inside the pack' {
        $ledger = Join-Path $global:rpPack 'car-records.jsonl'
        $bak = @(Get-Content -LiteralPath $ledger -Encoding UTF8)
        try {
            $row = $bak[0] | ConvertFrom-Json
            $row.Category = 'Tampered'
            Set-Content -LiteralPath $ledger -Value @(($row | ConvertTo-Json -Compress)) -Encoding UTF8
            $v = Test-CARAuditPack -PackPath $global:rpPack
            $v.Verified | Should -BeFalse
        } finally {
            Set-Content -LiteralPath $ledger -Value $bak -Encoding UTF8
        }
    }

    It 'proposes a raise for a sustained improvement and nothing otherwise' {
        $floor = [PSCustomObject]@{ demoClass = [PSCustomObject]@{ minAdoption = 0.5 } }
        $mkRec = {
            param([double]$Adoption)
            [PSCustomObject]@{ meanAdoption = $Adoption; atParity = $true; classes = @([PSCustomObject]@{ class = 'demoClass'; adopted = 1; total = 1; adoption = $Adoption; remaining = 0 }) }
        }
        $hist = @((& $mkRec 0.8), (& $mkRec 0.85), (& $mkRec 0.9), (& $mkRec 0.9), (& $mkRec 0.95))
        $cur = [PSCustomObject]@{ Classes = @([PSCustomObject]@{ Class = 'demoClass'; Adoption = 0.95 }) }
        $cands = @(Find-RatchetCandidates -Floor $floor -CurrentMetrics $cur -History $hist -MinSustained 5)
        $cands.Count | Should -Be 1
        $cands[0].Class | Should -Be 'demoClass'
        $cands[0].Proposed | Should -BeGreaterThan 0.5
        $dipped = @((& $mkRec 0.8), (& $mkRec 0.4), (& $mkRec 0.9), (& $mkRec 0.9), (& $mkRec 0.95))
        @(Find-RatchetCandidates -Floor $floor -CurrentMetrics $cur -History $dipped -MinSustained 5).Count | Should -Be 0
        @(Find-RatchetCandidates -Floor $null -CurrentMetrics $cur -History $hist).Count | Should -Be 0
    }
}
