#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

$global:cacheTemp = New-IntegrationTempDir
$global:cacheState = [PSCustomObject]@{ ScriptRoot = $global:cacheTemp; CorrelationId = 'cache-it' }

Describe "Cache Integration" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Cache.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterAll {
        if ($global:cacheTemp -and (Test-Path $global:cacheTemp)) { Remove-Item $global:cacheTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Initialize-BuildCache creates the cache root on disk" {
        $root = Initialize-BuildCache -State $global:cacheState -CacheDir 'cache'
        $root | Should -Not -BeNullOrEmpty
        Test-Path $root | Should -BeTrue
    }

    It "Save-CacheEntry then Get-CacheEntry round-trips the stored hash" {
        Initialize-BuildCache -State $global:cacheState -CacheDir 'cache' | Out-Null
        $saved = Save-CacheEntry -Key 'projA' -ProjectHash 'ABC123'
        $saved.Hash | Should -Be 'ABC123'
        $got = Get-CacheEntry -Key 'projA'
        $got | Should -Not -BeNullOrEmpty
        $got.Hash | Should -Be 'ABC123'
    }

    It "Test-CacheValid returns true for a matching hash and false for a mismatch" {
        Initialize-BuildCache -State $global:cacheState -CacheDir 'cache' | Out-Null
        $output = Join-Path $global:cacheTemp 'projB.out'
        Set-Content -LiteralPath $output -Value 'artifact' -Force
        Save-CacheEntry -Key 'projB' -ProjectHash 'HASH1' -OutputPath $output | Out-Null
        Test-CacheValid -Key 'projB' -ProjectHash 'HASH1' | Should -BeTrue
        Test-CacheValid -Key 'projB' -ProjectHash 'WRONG' | Should -BeFalse
    }

    It "Get-CacheEntry returns null for an unknown key" {
        Initialize-BuildCache -State $global:cacheState -CacheDir 'cache' | Out-Null
        Get-CacheEntry -Key 'never-saved' | Should -BeNullOrEmpty
    }

    It "rejects path traversal in canonical cache keys" {
        Get-CanonicalCacheKey -Key '..\outside' | Should -BeNullOrEmpty
        Get-CanonicalCacheKey -Key 'a/../../outside' | Should -BeNullOrEmpty
    }

    It "maps equivalent separators to one canonical hash" {
        Get-CanonicalCacheKey -Key 'project\src\file.cs' | Should -Be (Get-CanonicalCacheKey -Key 'project/src/file.cs')
    }

    It "keeps local cache entries isolated by tenant" {
        $stateA = [PSCustomObject]@{ ScriptRoot = $global:cacheTemp; ProjectRoot = $global:cacheTemp; TenantId = 'tenant-a' }
        $stateB = [PSCustomObject]@{ ScriptRoot = $global:cacheTemp; ProjectRoot = $global:cacheTemp; TenantId = 'tenant-b' }
        $output = Join-Path $global:cacheTemp 'tenant-output.out'
        Set-Content -LiteralPath $output -Value 'artifact' -Force
        Initialize-BuildCache -State $stateA -CacheDir 'cache' | Out-Null
        Save-CacheEntry -Key 'shared' -ProjectHash 'HASH-T' -OutputPath $output | Out-Null
        Test-CacheValid -Key 'shared' -ProjectHash 'HASH-T' | Should -BeTrue
        Initialize-BuildCache -State $stateB -CacheDir 'cache' | Out-Null
        Test-CacheValid -Key 'shared' -ProjectHash 'HASH-T' | Should -BeFalse
    }

    It "does not hit when the saved output disappears" {
        Initialize-BuildCache -State $global:cacheState -CacheDir 'cache' | Out-Null
        $output = Join-Path $global:cacheTemp 'disappearing.out'
        Set-Content -LiteralPath $output -Value 'artifact' -Force
        Save-CacheEntry -Key 'disappearing' -ProjectHash 'HASH1' -OutputPath $output | Out-Null
        Remove-Item -LiteralPath $output -Force
        Test-CacheValid -Key 'disappearing' -ProjectHash 'HASH1' | Should -BeFalse
    }

    It "keeps the index parseable after writes" {
        Initialize-BuildCache -State $global:cacheState -CacheDir 'cache' | Out-Null
        Save-CacheEntry -Key 'atomic-a' -ProjectHash 'HASH-A' | Out-Null
        Save-CacheEntry -Key 'atomic-b' -ProjectHash 'HASH-B' | Out-Null
        $index = Get-Content -LiteralPath (Join-Path $global:cacheTemp 'cache\index.json') -Raw | ConvertFrom-Json
        $index.Entries | Should -Not -BeNullOrEmpty
    }
}

