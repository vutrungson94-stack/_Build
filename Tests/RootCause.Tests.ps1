#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'RootCause.psm1') -Force -DisableNameChecking -ErrorAction Stop

Describe "RootCause (auto root-cause analysis)" {
    BeforeAll {
        $script:tempDir = Join-Path $( [System.IO.Path]::GetTempPath() ) "gbuild-rootcause-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    AfterAll {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Get-RootCauseConfig returns defaults when State has no rootCause section" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ } }
        $cfg = Get-RootCauseConfig -State $state
        $cfg.enabled | Should -BeTrue
        $cfg.maxHistoryEntries | Should -Be 500
    }

    It "the classifier table is data, so every score is config-overridable" {
        # The 15 confidence scores / suggestions used to be inline literals in a
        # 15-way elseif chain while Get-RootCauseConfig beside them was already
        # config-driven - so maxHistoryEntries was tunable and classifier
        # confidence was not. They are now rows in a table, and a project can
        # retune any of them from gbuild.config.json.
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ rootCause = [PSCustomObject]@{
            confidence = [PSCustomObject]@{ PortConflict = 0.11 }
            suggestion = [PSCustomObject]@{ PortConflict = 'Free the port or change build.defaultPort.' }
        } } }
        $err = [System.Management.Automation.ErrorRecord]::new(
            [Exception]::new('port 5000 is already in use'),
            'CommandNotFoundException',
            ([System.Management.Automation.ErrorCategory]::InvalidOperation),
            $null)
        $a = Get-RootCauseAnalysis -ErrorRecord $err -State $state
        $a.Category | Should -Be 'PortConflict'
        $a.Confidence | Should -Be 0.11
        $a.Suggestion | Should -Be 'Free the port or change build.defaultPort.'
    }

    It "ships a classifier for every known failure family, all scored" {
        # Asserting the table (not 15 inline numbers) is what makes a NEW
        # classifier or a removed one visible to a test.
        $rows = @(Get-RootCauseClassifiers -State ([PSCustomObject]@{ BuildConfig = [PSCustomObject]@{} }))
        $rows.Count | Should -BeGreaterOrEqual 15 -Because 'the shipped classifier table must cover the documented failure families'
        foreach ($r in $rows) {
            $r.Category | Should -Not -BeNullOrEmpty
            $r.Confidence | Should -BeGreaterThan 0
            $r.Confidence | Should -BeLessOrEqual 1
            $r.Suggestion | Should -Not -BeNullOrEmpty
            @($r.Tags).Count | Should -BeGreaterThan 0
        }
        # Order decides the winner when two patterns both match, so the specific
        # compiler rule must precede the broad config/json rule.
        $cats = @($rows | ForEach-Object { $_.Category })
        $cats | Should -Contain 'CompileError'
        $cats | Should -Contain 'ConfigError'
        [array]::IndexOf($cats, 'CompileError') | Should -BeLessThan ([array]::IndexOf($cats, 'ConfigError'))
    }

    It "Get-RootCauseAnalysis detects MissingSDK pattern" {
        $err = [System.Management.Automation.ErrorRecord]::new(
            [Exception]::new("The .NET SDK was not found. Install the .NET SDK or run 'gbuild' again."),
            'CommandNotFoundException',
            ([System.Management.Automation.ErrorCategory]::ObjectNotFound),
            $null
        )
        $analysis = Get-RootCauseAnalysis -ErrorRecord $err -State $null
        $analysis.Category | Should -Be 'MissingSDK'
        $analysis.Confidence | Should -BeGreaterThan 0.9
        $analysis.Tags | Should -Contain 'sdk'
    }

    It "Get-RootCauseAnalysis detects PortConflict pattern" {
        $err = [System.Management.Automation.ErrorRecord]::new(
            [Exception]::new("Port 5000 is already in use. Only one usage of each socket address is normally permitted."),
            'SocketException',
            ([System.Management.Automation.ErrorCategory]::ResourceBusy),
            $null
        )
        $analysis = Get-RootCauseAnalysis -ErrorRecord $err -State $null
        $analysis.Category | Should -Be 'PortConflict'
        $analysis.Confidence | Should -BeGreaterThan 0.9
    }

    It "Get-RootCauseAnalysis detects CompileError pattern" {
        $err = [System.Management.Automation.ErrorRecord]::new(
            [Exception]::new("error CS1002: ; expected in Program.cs(12,5)"),
            'CompilerError',
            ([System.Management.Automation.ErrorCategory]::SyntaxError),
            $null
        )
        $analysis = Get-RootCauseAnalysis -ErrorRecord $err -State $null
        $analysis.Category | Should -Be 'CompileError'
        $analysis.Tags | Should -Contain 'compile'
    }

    It "Get-RootCauseAnalysis detects DiskFull pattern" {
        $err = [System.Management.Automation.ErrorRecord]::new(
            [Exception]::new("There is not enough space on the disk. Write error occurred."),
            'IOException',
            ([System.Management.Automation.ErrorCategory]::WriteError),
            $null
        )
        $analysis = Get-RootCauseAnalysis -ErrorRecord $err -State $null
        $analysis.Category | Should -Be 'DiskFull'
    }

    It "Get-RootCauseAnalysis returns Unknown for unrecognized errors" {
        $err = [System.Management.Automation.ErrorRecord]::new(
            [Exception]::new("Something completely unexpected happened xyzzy."),
            'UnknownError',
            ([System.Management.Automation.ErrorCategory]::NotSpecified),
            $null
        )
        $analysis = Get-RootCauseAnalysis -ErrorRecord $err -State $null
        $analysis.Category | Should -Be 'Unknown'
        $analysis.Confidence | Should -Be 0.0
    }

    It "Write-RootCauseHistory appends a JSON line to the history file" {
        $historyFile = Join-Path $tempDir "root-cause.jsonl"
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ rootCause = [PSCustomObject]@{ enabled = $true; historyPath = $historyFile } }; ScriptRoot = $tempDir }
        $analysis = @{ Category = 'CompileError'; Confidence = 0.9; Suggestion = 'Fix the error'; RelatedFiles = @('Program.cs'); Tags = @('compile') }
        Write-RootCauseHistory -Analysis $analysis -State $state
        Test-Path $historyFile | Should -BeTrue
        $line = Get-Content $historyFile -Raw
        $line | Should -Match '"Category":"CompileError"'
    }

    It "Get-RootCauseSummary aggregates history correctly" {
        $historyFile = Join-Path $tempDir "root-cause-summary.jsonl"
        $lines = @(
            ([PSCustomObject]@{ Timestamp = (Get-Date).ToString('o'); Category = 'CompileError'; Confidence = 0.9; Suggestion = 'Fix'; RelatedFiles = @(); Tags = @('compile') } | ConvertTo-Json -Compress),
            ([PSCustomObject]@{ Timestamp = (Get-Date).ToString('o'); Category = 'CompileError'; Confidence = 0.85; Suggestion = 'Fix'; RelatedFiles = @(); Tags = @('compile') } | ConvertTo-Json -Compress),
            ([PSCustomObject]@{ Timestamp = (Get-Date).ToString('o'); Category = 'PortConflict'; Confidence = 0.95; Suggestion = 'Change port'; RelatedFiles = @(); Tags = @('port') } | ConvertTo-Json -Compress)
        )
        $lines | Set-Content -Path $historyFile -Encoding UTF8
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ rootCause = [PSCustomObject]@{ enabled = $true; historyPath = $historyFile } }; ScriptRoot = $tempDir }
        $summary = Get-RootCauseSummary -State $state
        $summary.Total | Should -Be 3
        $summary.Categories['CompileError'] | Should -Be 2
        $summary.Categories['PortConflict'] | Should -Be 1
    }
}

