# ============================================================================
# CacheProvider.Eviction.Tests.ps1 (Sprint 3-Q6: LRU/age eviction + compression)
# ============================================================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0

$cacheModule = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'Modules' 'CacheProvider.psm1'))
Import-Module $cacheModule -Force -DisableNameChecking

Describe 'CacheProvider - LRU / age eviction (Invoke-CacheEviction)' {

    BeforeEach {
        $dir = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_ev_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        for ($i = 0; $i -lt 5; $i++) {
            $f = Join-Path $dir ("entry_$i.bin")
            Set-Content -Path $f -Value ('x' * 1024)
            (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-($i * 10))
        }
        $script:state = [PSCustomObject]@{
            ScriptRoot = $( [System.IO.Path]::GetTempPath() )
            TenantId   = 'default'
            BuildConfig = [PSCustomObject]@{
                build = [PSCustomObject]@{
                    cacheLocal = [PSCustomObject]@{ Enabled = $true; MaxEntries = 3; MaxAgeDays = 100; MaxSizeMb = 1024 }
                }
            }
        }
    }

    AfterEach {
        if ($dir -and (Test-Path $dir)) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'evicts entries beyond MaxEntries (keeps newest 3)' {
        $removed = Invoke-CacheEviction -State $script:state -CacheDir $dir
        $remaining = @(Get-ChildItem -Path $dir -File).Count
        $remaining | Should -Be 3
        $removed | Should -Be 2
    }

    It 'evicts entries older than MaxAgeDays' {
        $script:state.BuildConfig.build.cacheLocal.MaxEntries = 100
        $script:state.BuildConfig.build.cacheLocal.MaxAgeDays = 15
        $removed = Invoke-CacheEviction -State $script:state -CacheDir $dir
        # entries at -20,-30,-40 days are older than 15d -> 3 evicted
        $removed | Should -Be 3
    }
}

Describe 'CacheProvider - GZip compression round-trip' {

    It 'compresses then decompresses a file to identical bytes' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_cmp_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $src = Join-Path $tmp 'plain.bin'
            $cmp = Join-Path $tmp 'plain.bin.gz'
            $out = Join-Path $tmp 'restored.bin'
            $data = [byte[]]@(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 1, 2, 3, 4, 5)
            [System.IO.File]::WriteAllBytes($src, $data)

            Compress-CacheFile -SourcePath $src -DestinationPath $cmp | Should -BeTrue
            (Test-Path $cmp) | Should -BeTrue
            Expand-CacheFile -SourcePath $cmp -DestinationPath $out | Should -BeTrue
            $restored = [System.IO.File]::ReadAllBytes($out)
            $restored.Count | Should -Be $data.Count
            for ($i = 0; $i -lt $data.Count; $i++) { $restored[$i] | Should -Be $data[$i] }
        }
        finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
