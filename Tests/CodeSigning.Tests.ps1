$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $here) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'CodeSigning - configuration' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'CodeSigning.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'Get-CodeSigningConfig returns the module defaults when no config is present' {
        $cfg = Get-CodeSigningConfig -State $null
        $cfg.Enabled | Should -BeFalse
        $cfg.Tool | Should -Be 'signtool'
        $cfg.Artifacts | Should -Contain '*.exe'
        $cfg.Verify | Should -Be 'valid'
        $cfg.FailOnError | Should -BeTrue
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