Describe "Cache Hashing" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Cache.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Initialize-BuildCache -State $global:cacheState -CacheDir 'cache' | Out-Null
    }

    It "Get-FileHashFast returns a stable 64-char hex hash" {
        $f1 = Join-Path $global:cacheTemp 'h1.txt'; 'alpha' | Set-Content -Path $f1 -Force
        $f2 = Join-Path $global:cacheTemp 'h2.txt'; 'beta'  | Set-Content -Path $f2 -Force
        $h1 = Get-FileHashFast -Paths @($f1, $f2)
        $h1 | Should -BeOfType [string]
        $h1.Length | Should -Be 64
        Get-FileHashFast -Paths @($f1, $f2) | Should -Be $h1
    }

    It "Get-FileHashFast differs for different content" {
        $f1 = Join-Path $global:cacheTemp 'd1.txt'; 'alpha' | Set-Content -Path $f1 -Force
        $f2 = Join-Path $global:cacheTemp 'd2.txt'; 'gamma' | Set-Content -Path $f2 -Force
        $ha = Get-FileHashFast -Paths @($f1)
        $hb = Get-FileHashFast -Paths @($f2)
        $ha | Should -Not -Be $hb
    }
}

Describe "Cache Statistics and Maintenance" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Cache.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Initialize-BuildCache -State $global:cacheState -CacheDir 'cache' | Out-Null
    }

    It "Get-CacheStatistics returns an object with statistic properties" {
        Initialize-BuildCache -State $global:cacheState -CacheDir 'cache' | Out-Null
        Save-CacheEntry -Key 'statProbe' -ProjectHash 'STAT1' | Out-Null
        $stats = Get-CacheStatistics
        $stats | Should -Not -BeNullOrEmpty
        $stats.Keys -contains 'Entries'  | Should -BeTrue
        $stats.Keys -contains 'Hits'     | Should -BeTrue
        $stats.Keys -contains 'Misses'   | Should -BeTrue
        $stats.Keys -contains 'HitRatio' | Should -BeTrue
        $stats.Entries | Should -BeOfType [int]
        $stats.Hits    | Should -BeOfType [int]
        $stats.Misses  | Should -BeOfType [int]
    }

    It "Clear-BuildCache -Force does not throw and Get-CacheStatistics still works" {
        { Clear-BuildCache -State $global:cacheState -Force } | Should -Not -Throw
        $stats = Get-CacheStatistics
        $stats | Should -Not -BeNullOrEmpty
    }

    It "Optimize-Cache does not throw (even after clear)" {
        Initialize-BuildCache -State $global:cacheState -CacheDir 'cache' | Out-Null
        { Optimize-Cache -State $global:cacheState } | Should -Not -Throw
    }
}

Describe "Cache Build Wrapper" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Cache.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Initialize-BuildCache -State $global:cacheState -CacheDir 'cache' | Out-Null
    }

    It "Invoke-BuildWithCache caches results on the second call" {
        $projDir = Join-Path $global:cacheTemp 'projc'
        $null = New-Item -ItemType Directory -Path $projDir -Force
        $projFile = Join-Path $projDir 'projC.cs'
        'class C { }' | Set-Content -Path $projFile -Force
        $outFile = Join-Path $projDir 'projC.out'
        'output' | Set-Content -Path $outFile -Force

        $first = @(Invoke-BuildWithCache -ProjectPath $projFile -CacheKey 'k1' -BuildAction { return $outFile } -State $global:cacheState)
        ($first -contains $outFile) | Should -BeTrue

        $second = Invoke-BuildWithCache -ProjectPath $projFile -CacheKey 'k1' -BuildAction { return $outFile } -State $global:cacheState
        $second | Should -BeOfType [hashtable]
        $second.Cached | Should -BeTrue
    }
}

