#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

$global:cpTemp = New-IntegrationTempDir
$global:cpState = [PSCustomObject]@{ ScriptRoot = $global:cpTemp; CorrelationId = 'cp-it' }

Describe "CacheProvider Config" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'CacheProvider.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterAll {
        if ($global:cpTemp -and (Test-Path $global:cpTemp)) { Remove-Item $global:cpTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    AfterEach {
        if (Test-Path Env:GBUILD_TEST_SAS) { Remove-Item Env:GBUILD_TEST_SAS -ErrorAction SilentlyContinue }
    }

    It "Get-RemoteCacheConfig returns a disabled default when no config present" {
        $cfg = Get-RemoteCacheConfig -State $global:cpState
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.Enabled | Should -BeFalse
        $cfg.Type | Should -Be 'azureBlob'
    }

    It "Get-RemoteCacheConfig reads config from State and resolves env placeholders" {
        $env:GBUILD_TEST_SAS = 'sas-from-env'
        $state = [PSCustomObject]@{
            ScriptRoot  = $global:cpTemp
            BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = [PSCustomObject]@{ Enabled = $true; Type = 'awsS3'; Container = 'mybucket'; AuthToken = '${env:GBUILD_TEST_SAS}' } } }
        }
        $cfg = Get-RemoteCacheConfig -State $state
        $cfg.Enabled   | Should -BeTrue
        $cfg.Type      | Should -Be 'awsS3'
        $cfg.Container | Should -Be 'mybucket'
        $cfg.AuthToken | Should -Be 'sas-from-env'
    }

    It "Send-CacheEntry returns false when remote cache is disabled" {
        Send-CacheEntry -State $global:cpState -Key 'x' -FilePath 'nope.txt' | Should -BeFalse
    }

    It "Receive-CacheEntry returns false when remote cache is disabled" {
        Receive-CacheEntry -State $global:cpState -Key 'x' -DestinationPath (Join-Path $global:cpTemp 'out.bin') | Should -BeFalse
    }

    It "Test-CacheEntryExists returns false when remote cache is disabled" {
        Test-CacheEntryExists -State $global:cpState -Key 'x' | Should -BeFalse
    }

    It "Update-CacheToLocal returns 0 when remote cache is disabled" {
        Update-CacheToLocal -State $global:cpState | Should -Be 0
    }

    It "Update-CacheToRemote returns 0 when remote cache is disabled" {
        Update-CacheToRemote -State $global:cpState | Should -Be 0
    }

    It "rejects traversal keys before remote access" {
        $state = [PSCustomObject]@{ TenantId = 'tenant-a'; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = [PSCustomObject]@{ Enabled = $true; Type = 'azureBlob'; Endpoint = 'https://example.invalid'; Container = 'cache' } } } }
        Send-CacheEntry -State $state -Key '..\outside' -FilePath (Join-Path $global:cpTemp 'missing') | Should -BeFalse
        Receive-CacheEntry -State $state -Key '../outside' -DestinationPath (Join-Path $global:cpTemp 'outside') | Should -BeFalse
    }

    It "rejects a destination outside the state roots" {
        $state = [PSCustomObject]@{ ScriptRoot = $global:cpTemp; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = [PSCustomObject]@{ Enabled = $true; Type = 'azureBlob'; Endpoint = 'https://example.invalid'; Container = 'cache' } } } }
        Receive-CacheEntry -State $state -Key 'entry' -DestinationPath (Join-Path (Get-Location) 'cp-outside.bin') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path (Get-Location) 'cp-outside.bin') | Should -BeFalse
    }

    It "uses the bounded downloader for S3 presigned fallback and rejects checksum mismatch" {
        $global:cpS3Destination = Join-Path $global:cpTemp 's3-fallback.bin'
        if (Test-Path -LiteralPath $global:cpS3Destination) { Remove-Item -LiteralPath $global:cpS3Destination -Force -ErrorAction SilentlyContinue }
        InModuleScope CacheProvider {
            $state = [PSCustomObject]@{ TenantId = 'tenant-a'; ScriptRoot = $global:cpTemp; BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheRemote = [PSCustomObject]@{ Enabled = $true; Type = 'awsS3'; Container = 'mybucket'; Endpoint = 'https://example.invalid'; MaxEntryBytes = 32 } } } }
            Mock Get-Command { [PSCustomObject]@{ Name = 'stub'; Source = 'stub'; CommandType = 'Function' } } -ParameterFilter { $Name -ne 'aws' }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'aws' }
            Mock New-S3SignedUrl { 'https://example.invalid/mybucket/tenant-a/entry' }
            $script:boundedFallbackCalls = 0
            Mock Invoke-BoundedCacheDownload {
                $script:boundedFallbackCalls++
                [System.IO.File]::WriteAllBytes($Path, [byte[]](1,2,3))
                return [PSCustomObject]@{ StatusCode = 200; Headers = @{} }
            }
            Receive-CacheEntry -State $state -Key 'entry' -DestinationPath $global:cpS3Destination -ExpectedSha256 ('B' * 64) | Should -BeFalse
            $script:boundedFallbackCalls | Should -Be 1
        }
        Test-Path -LiteralPath $global:cpS3Destination | Should -BeFalse
    }

    It "accepts only the current tenant prefix during restore" {
        InModuleScope CacheProvider {
            $state = [PSCustomObject]@{ TenantId = 'tenant-a' }
            Get-CacheLogicalKey -State $state -RemoteKey 'tenant-a/file.bin' | Should -Be 'file.bin'
            Get-CacheLogicalKey -State $state -RemoteKey 'tenant-b/file.bin' | Should -BeNullOrEmpty
            Get-CacheLogicalKey -State $state -RemoteKey '../escape' | Should -BeNullOrEmpty
        }
    }

    It "restores AWS environment variables after an exception" {
        $env:GBUILD_TEST_AWS = 'original'
        $env:AWS_ACCESS_KEY_ID = 'ambient'
        try {
            InModuleScope CacheProvider {
                $before = $env:AWS_ACCESS_KEY_ID
                try { Invoke-WithAwsCredentials -Credentials ([PSCustomObject]@{ AccessKey = 'scoped'; SecretKey = 'secret' }) -Region 'test-region' -ScriptBlock { throw 'boom' } } catch { }
                $env:AWS_ACCESS_KEY_ID | Should -Be $before
            }
        } finally {
            Remove-Item Env:GBUILD_TEST_AWS -ErrorAction SilentlyContinue
            Remove-Item Env:AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
        }
    }

    It "releases the AWS credential lock after use" {
        InModuleScope CacheProvider {
            $credentials = [PSCustomObject]@{ AccessKey = 'scoped'; SecretKey = 'secret' }
            { Invoke-WithAwsCredentials -Credentials $credentials -ScriptBlock { $true } } | Should -Not -Throw
            { Invoke-WithAwsCredentials -Credentials $credentials -ScriptBlock { $true } } | Should -Not -Throw
        }
    }

    It "streams the upload file instead of buffering the whole file" {
        $global:cpUploadPath = Join-Path $global:cpTemp 'upload.bin'
        [System.IO.File]::WriteAllBytes($global:cpUploadPath, [byte[]](1,2,3))
        InModuleScope CacheProvider {
            $script:putInFile = ''
            Mock Invoke-WebRequest { $script:putInFile = $InFile; return [PSCustomObject]@{ StatusCode = 201 } }
            $sent = Send-CachePut -Url 'https://example.invalid/cache/entry' -Headers @{} -WorkFile $global:cpUploadPath -LogMessage 'upload' -State ([PSCustomObject]@{}) -MaxBytes 0
            $sent | Should -BeTrue
            $script:putInFile | Should -Be $global:cpUploadPath
        }
        Remove-Variable -Name cpUploadPath -Scope Global -ErrorAction SilentlyContinue
    }
}
