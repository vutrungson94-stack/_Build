#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    CacheProvider.E2E - mock end-to-end remote cache proof.
.DESCRIPTION
    Proves Send-CacheEntry -> Receive-CacheEntry roundtrips through the
    full remote-cache code path WITHOUT a real Azure Blob / AWS S3 backend.
    Inside InModuleScope we shim Invoke-RestMethod / Invoke-WebRequest so
    the module's real push/pull logic runs against an in-memory store.
    No hardcoded paths, no external network.
#>

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe "Remote Cache E2E (mock backend)" {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Import-Module (Join-Path $global:GBuildModuleRoot 'CacheProvider.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    AfterAll {
        # Intentionally do NOT Remove-Module: Pester shares module session state
        # across files in one run; removing here would break later test files that
        # import the same module. Mocks defined inside the It block auto-revert.
    }

    It "Pushes then pulls a cache entry through the mocked remote backend" {
        InModuleScope CacheProvider {
            # In-memory stand-in for a cloud blob store.
            $script:__mockStore = @{}

            # Send-CachePut (CacheProvider.psm1) uploads with
            # `Invoke-WebRequest -Method Put -InFile`, NOT Invoke-RestMethod.
            # Mocking Invoke-RestMethod here never intercepted the push, so the
            # suite made a REAL request to example.blob.core.windows.net and
            # failed on DNS - a mock-backend test silently depending on network.
            Mock Invoke-WebRequest -ParameterFilter { $Method -eq 'Put' } -MockWith {
                $name = [System.IO.Path]::GetFileName($Uri)
                $script:__mockStore[$name] = if ($InFile -and (Test-Path -LiteralPath $InFile)) { [System.IO.File]::ReadAllBytes($InFile) } else { $Body }
                return [PSCustomObject]@{ StatusCode = 201 }
            }
            Mock Invoke-WebRequest -ParameterFilter { $Method -eq 'Get' } -MockWith {
                $name = [System.IO.Path]::GetFileName($Uri)
                $dest = $OutFile
                [System.IO.File]::WriteAllBytes($dest, $script:__mockStore[$name])
                return [PSCustomObject]@{ StatusCode = 200 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Head' } -MockWith {
                return [PSCustomObject]@{ StatusCode = 200; Headers = @{} }
            }
            Mock Invoke-WebRequest -ParameterFilter { $Method -eq 'Head' } -MockWith {
                return [PSCustomObject]@{ StatusCode = 200; Headers = @{} }
            }

            $state = [PSCustomObject]@{
                BuildConfig = [PSCustomObject]@{
                    build = [PSCustomObject]@{
                        cacheRemote = [PSCustomObject]@{
                            Enabled  = $true
                            Type     = 'azureBlob'
                            Endpoint = 'https://example.blob.core.windows.net'
                            Container = 'gbuild-cache'
                            Compress = $false
                        }
                    }
                }
                ScriptRoot = $TestDrive
            }

            $srcFile = Join-Path $TestDrive 'entry.bin'
            [System.IO.File]::WriteAllText($srcFile, 'gbuild-cache-entry')

            $sent = Send-CacheEntry -State $state -Key 'k1' -FilePath $srcFile
            $sent | Should -BeTrue

            $destFile = Join-Path $TestDrive 'restored.bin'
            $received = Receive-CacheEntry -State $state -Key 'k1' -Destination $destFile
            $received | Should -BeTrue
            Test-Path -Path $destFile | Should -BeTrue
            [System.IO.File]::ReadAllText($destFile) | Should -Be 'gbuild-cache-entry'
        }
    }

    It "Get-RemoteCacheConfig reads and defaults correctly" {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{} }
        $cfg = Get-RemoteCacheConfig -State $state
        $cfg.Enabled | Should -BeFalse
    }

    It "restores only the current tenant and ignores traversal names" {
        InModuleScope CacheProvider {
            $root = $TestDrive
            $state = [PSCustomObject]@{ TenantId = 'tenant-a'; ProjectRoot = $root; ScriptRoot = $root; BuildConfig = [PSCustomObject]@{ tenancy = [PSCustomObject]@{ isolation = 'directory' }; build = [PSCustomObject]@{ cacheDirectory = '.gbuildcache'; cacheRemote = [PSCustomObject]@{ Enabled = $true; Type = 'azureBlob'; Endpoint = 'https://example.blob.core.windows.net'; Container = 'gbuild-cache' } } } }
            Mock Invoke-RestMethod -MockWith { [xml]'<EnumerationResults><Blobs><Blob><Name>tenant-a/owned.bin</Name></Blob><Blob><Name>tenant-b/foreign.bin</Name></Blob><Blob><Name>../escape</Name></Blob></Blobs></EnumerationResults>' }
            $script:received = @()
            Mock Receive-CacheEntry -MockWith { $script:received += [PSCustomObject]@{ Key = $Key; Destination = $DestinationPath }; [System.IO.File]::WriteAllText($DestinationPath, 'owned'); return $true }
            $count = Update-CacheToLocal -State $state
            $count | Should -Be 1
            $script:received.Count | Should -Be 1
            $script:received[0].Key | Should -Be 'tenant-a/owned.bin'
            Test-Path -LiteralPath (Join-Path $root '.gbuildcache/tenant-a/owned.bin') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root '.gbuildcache/tenant-a/foreign.bin') | Should -BeFalse
        }
    }

    It "rejects oversized and checksum-mismatched remote content" {
        InModuleScope CacheProvider {
            $script:__mockStore = @{}
            # Send-CachePut uses Invoke-WebRequest -Method Put -InFile, not
            # Invoke-RestMethod - see the note in the roundtrip test above.
            Mock Invoke-WebRequest -ParameterFilter { $Method -eq 'Put' } -MockWith {
                $script:__mockStore[[System.IO.Path]::GetFileName($Uri)] = if ($InFile -and (Test-Path -LiteralPath $InFile)) { [System.IO.File]::ReadAllBytes($InFile) } else { $Body }
                return [PSCustomObject]@{ StatusCode = 201 }
            }
            Mock Invoke-WebRequest -ParameterFilter { $Method -eq 'Get' } -MockWith {
                [System.IO.File]::WriteAllBytes($OutFile, $script:__mockStore[[System.IO.Path]::GetFileName($Uri)])
                return [PSCustomObject]@{ StatusCode = 200 }
            }
            $state = [PSCustomObject]@{ TenantId = 'tenant-a'; ScriptRoot = $TestDrive; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = [PSCustomObject]@{ Enabled = $true; Type = 'azureBlob'; Endpoint = 'https://example.blob.core.windows.net'; Container = 'gbuild-cache'; MaxEntryBytes = 4; Compress = $false } } } }
            $source = Join-Path $TestDrive 'too-large.bin'
            [System.IO.File]::WriteAllBytes($source, [byte[]](1,2,3,4,5))
            Send-CacheEntry -State $state -Key 'large' -FilePath $source | Should -BeFalse
            $state.BuildConfig.build.cacheRemote.MaxEntryBytes = 32
            $expected = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            Send-CacheEntry -State $state -Key 'checksum' -FilePath $source -ExpectedSha256 $expected | Should -BeTrue
            $destination = Join-Path $TestDrive 'checksum.bin'
            Receive-CacheEntry -State $state -Key 'checksum' -DestinationPath $destination -ExpectedSha256 ('A' * 64) | Should -BeFalse
            Test-Path -LiteralPath $destination | Should -BeFalse
        }
    }
}
