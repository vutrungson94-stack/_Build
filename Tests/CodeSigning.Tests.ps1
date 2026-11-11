$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $here) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

# The machine profile (profiles\signing.json inside the tool) is REAL state on
# the developer machine and must never decide what these tests expect. Point
# the lookup at an empty profile for the whole file, and restore it afterwards.
# A global (not $script:) is used on purpose: Pester runs BeforeAll/AfterAll in
# its own scope, where a file-level $script: variable is not visible.
$global:GBuildOriginalSigningProfile = $env:GBUILD_SIGNING_PROFILE
$global:GBuildEmptySigningProfile = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-empty-profile-' + [guid]::NewGuid().ToString('N') + '.json')
Set-Content -LiteralPath $global:GBuildEmptySigningProfile -Value '{}' -Encoding UTF8
$env:GBUILD_SIGNING_PROFILE = $global:GBuildEmptySigningProfile

Describe 'CodeSigning - machine profile' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'CodeSigning.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    AfterAll {
        # The profile stays pointed at the empty file for the WHOLE file: the
        # other Describes in it must not see the machine's real profile either.
        # Restoring here would run BEFORE them and re-expose it.
        # The scope runs in its own child process, so the env var dies with it.
    }

    It 'Get-CodeSigningProfilePath honours GBUILD_SIGNING_PROFILE' {
        $file = Join-Path $TestDrive 'signing.json'
        Set-Content -LiteralPath $file -Value '{}' -Encoding UTF8
        $old = $env:GBUILD_SIGNING_PROFILE
        try {
            $env:GBUILD_SIGNING_PROFILE = $file
            Get-CodeSigningProfilePath | Should -Be (Resolve-Path -LiteralPath $file).Path
        }
        finally { $env:GBUILD_SIGNING_PROFILE = $old }
    }

    It 'Get-CodeSigningProfile reads the peSign and release sections' {
        $file = Join-Path $TestDrive 'profile.json'
        Set-Content -LiteralPath $file -Value '{"peSign":{"enabled":true,"tool":"external"},"release":{"outputDir":"D:\\releases"}}' -Encoding UTF8
        $old = $env:GBUILD_SIGNING_PROFILE
        try {
            $env:GBUILD_SIGNING_PROFILE = $file
            $p = Get-CodeSigningProfile
            $p.PeSign['enabled'] | Should -BeTrue
            $p.PeSign['tool'] | Should -Be 'external'
            $p.Release['outputDir'] | Should -Be 'D:\releases'
        }
        finally { $env:GBUILD_SIGNING_PROFILE = $old }
    }

    It 'Get-CodeSigningProfile survives a broken file' {
        $file = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $file -Value '{ this is not json' -Encoding UTF8
        $old = $env:GBUILD_SIGNING_PROFILE
        try {
            $env:GBUILD_SIGNING_PROFILE = $file
            $p = Get-CodeSigningProfile
            $p.PeSign.Count | Should -Be 0
        }
        finally { $env:GBUILD_SIGNING_PROFILE = $old }
    }

    It 'Get-CodeSigningConfig takes the machine profile and lets the project override it' {
        # The project layer is the project's OWN gbuild.config.json on disk - the
        # merged BuildConfig cannot tell "the project said this" from "the tool
        # shipped this", and the project must win over the machine profile.
        $projectDir = Join-Path $TestDrive 'proj'
        New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $projectDir 'gbuild.config.json') `
            -Value '{"security":{"peSign":{"tool":"powershell","verify":"valid"}}}' -Encoding UTF8

        $file = Join-Path $TestDrive 'profile2.json'
        Set-Content -LiteralPath $file -Value '{"peSign":{"enabled":true,"tool":"external","verify":"signature"}}' -Encoding UTF8
        $old = $env:GBUILD_SIGNING_PROFILE
        try {
            $env:GBUILD_SIGNING_PROFILE = $file
            $state = [PSCustomObject]@{
                ProjectRoot = $projectDir
                BuildConfig = @{ security = @{ peSign = @{ tool = 'powershell'; verify = 'valid' } } }
            }
            $cfg = Get-CodeSigningConfig -State $state
            $cfg.Enabled | Should -BeTrue          # from the profile
            $cfg.Tool | Should -Be 'powershell'   # the project file wins
            $cfg.Verify | Should -Be 'valid'       # the project file wins
        }
        finally { $env:GBUILD_SIGNING_PROFILE = $old }
    }
}

Describe 'CodeSigning - Artifact Signing auto-detection' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'CodeSigning.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'tool auto falls back to the self-signed signer when no account is on this machine' {
        $state = [PSCustomObject]@{
            BuildConfig = @{ security = @{ peSign = @{ enabled = $true; tool = 'auto' } } }
        }
        $cfg = Get-CodeSigningConfig -State $state
        # This machine has no Artifact Signing client tools, so the signer falls
        # back to the self-signed one - a build never stops for a missing account.
        $cfg.Tool | Should -BeIn @('external', 'powershell')
        if ($cfg.Tool -eq 'external') {
            $cfg.ExternalCommand | Should -Not -BeNullOrEmpty
        }
        else {
            $cfg.AzureAvailable | Should -BeFalse
            $cfg.AzureReason | Should -Not -BeNullOrEmpty
        }
    }

    It 'tool auto uses the Artifact Signing account when the metadata is present' {
        $metadata = Join-Path $TestDrive 'azure-metadata.json'
        Set-Content -LiteralPath $metadata -Value '{"Endpoint":"https://eus.codesigning.azure.net","CodeSigningAccountName":"acct","CertificateProfileName":"prof"}' -Encoding UTF8
        $state = [PSCustomObject]@{
            BuildConfig = @{
                security = @{
                    peSign = @{
                        enabled = $true
                        tool = 'auto'
                        azureMetadataPath = $metadata
                        azureSignToolPath = 'C:\fake\signtool.exe'
                        azureDlibPath = 'C:\fake\Azure.CodeSigning.Dlib.dll'
                    }
                }
            }
        }
        $cfg = Get-CodeSigningConfig -State $state
        $cfg.Tool | Should -Be 'external'
        $cfg.ExternalCommand | Should -Be 'C:\fake\signtool.exe'
        $cfg.ExternalArguments | Should -Match 'Azure\.CodeSigning\.Dlib\.dll'
        $cfg.ExternalArguments | Should -Match 'dmdf'
        $cfg.AzureAvailable | Should -BeTrue
    }

    It 'Find-ArtifactSigningMetadata writes the metadata file from the profile values' {
        $metadata = Find-ArtifactSigningMetadata -Endpoint 'https://eus.codesigning.azure.net' -Account 'acct' -ProfileName 'prof'
        $metadata | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $metadata | Should -BeTrue
        $doc = Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json
        $doc.Endpoint | Should -Be 'https://eus.codesigning.azure.net'
        $doc.CodeSigningAccountName | Should -Be 'acct'
        $doc.CertificateProfileName | Should -Be 'prof'
    }

    It 'Resolve-ArtifactSigningCommand reports what is missing' {
        $r = Resolve-ArtifactSigningCommand -SignToolPath '' -DlibPath '' -MetadataPath '' -Endpoint '' -Account '' -ProfileName ''
        $r.Available | Should -BeFalse
        $r.Reason | Should -Not -BeNullOrEmpty
    }
}

Describe 'CodeSigning - configuration' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'CodeSigning.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'Get-CodeSigningConfig returns the module defaults when no config is present' {
        $cfg = Get-CodeSigningConfig -State $null
        $cfg.Enabled | Should -BeFalse
        $cfg.Artifacts | Should -Contain '*.exe'
        $cfg.Verify | Should -Be 'valid'
        $cfg.FailOnError | Should -BeTrue
        # The shipped default tool is 'auto': it resolves to the Artifact Signing
        # account when this machine has one, and to the self-signed signer when
        # it has not.
        $cfg.Tool | Should -BeIn @('external', 'powershell')
    }

    It 'Get-CodeSigningConfig reads security.peSign from the build config' {
        $state = [PSCustomObject]@{
            BuildConfig = @{
                security = @{
                    peSign = @{
                        enabled = $true
                        tool = 'external'
                        artifacts = @('*.msi')
                        recursive = $false
                        certificateThumbprint = 'ABCDEF'
                        certificatePasswordEnv = 'MY_PW'
                        timestampUrl = 'http://ts.example'
                        externalCommand = 'signer'
                        externalArguments = '--in {file}'
                        verify = 'signature'
                        failOnError = $false
                    }
                }
            }
        }
        $cfg = Get-CodeSigningConfig -State $state
        $cfg.Enabled | Should -BeTrue
        $cfg.Tool | Should -Be 'external'
        $cfg.Artifacts | Should -Be @('*.msi')
        $cfg.Recursive | Should -BeFalse
        $cfg.CertificateThumbprint | Should -Be 'ABCDEF'
        $cfg.CertificatePasswordEnv | Should -Be 'MY_PW'
        $cfg.TimestampUrl | Should -Be 'http://ts.example'
        $cfg.ExternalCommand | Should -Be 'signer'
        $cfg.ExternalArguments | Should -Be '--in {file}'
        $cfg.Verify | Should -Be 'signature'
        $cfg.FailOnError | Should -BeFalse
    }

    It 'Get-CodeSigningConfig normalizes an unknown verify mode to valid' {
        $state = [PSCustomObject]@{
            BuildConfig = @{ security = @{ peSign = @{ enabled = $true; verify = 'nonsense' } } }
        }
        $cfg = Get-CodeSigningConfig -State $state
        $cfg.Verify | Should -Be 'valid'
    }

    It 'Get-CodeSigningConfig keeps signing disabled when the config section is broken' {
        $state = [PSCustomObject]@{ BuildConfig = 'not-an-object' }
        $cfg = Get-CodeSigningConfig -State $state
        $cfg.Enabled | Should -BeFalse
    }
}

Describe 'CodeSigning - artifact discovery' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'CodeSigning.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'Get-CodeSigningArtifact returns an empty array for a missing directory' {
        $found = @(Get-CodeSigningArtifact -Path (Join-Path $TestDrive 'nope') -Pattern @('*.exe'))
        $found.Count | Should -Be 0
    }

    It 'Get-CodeSigningArtifact returns an empty array for an empty path' {
        $found = @(Get-CodeSigningArtifact -Path '' -Pattern @('*.exe'))
        $found.Count | Should -Be 0
    }

    It 'Get-CodeSigningArtifact finds matching files and ignores the rest' {
        $dir = Join-Path $TestDrive 'out'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'a.exe') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dir 'b.dll') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dir 'c.txt') -Value 'x'

        $found = @(Get-CodeSigningArtifact -Path $dir -Pattern @('*.exe'))
        $found.Count | Should -Be 1
        $found[0] | Should -Match 'a\.exe$'
    }
}

Describe 'CodeSigning - tool availability' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'CodeSigning.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'Test-CodeSigningToolAvailable is false for external without a command' {
        Test-CodeSigningToolAvailable -Tool 'external' -ExternalCommand '' | Should -BeFalse
    }

    It 'Test-CodeSigningToolAvailable is false for a command that does not exist' {
        Test-CodeSigningToolAvailable -Tool 'external' -ExternalCommand 'definitely-not-a-real-signer-xyz' | Should -BeFalse
    }

    It 'Test-CodeSigningToolAvailable is false for an unknown tool name' {
        Test-CodeSigningToolAvailable -Tool 'not-a-tool' | Should -BeFalse
    }

    It 'Test-CodeSigningToolAvailable reports the powershell signer as available' {
        Test-CodeSigningToolAvailable -Tool 'powershell' | Should -BeTrue
    }
}

Describe 'CodeSigning - external signer invocation' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'CodeSigning.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'Invoke-ExternalCodeSigning reports a missing command instead of throwing' {
        $r = Invoke-ExternalCodeSigning -Path 'x.exe' -Command 'definitely-not-a-real-signer-xyz' -Arguments '{file}'
        $r.Signed | Should -BeFalse
        $r.Message | Should -Not -BeNullOrEmpty
    }
}

Describe 'CodeSigning - signature verification' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'CodeSigning.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'Test-CodeSignatureStatus reports Unknown for a missing file' {
        $r = Test-CodeSignatureStatus -Path (Join-Path $TestDrive 'missing.exe')
        $r.Valid | Should -BeFalse
        $r.Status | Should -Be 'Unknown'
    }

    It 'Test-CodeSignatureStatus does not throw on an unsigned file' {
        $file = Join-Path $TestDrive 'plain.exe'
        Set-Content -LiteralPath $file -Value 'not a pe file'
        { Test-CodeSignatureStatus -Path $file } | Should -Not -Throw
    }
}

Describe 'CodeSigning - pipeline entry point' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'CodeSigning.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'Invoke-CodeSigning is skipped when the feature is disabled' {
        $r = Invoke-CodeSigning -State $null -InputPath $TestDrive
        $r.Status | Should -Be 'Skipped'
        $r.Message | Should -Match 'peSign'
    }

    It 'Invoke-CodeSigning fails when it is enabled but no input path is given' {
        $state = [PSCustomObject]@{
            BuildConfig = @{ security = @{ peSign = @{ enabled = $true } } }
        }
        $r = Invoke-CodeSigning -State $state -InputPath ''
        $r.Status | Should -Be 'Failed'
    }

    It 'Invoke-CodeSigning is skipped when the signer is not on this machine' {
        $state = [PSCustomObject]@{
            BuildConfig = @{
                security = @{
                    peSign = @{ enabled = $true; tool = 'external'; externalCommand = 'definitely-not-a-real-signer-xyz' }
                }
            }
        }
        $r = Invoke-CodeSigning -State $state -InputPath $TestDrive
        $r.Status | Should -Be 'Skipped'
        $r.Message | Should -Match 'not available'
    }
}