Describe 'RootCause history safety' {
    It 'rejects a history path outside the configured root' {
        $root = Join-Path $TestDrive 'contained'
        $outside = Join-Path $TestDrive 'outside-history.jsonl'
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ rootCause = [PSCustomObject]@{ enabled = $true; historyPath = $outside } }; WorkingDir = $root }
        Write-RootCauseHistory -Analysis @{ Category = 'CompileError'; Confidence = 0.9; Suggestion = 'Fix'; RelatedFiles = @(); Tags = @('compile') } -State $state | Should -BeFalse
        Test-Path -LiteralPath $outside | Should -BeFalse
    }

    It 'does not persist secret-bearing suggestions or paths' {
        $history = Join-Path $TestDrive 'root-cause-redaction.jsonl'
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ rootCause = [PSCustomObject]@{ enabled = $true; historyPath = $history } }; WorkingDir = (Split-Path -Parent $history) }
        Write-RootCauseHistory -Analysis @{ Category = 'NetworkError'; Confidence = 0.8; Suggestion = 'https://example.test/?token=secret-token'; RelatedFiles = @('C:\project\secret.cs'); Tags = @('token') } -State $state
        $content = Get-Content -LiteralPath $history -Raw
        $content | Should -Not -Match 'secret-token'
        $content | Should -Match 'REDACTED'
    }

    It 'keeps concurrent history lines valid' {
        $history = Join-Path $TestDrive 'root-cause-concurrent.jsonl'
        $historyRoot = Split-Path -Parent $history
        $module = Join-Path $global:GBuildModuleRoot 'RootCause.psm1'
        $jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock { param($m, $h, $root) Import-Module $m -Force -DisableNameChecking; $s = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ rootCause = [PSCustomObject]@{ enabled = $true; historyPath = $h } }; WorkingDir = $root }; 1..3 | ForEach-Object { Write-RootCauseHistory -Analysis @{ Category = 'CompileError'; Confidence = 0.9; Suggestion = 'Fix'; RelatedFiles = @(); Tags = @('compile') } -State $s } } -ArgumentList $module, $history, $historyRoot }
        $jobs | Wait-Job | Out-Null
        $jobs | Receive-Job | Out-Null
        $jobs | Remove-Job
        $lines = @(Get-Content -LiteralPath $history -ErrorAction SilentlyContinue)
        $lines.Count | Should -Be 6
        foreach ($line in $lines) { { $line | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw }
    }
}