Describe "Cache Remote Sync Wiring" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Cache.psm1') -Force -DisableNameChecking -ErrorAction Stop
        # The wiring resolves the sync/flag commands via Get-Command (mirroring the
        # production bootstrap where Cache + CacheProvider coexist). Loading the
        # real provider here lets Pester redirect those calls with -ModuleName Cache,
        # so no network/sync happens and the syncOnBuild/syncOnRestore paths are
        # exercised deterministically.
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'CacheProvider.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:syncTemp = New-IntegrationTempDir
        $global:syncState = [PSCustomObject]@{ ScriptRoot = $global:syncTemp; ProjectRoot = $global:syncTemp; CorrelationId = 'cache-sync' }
        Initialize-BuildCache -State $global:syncState -CacheDir 'cache' | Out-Null
    }
    AfterAll {
        if ($global:syncTemp -and (Test-Path $global:syncTemp)) { Remove-Item $global:syncTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "syncOnRestore is a no-op when the remote cache is disabled" {
        $projDir = Join-Path $global:syncTemp 'projno'
        $null = New-Item -ItemType Directory -Path $projDir -Force
        $projFile = Join-Path $projDir 'projNo.cs'
        'class No { }' | Set-Content -Path $projFile -Force
        $outFile = Join-Path $projDir 'projNo.out'
        'output' | Set-Content -Path $outFile -Force

        $global:syncRestoreCalled = $false
        Mock Get-RemoteCacheConfig { [PSCustomObject]@{ Enabled = $false; SyncOnRestore = $true; SyncOnBuild = $true; Type = 'azureBlob' } } -ModuleName Cache
        Mock Update-CacheToLocal { $global:syncRestoreCalled = $true } -ModuleName Cache
        Mock Update-CacheToRemote { $null } -ModuleName Cache

        $result = @(Invoke-BuildWithCache -ProjectPath $projFile -CacheKey 'syncKno' -BuildAction { return $outFile } -State $global:syncState)
        ($result -contains $outFile) | Should -BeTrue
        $global:syncRestoreCalled | Should -BeFalse
    }

    It "syncOnRestore pulls from remote on a miss and returns a hit without building" {
        $projDir = Join-Path $global:syncTemp 'projs'
        $null = New-Item -ItemType Directory -Path $projDir -Force
        $projFile = Join-Path $projDir 'projS.cs'
        'class S { }' | Set-Content -Path $projFile -Force
        $outFile = Join-Path $projDir 'projS.out'
        'output' | Set-Content -Path $outFile -Force
        $syncHash = Get-ProjectHash -ProjectPath $projFile

        $global:syncBuildRan = $false
        Mock Get-RemoteCacheConfig { [PSCustomObject]@{ Enabled = $true; SyncOnRestore = $true; SyncOnBuild = $true; Type = 'azureBlob' } } -ModuleName Cache
        Mock Update-CacheToLocal { Save-CacheEntry -Key 'syncK1' -ProjectHash $syncHash -OutputPath $outFile } -ModuleName Cache
        Mock Update-CacheToRemote { $null } -ModuleName Cache

        $result = Invoke-BuildWithCache -ProjectPath $projFile -CacheKey 'syncK1' -BuildAction { $global:syncBuildRan = $true; return $outFile } -State $global:syncState
        $result.Cached | Should -BeTrue
        $global:syncBuildRan | Should -BeFalse
    }

    It "syncOnBuild pushes local entries to remote after a successful build" {
        $projDir = Join-Path $global:syncTemp 'projp'
        $null = New-Item -ItemType Directory -Path $projDir -Force
        $projFile = Join-Path $projDir 'projP.cs'
        'class P { }' | Set-Content -Path $projFile -Force
        $outFile = Join-Path $projDir 'projP.out'
        'output' | Set-Content -Path $outFile -Force

        $global:syncRemotePushed = $false
        Mock Get-RemoteCacheConfig { [PSCustomObject]@{ Enabled = $true; SyncOnRestore = $true; SyncOnBuild = $true; Type = 'azureBlob' } } -ModuleName Cache
        Mock Update-CacheToLocal { $null } -ModuleName Cache
        Mock Update-CacheToRemote { $global:syncRemotePushed = $true } -ModuleName Cache

        $result = @(Invoke-BuildWithCache -ProjectPath $projFile -CacheKey 'syncK2' -BuildAction { return $outFile } -State $global:syncState)
        ($result -contains $outFile) | Should -BeTrue
        $global:syncRemotePushed | Should -BeTrue
    }
}
