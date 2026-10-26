#Requires -Version 5.1
#Requires -Module Pester

# PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS
. (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'PlatformShim.ps1'))

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "ErrorHandling" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'ErrorHandling.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Reset-ErrorLog
    }

    BeforeEach {
        Reset-ErrorLog
        Clear-RollbackStack
        $global:state = [PSCustomObject]@{
            ScriptRoot  = $( [System.IO.Path]::GetTempPath() )
            ProjectRoot = $( [System.IO.Path]::GetTempPath() )
            WorkingDir  = $( [System.IO.Path]::GetTempPath() )
            CorrelationId = 'test-correlation-000'
            BuildConfig = [PSCustomObject]@{ }
            Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
            OS = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'MacOS' } else { 'Linux' }
            LogLevel = 3
        }
    }

    # ── Get-ErrorCategory ───────────────────────────────────────────────
    It "Get-ErrorCategory returns Transient for network timeout" {
        $err = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('network timeout'), 'op', 'OperationStopped', $null)
        Get-ErrorCategory -ErrorRecord $err | Should -Be 'Transient'
    }

    It "Get-ErrorCategory returns Transient for connection refused" {
        $err = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('connection refused'), 'op', 'OperationStopped', $null)
        Get-ErrorCategory -ErrorRecord $err | Should -Be 'Transient'
    }

    It "Get-ErrorCategory returns Configuration for file not found" {
        $err = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('file not found'), 'op', 'OperationStopped', $null)
        Get-ErrorCategory -ErrorRecord $err | Should -Be 'Configuration'
    }

    It "Get-ErrorCategory returns Environment for permission denied" {
        $err = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('permission denied'), 'op', 'OperationStopped', $null)
        Get-ErrorCategory -ErrorRecord $err | Should -Be 'Environment'
    }

    It "Get-ErrorCategory returns Permanent for CS1002 syntax error" {
        $err = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('CS1002: syntax error'), 'op', 'OperationStopped', $null)
        Get-ErrorCategory -ErrorRecord $err | Should -Be 'Permanent'
    }

    It "Get-ErrorCategory returns Unknown for null" {
        Get-ErrorCategory -ErrorRecord $null | Should -Be 'Unknown'
    }

    It "Get-ErrorCategory returns Unknown for non-ErrorRecord" {
        Get-ErrorCategory -ErrorRecord 'just a string' | Should -Be 'Unknown'
    }

    # ── Get-ErrorCategoryInfo ───────────────────────────────────────────
    It "Get-ErrorCategoryInfo returns non-empty string for known category" {
        $info = Get-ErrorCategoryInfo -Category 'Transient'
        $info | Should -Not -BeNullOrEmpty
    }

    It "Get-ErrorCategoryInfo returns Unknown description for unknown category" {
        Get-ErrorCategoryInfo -Category 'Bogus' | Should -Be (Get-ErrorCategoryInfo -Category 'Unknown')
    }

    # ── New-BuildError ──────────────────────────────────────────────────
    It "New-BuildError returns object with Message, Category and IsRetryable true for Transient" {
        $e = New-BuildError -Message 'x' -Category 'Transient' -State $global:state
        $e.Message | Should -Be 'x'
        $e.Category | Should -Be 'Transient'
        $e.IsRetryable | Should -Be $true
    }

    It "New-BuildError enriches Context with CorrelationId and Module" {
        $e = New-BuildError -Message 'x' -Category 'Transient' -State $global:state
        $e.Context.CorrelationId | Should -Be 'test-correlation-000'
        $e.Context.Module | Should -Not -BeNullOrEmpty
    }

    It "New-BuildError auto-classifies Unknown category from OriginalError timeout" {
        $err = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('network timeout'), 'op', 'OperationStopped', $null)
        $e = New-BuildError -Message 'x' -Category 'Unknown' -OriginalError $err -State $global:state
        $e.Category | Should -Be 'Transient'
        $e.IsRetryable | Should -Be $true
    }

    # ── Invoke-WithRetry ────────────────────────────────────────────────
    It "Invoke-WithRetry returns result on first try" {
        $r = Invoke-WithRetry -Action { return 'ok' } -MaxRetries 2
        $r | Should -Be 'ok'
    }

    It "Invoke-WithRetry retries then succeeds and counts attempts" {
        $script:c = 0
        $act = { $script:c++; if ($script:c -le 2) { throw [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('network timeout'), 'o', 'OperationStopped', $null) } else { return 'done' } }
        $r = Invoke-WithRetry -Action $act -MaxRetries 3 -BaseDelayMs 10
        $r | Should -Be 'done'
        $script:c | Should -Be 3
    }

    It "Invoke-WithRetry throws on non-retryable (Permanent) error" {
        $act = { throw [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('CS1002: syntax error'), 'o', 'OperationStopped', $null) }
        { Invoke-WithRetry -Action $act -MaxRetries 3 -BaseDelayMs 1 } | Should -Throw
    }

    It "Invoke-WithRetry respects config-driven retry settings" {
        $script:c = 0
        $cfgState = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{ errorHandling = [PSCustomObject]@{ maxRetries = 2; baseDelayMs = 10; maxDelayMs = 20; retryTimeoutSec = 0 } }
            Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
            LogLevel = 3
        }
        $act = { $script:c++; if ($script:c -le 1) { throw [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('network timeout'), 'o', 'OperationStopped', $null) } else { return 'cfg-ok' } }
        $r = Invoke-WithRetry -Action $act -State $cfgState -MaxRetries 99
        $r | Should -Be 'cfg-ok'
        $script:c | Should -Be 2
    }

    It "Invoke-WithRetry throws on timeout (retryTimeoutSec=1)" {
        $timeoutState = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{ errorHandling = [PSCustomObject]@{ maxRetries = 20; baseDelayMs = 10; maxDelayMs = 20; retryTimeoutSec = 1 } }
            Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
            LogLevel = 3
        }
        $act = { throw [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('network timeout'), 'o', 'OperationStopped', $null) }
        { Invoke-WithRetry -Action $act -State $timeoutState -MaxRetries 20 -BaseDelayMs 10 } | Should -Throw
    }

    It "Invoke-WithRetry honors ChaosRetryOverride from State (chaos drill)" {
        $script:c = 0
        $chaosState = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{ }
            ChaosRetryOverride = 0
            Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
            LogLevel = 3
        }
        $act = { $script:c++; throw [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('network timeout'), 'o', 'OperationStopped', $null) }
        { Invoke-WithRetry -Action $act -State $chaosState -MaxRetries 5 -BaseDelayMs 1 } | Should -Throw
        $script:c | Should -Be 1
    }

    It "Invoke-HistoryWriteWithRetry returns a successful result without retrying" {
        $r = Invoke-HistoryWriteWithRetry -OperationName 'test history' -Action { return 'written' } -MaxAttempts 3 -BaseDelayMs 1
        $r | Should -Be 'written'
    }

    It "Invoke-HistoryWriteWithRetry retries a permanent history failure and returns false" {
        # This intentionally differs from Invoke-WithRetry: a history lock
        # failure is not classified first, so even a permanent error is
        # retried, and exhaustion returns $false instead of throwing.
        $script:c = 0
        $act = { $script:c++; throw [System.InvalidOperationException]::new('history lock unavailable') }
        $r = Invoke-HistoryWriteWithRetry -OperationName 'test history' -Action $act -MaxAttempts 2 -BaseDelayMs 1
        $r | Should -BeFalse
        $script:c | Should -Be 2
    }

    # ── Rollback ────────────────────────────────────────────────────────
    It "Invoke-Rollback executes actions in LIFO order" {
        $global:__rbOrder = ''
        Register-RollbackAction -Name 'a' -Action { $global:__rbOrder += 'a' }
        Register-RollbackAction -Name 'b' -Action { $global:__rbOrder += 'b' }
        Invoke-Rollback -State $global:state
        $global:__rbOrder | Should -Be 'ba'
    }

    It "Invoke-Rollback with empty stack does not throw" {
        Clear-RollbackStack
        { Invoke-Rollback -State $global:state } | Should -Not -Throw
    }

    # ── Error aggregation ───────────────────────────────────────────────
    It "Get-ErrorSummary returns Total and ByCategory after errors created" {
        New-BuildError -Message 'e1' -Category 'Transient' -State $global:state
        New-BuildError -Message 'e2' -Category 'Permanent' -State $global:state
        $s = Get-ErrorSummary
        $s.Total | Should -Be 2
        $s.ByCategory.Keys | Should -Contain 'Transient'
        $s.ByCategory.Keys | Should -Contain 'Permanent'
    }

    It "Show-ErrorReport does not throw" {
        New-BuildError -Message 'e1' -Category 'Transient' -State $global:state
        { Show-ErrorReport -State $global:state } | Should -Not -Throw
    }

    It "Show-ErrorReport -AsJson returns a JSON string" {
        New-BuildError -Message 'e1' -Category 'Transient' -State $global:state
        $json = Show-ErrorReport -State $global:state -AsJson
        $json | Should -Not -BeNullOrEmpty
        { $json | ConvertFrom-Json } | Should -Not -Throw
    }

    It "Write-ErrorStructured returns an error object" {
        $e = Write-ErrorStructured -Message 'm' -Category 'Transient' -State $global:state
        $e.Message | Should -Be 'm'
        $e.Category | Should -Be 'Transient'
    }

    It "Reset-ErrorLog clears the error log" {
        New-BuildError -Message 'e1' -Category 'Transient' -State $global:state
        Reset-ErrorLog
        (Get-ErrorSummary).Total | Should -Be 0
    }

    It "Save-BuildState creates a state file on disk" {
        $td = New-IntegrationTempDir
        $st = [PSCustomObject]@{ ScriptRoot = $td; CorrelationId = 'save-test'; BuildConfig = [PSCustomObject]@{} }
        $ok = Save-BuildState -State $st
        $ok | Should -BeTrue
        $path = Get-StateFilePath -State $st
        Test-Path -LiteralPath $path | Should -BeTrue
        Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Restore-BuildState recovers State from disk and reports the previous run's error count without replaying it" {
        $td = New-IntegrationTempDir
        $st = [PSCustomObject]@{ ScriptRoot = $td; CorrelationId = 'restore-test'; BuildConfig = [PSCustomObject]@{} }
        New-BuildError -Message 'persist-me' -Category 'Transient' -State $st
        Save-BuildState -State $st | Out-Null
        Reset-ErrorLog
        (Get-ErrorSummary).Total | Should -Be 0
        $path = Get-StateFilePath -State $st
        $restored = Restore-BuildState -Path $path
        $restored.CorrelationId | Should -Be 'restore-test'
        # The previous run's errors are persisted and REPORTED but deliberately
        # NOT replayed into the live log. They used to be injected here, which
        # leaked them into every subsequent run: Write-TelemetryEntry counts the
        # live log, so a successful build published ErrorCount=2 inherited from an
        # earlier run. Per-run accounting must start from zero. The count itself
        # used to be parsed into $script:RestoredErrorCount and then read by
        # nothing at all, so "how badly did the last run fail" was unreachable;
        # Get-RestoredStateInfo is the accessor that carries it.
        (Get-ErrorSummary).Total | Should -Be 0 -Because 'previous-run errors must not enter this run live tally'
        $info = Get-RestoredStateInfo
        $info | Should -Not -BeNullOrEmpty
        $info.PreviousErrorCount | Should -Be 1 -Because 'the count parsed from the state file must be observable, not discarded'
        Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Restore-BuildState returns null for nonexistent path" {
        Restore-BuildState -Path 'C:\nonexistent\fake.gbuildstate' | Should -BeNullOrEmpty
    }

    # --- Regression: CWD-anchored state persistence leaked .gbuild artifacts
    # outside the project. Save-BuildState used Resolve-Path -Relative, which
    # anchors on the PROCESS current directory, while Restore-BuildState re-joins
    # against the state file's own directory. A save from <proj>\Modules therefore
    # persisted '..\' and a restore from a different directory turned that into an
    # unrelated absolute path (observed: F:\.gbuild\locale.json). ---
    It "Save-BuildState anchors relative paths on the state file directory, not the CWD" {
        $proj = New-IntegrationTempDir
        $sub  = New-Item -ItemType Directory -Path (Join-Path $proj 'Modules') -Force
        $st = [PSCustomObject]@{ ScriptRoot = $proj; ProjectRoot = $proj; WorkingDir = $proj; CorrelationId = 'anchor-test' }

        $origLoc = $PWD.Path
        try {
            Set-Location -LiteralPath $sub.FullName
            Save-BuildState -State $st | Out-Null
        } finally { Set-Location -LiteralPath $origLoc }

        $persisted = [string](Import-Clixml -LiteralPath (Join-Path $proj '.gbuild-state.gbuildstate')).State.ScriptRoot
        $persisted | Should -Not -BeNullOrEmpty
        # A CWD-anchored save produced '..\' here. Only an ancestor traversal or a
        # bare '.' is ever persisted, and only when it is anchored on the state
        # file directory; a rooted value is always safe because Restore-BuildState
        # passes it through untouched.
        if (-not [System.IO.Path]::IsPathRooted($persisted)) {
            $persisted | Should -Not -Match '^[\\/]?\.([\\/]|$)'
            $persisted | Should -Not -Match '^[\\/]?\.\.([\\/]|$)'
        }
        Remove-Item $proj -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Restore-BuildState round-trips the root when the CWD differs from the state file directory" {
        $proj   = New-IntegrationTempDir
        $sub    = New-Item -ItemType Directory -Path (Join-Path $proj 'Modules') -Force
        $launch = New-IntegrationTempDir
        $st = [PSCustomObject]@{ ScriptRoot = $proj; ProjectRoot = $proj; WorkingDir = $proj; CorrelationId = 'roundtrip-test' }

        $origLoc = $PWD.Path
        try {
            Set-Location -LiteralPath $sub.FullName
            Save-BuildState -State $st | Out-Null
            Set-Location -LiteralPath $launch
            $restored = Restore-BuildState -Path (Join-Path $proj '.gbuild-state.gbuildstate')
        } finally { Set-Location -LiteralPath $origLoc }

        $restored.ScriptRoot | Should -Be ([System.IO.Path]::GetFullPath($proj))
        Remove-Item $proj   -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $launch -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Restore-BuildState normalizes a legacy '..\' path so no parent segment survives" {
        $anchor = New-IntegrationTempDir
        $legacy = [PSCustomObject]@{
            State   = [PSCustomObject]@{ ScriptRoot = '..'; CorrelationId = 'legacy' }
            Errors  = @(); SavedAt = (Get-Date).ToString('o')
        }
        $legacy | Export-Clixml -Path (Join-Path $anchor '.gbuild-state.gbuildstate') -Force
        $restored = Restore-BuildState -Path (Join-Path $anchor '.gbuild-state.gbuildstate')
        [System.IO.Path]::IsPathRooted([string]$restored.ScriptRoot) | Should -BeTrue
        $restored.ScriptRoot | Should -Not -Match '(\.\.)(\\|/|$)'
        Remove-Item $anchor -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Get-StateFilePath refuses to fall back to the current directory" {
        Get-StateFilePath -State ([PSCustomObject]@{}) | Should -BeNullOrEmpty
        Get-StateFilePath -State $null | Should -BeNullOrEmpty
        # A relative root is not a valid anchor for a persisted state file.
        Get-StateFilePath -State ([PSCustomObject]@{ ScriptRoot = '.' }) | Should -BeNullOrEmpty
    }

    # Get-CircuitBreakerStateFilePath is module-private, so assert the observable
    # effect: Save-CircuitBreakerState must not drop a file in the CWD when the
    # state carries no usable root (Reset-CircuitBreaker passes -State $null).
    It "Save-CircuitBreakerState writes nothing when no rooted root can be resolved" {
        $cwd = New-IntegrationTempDir
        $origLoc = $PWD.Path
        try {
            Set-Location -LiteralPath $cwd
            Save-CircuitBreakerState -State ([PSCustomObject]@{}) | Should -BeFalse
            Save-CircuitBreakerState -State $null | Should -BeFalse
            @(Get-ChildItem -LiteralPath $cwd -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally { Set-Location -LiteralPath $origLoc; Remove-Item $cwd -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Save-BuildState writes nothing when no rooted destination can be resolved" {
        $cwd = New-IntegrationTempDir
        $origLoc = $PWD.Path
        try {
            Set-Location -LiteralPath $cwd
            Save-BuildState -State ([PSCustomObject]@{ CorrelationId = 'no-root' }) | Should -BeFalse
            Save-BuildState -State ([PSCustomObject]@{ ScriptRoot = '.'; CorrelationId = 'no-root2' }) | Should -BeFalse
            @(Get-ChildItem -LiteralPath $cwd -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally { Set-Location -LiteralPath $origLoc; Remove-Item $cwd -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