Describe 'RootCause verification CAR' {
    It 'opens a corrective-action record that names the scope and the failing tests' {
        $record = New-VerificationCAR -Scope 'BuildHelpers' -FailedTests @('Suite.Probe :: fails on purpose', '') -GateThatMissed 'core suite scope verdict' -DetectedBy 'Pester scope BuildHelpers'
        $record | Should -Not -BeNullOrEmpty
        $record.Schema | Should -Be 'car.record.v1'
        $record.Status | Should -Be 'Open'
        $record.Category | Should -Be 'VerificationGateFailure'
        $record.Confidence | Should -Be 1.0
        $record.Verification.Scope | Should -Be 'BuildHelpers'
        @($record.Verification.FailedTests).Count | Should -Be 1
        $record.Verification.GateThatMissed | Should -Be 'core suite scope verdict'
        $record.Verification.DetectedBy | Should -Be 'Pester scope BuildHelpers'
        $record.Suggestion | Should -Match 'BuildHelpers'
        $record.Suggestion | Should -Match 'fails on purpose'
    }

    It 'redacts secret-bearing failure text before the record is written' {
        $record = New-VerificationCAR -Scope 'X' -FailedTests @('probe :: fails with https://example.test/?token=secret-token')
        $record.Suggestion | Should -Not -Match 'secret-token'
        $record.Suggestion | Should -Match 'REDACTED'
    }

    It 'resolves its config without ConfigProvider or BuildConstants loaded' {
        # A failing gate is exactly when the CAR must be writable, and the
        # runner may not have loaded the config modules. A CommandNotFound here
        # would silently lose the analysis record.
        $state = [PSCustomObject]@{ WorkingDir = $TestDrive }
        $cfg = Get-RootCauseConfig -State $state
        $cfg.enabled | Should -BeTrue
        $cfg.historyPath | Should -Match 'root-cause\.jsonl$'
        $cfg.maxHistoryEntries | Should -BeGreaterThan 0
    }
}
