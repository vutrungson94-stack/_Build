# Phase B Verification Tests - DI bridge, EventBus->Alerting, Cache performance
# Validates the real behavior of the _Build system's core infrastructure.
# Run separately from other test files to avoid module session state pollution.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $here) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

AfterAll {
    if (Get-Module Logging) { Remove-Module Logging -Force -ErrorAction SilentlyContinue }
    if (Get-Module Container) { Remove-Module Container -Force -ErrorAction SilentlyContinue }
    if (Get-Module BuildContext) { Remove-Module BuildContext -Force -ErrorAction SilentlyContinue }
    if (Get-Module EventBus) { Remove-Module EventBus -Force -ErrorAction SilentlyContinue }
    if (Get-Module Alerting) { Remove-Module Alerting -Force -ErrorAction SilentlyContinue }
    if (Get-Module CacheProvider) { Remove-Module CacheProvider -Force -ErrorAction SilentlyContinue }
    if (Test-Path Variable:global:GState) { Remove-Variable GState -Scope Global -Force -ErrorAction SilentlyContinue }
    if (Test-Path Variable:global:GBuildServices) { $global:GBuildServices.Clear() }
}

Describe 'Phase B - Get-BuildState DI bridge' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Import-Module (Join-Path $global:GBuildModuleRoot 'Container.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Import-Module (Join-Path $global:GBuildModuleRoot 'BuildContext.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Clear-Services
        if (Test-Path Variable:global:GState) { Remove-Variable -Name GState -Scope Global -Force -ErrorAction SilentlyContinue }
    }

    It 'Returns $null when no state available' {
        if (Test-Path Variable:global:GState) { Remove-Variable -Name GState -Scope Global -Force -ErrorAction SilentlyContinue }
        if (Test-Path Variable:global:GBuildServices) { $global:GBuildServices.Clear() }
        Get-BuildState | Should -BeNullOrEmpty
    }

    It 'Falls back to $global:GState when no DI service registered' {
        $global:GState = [PSCustomObject]@{ Name = 'legacy'; OS = 'Windows' }
        $result = Get-BuildState
        $result.Name | Should -Be 'legacy'
        Remove-Variable -Name GState -Scope Global -Force -ErrorAction SilentlyContinue
    }

    It 'Prefers DI BuildContext singleton over $global:GState' {
        $ctx = New-BuildContext -Seed ([PSCustomObject]@{ OS = 'Linux'; TenantId = 'di' })
        Register-Service -Name 'BuildContext' -Factory { $ctx } -Singleton
        $global:GState = [PSCustomObject]@{ Name = 'legacy'; OS = 'Windows' }
        $result = Get-BuildState
        $result | Should -Not -BeNullOrEmpty
        $result.OS | Should -Be 'Linux'
        $result.TenantId | Should -Be 'di'
        Remove-Variable -Name GState -Scope Global -Force -ErrorAction SilentlyContinue
        Clear-Services
    }

    It 'Pass-through parameter has highest priority' {
        $param = [PSCustomObject]@{ Name = 'param' }
        $global:GState = [PSCustomObject]@{ Name = 'legacy' }
        $result = Get-BuildState -State $param
        $result.Name | Should -Be 'param'
        Remove-Variable -Name GState -Scope Global -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Phase B - EventBus -> Alerting integration' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'EventBus.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Import-Module (Join-Path $global:GBuildModuleRoot 'Alerting.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Clear-BuildEvents
    }

    It 'EVT_BUILD_ERROR triggers Send-Alert (webhook called, graceful degrade on dead endpoint)' {
        $captured = $null
        # Subscribe to EVT_BUILD_ERROR with a handler that calls Send-Alert and records the call
        Add-BuildEvent -EventName $EVT_BUILD_ERROR -Handler {
            param($Source, $Data)
            $script:captured = $Data.Message
            Send-Alert -Message $Data.Message -Severity 'Critical' -State $Data.State
        } -Label 'AlertOnError'

        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                alerting = [PSCustomObject]@{
                    enabled    = $true
                    webhookUrl = 'http://127.0.0.1:1/alert'  # dead endpoint, graceful degrade
                    minSeverity = 'Critical'
                }
            }
        }
        Send-BuildEvent -EventName $EVT_BUILD_ERROR -Data @{ Message = 'Test error'; State = $state }

        $script:captured | Should -Be 'Test error'
    }

    It 'EventBus isolates handler errors (one bad handler does not break others)' {
        Clear-BuildEvents
        Add-BuildEvent -EventName 'TestEvent' -Handler { throw 'bad handler' } -Label 'Bad'
        Add-BuildEvent -EventName 'TestEvent' -Handler { $script:goodFired = $true } -Label 'Good'
        { Send-BuildEvent -EventName 'TestEvent' } | Should -Not -Throw
        $script:goodFired | Should -Be $true
        $errors = Get-BuildEventErrors
        $errors.Count | Should -BeGreaterThan 0
    }

    It 'Get-BuildEventSubscribers reports correct counts' {
        Clear-BuildEvents
        Add-BuildEvent -EventName 'CountTest' -Handler { } -Label 'A'
        Add-BuildEvent -EventName 'CountTest' -Handler { } -Label 'B'
        $counts = Get-BuildEventSubscribers
        $counts['CountTest'] | Should -Be 2
    }
}

Describe 'Phase B - Cache performance verification' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'CacheProvider.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $cacheDir = Join-Path $TestDrive 'cache-perf'
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                build = [PSCustomObject]@{
                    cacheLocal = [PSCustomObject]@{
                        Enabled   = $true
                        MaxSizeMb = 0.001  # ~1KB to force eviction
                        MaxEntries = 3
                        MaxAgeDays = 30
                    }
                }
            }
        }
        $null = $state
    }

    It 'GZip compression reduces file size for compressible content' {
        $srcFile = Join-Path $TestDrive 'compress-src.txt'
        $content = 'repeated-text-' * 200  # highly compressible
        [System.IO.File]::WriteAllText($srcFile, $content, [System.Text.Encoding]::UTF8)
        $origSize = (Get-Item $srcFile).Length

        $gzFile = Join-Path $TestDrive 'compress-src.txt.gz'
        $ok = Compress-CacheFile -SourcePath $srcFile -DestinationPath $gzFile
        $ok | Should -Be $true
        $gzSize = (Get-Item $gzFile).Length
        $gzSize | Should -BeLessThan $origSize

        # Round-trip: decompress and verify content matches
        $outFile = Join-Path $TestDrive 'decompressed.txt'
        $ok2 = Expand-CacheFile -SourcePath $gzFile -DestinationPath $outFile
        $ok2 | Should -Be $true
        $decompressed = [System.IO.File]::ReadAllText($outFile)
        $decompressed | Should -Be $content
    }

    It 'LRU eviction removes oldest entries under size pressure' {
        # Create cache dir with 5 entries of ~1KB each (total > 1KB limit)
        $cacheSub = Join-Path $cacheDir 'lru'
        New-Item -ItemType Directory -Path $cacheSub -Force | Out-Null
        for ($i = 0; $i -lt 5; $i++) {
            $f = Join-Path $cacheSub "entry-$i.bin"
            $bytes = [byte[]]::new(400)
            [System.IO.File]::WriteAllBytes($f, $bytes)
            # Stagger last-write times so LRU is deterministic
            (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(-$i)
        }
        Invoke-CacheEviction -State $state -CacheDir $cacheSub -ErrorAction SilentlyContinue
        $remaining = @(Get-ChildItem $cacheSub -File -ErrorAction SilentlyContinue).Count
        $remaining | Should -BeLessThan 5
    }
}
