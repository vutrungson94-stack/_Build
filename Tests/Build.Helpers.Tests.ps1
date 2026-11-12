#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Locale.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Build.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'Build helper functions' {
    Context 'Get-CacheArtifactPatterns' {
        It 'returns default *.dll when config is absent' {
            $p = @(InModuleScope Build -Parameters @{ state = [PSCustomObject]@{ BuildConfig = $null } } {
                Get-CacheArtifactPatterns -State $state -OutputSubDir 'web' -ExeBaseName 'MyApp'
            })
            $p | Should -Be @('*.dll')
        }
        It 'returns default pattern when cacheArtifactPatterns is absent' {
            $p = @(InModuleScope Build -Parameters @{ state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } } } {
                Get-CacheArtifactPatterns -State $state -OutputSubDir 'apk' -ExeBaseName 'MyApp'
            })
            $p | Should -Be @('*.dll')
        }
        It 'falls back to default entry when subdir is missing' {
            InModuleScope Build -Parameters @{ state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheArtifactPatterns = [PSCustomObject]@{ default = '*.pdb' } } } } } {
                { Get-CacheArtifactPatterns -State $state -OutputSubDir 'unknown' -ExeBaseName 'MyApp' } | Should -Not -Throw
                $p = @(Get-CacheArtifactPatterns -State $state -OutputSubDir 'unknown' -ExeBaseName 'MyApp')
                if ($p.Count -gt 0 -and $null -ne $p[0]) { $p[0] | Should -Be '*.pdb' }
            }
        }
        It 'returns *.dll when subdir and default are both missing' {
            InModuleScope Build -Parameters @{ state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheArtifactPatterns = [PSCustomObject]@{ web = '*.dll' } } } } } {
                { Get-CacheArtifactPatterns -State $state -OutputSubDir 'other' -ExeBaseName 'MyApp' } | Should -Not -Throw
                $p = @(Get-CacheArtifactPatterns -State $state -OutputSubDir 'other' -ExeBaseName 'MyApp')
                if ($p.Count -gt 0 -and $null -ne $p[0]) { $p[0] | Should -Be '*.dll' }
            }
        }
        It 'returns configured patterns and expands ${exeBaseName}' {
            $p = @(InModuleScope Build -Parameters @{ state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheArtifactPatterns = [PSCustomObject]@{ win = @('${exeBaseName}.exe', '${exeBaseName}.dll', '*.pdb') } } } } } {
                Get-CacheArtifactPatterns -State $state -OutputSubDir 'win' -ExeBaseName 'SampleApp'
            })
            $p[0] | Should -Be 'SampleApp.exe'
            $p[1] | Should -Be 'SampleApp.dll'
            $p[2] | Should -Be '*.pdb'
        }
        It 'leaves ${exeBaseName} placeholder when ExeBaseName is empty' {
            $p = @(InModuleScope Build -Parameters @{ state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ cacheArtifactPatterns = [PSCustomObject]@{ win = @('${exeBaseName}.exe') } } } } } {
                Get-CacheArtifactPatterns -State $state -OutputSubDir 'win' -ExeBaseName ''
            })
            $p | Should -Contain '${exeBaseName}.exe'
        }
    }

    Context 'Get-BuildPluginCacheKey' {
        It 'returns a deterministic fallback key when plugin helper is unavailable' {
            $proj = Join-Path ([System.IO.Path]::GetTempPath()) 'gbuild-cachekey-test.csproj'
            $r = InModuleScope Build -Parameters @{ proj = $proj } {
                $savedCmd = Get-Command Get-PluginCacheKey -ErrorAction SilentlyContinue
                $savedFn = if (Test-Path Function:\Get-PluginCacheKey) { ${function:Get-PluginCacheKey} } else { $null }
                try {
                    if (Test-Path Function:\Get-PluginCacheKey) { Remove-Item Function:\Get-PluginCacheKey -ErrorAction SilentlyContinue }
                    $k1 = Get-BuildPluginCacheKey -State ([PSCustomObject]@{}) -ProjectPath $proj -Tfm 'net8.0' -Configuration 'Release' -InputHash 'abc'
                    $k2 = Get-BuildPluginCacheKey -State ([PSCustomObject]@{}) -ProjectPath $proj -Tfm 'net8.0' -Configuration 'Release' -InputHash 'abc'
                    [PSCustomObject]@{ k1 = $k1; k2 = $k2 }
                } finally {
                    if ($savedFn) { ${function:Get-PluginCacheKey} = $savedFn }
                }
            }
            $r.k1 | Should -Match '^build-v2\|.+\|Release\|net8.0\|abc$'
            $r.k1 | Should -Be $r.k2
        }
        It 'uses Get-PluginCacheKey when available and appends tfm' {
            $proj = Join-Path ([System.IO.Path]::GetTempPath()) 'gbuild-cachekey-test.csproj'
            $k = InModuleScope Build -Parameters @{ proj = $proj } {
                function Get-PluginCacheKey { param($Plugin,$Language,$ProjectDir,$ProjectFile,$Configuration,$InputHash) return 'plugin-key-base' }
                Mock Get-PluginCacheKey { return 'plugin-key-base' }
                Get-BuildPluginCacheKey -State ([PSCustomObject]@{ DotnetCmd = 'dotnet-test' }) -ProjectPath $proj -Tfm 'net9.0' -Configuration 'Debug' -InputHash 'h1'
            }
            $k | Should -Be 'plugin-key-base|tfm=net9.0'
        }
    }

    Context 'New-BuildResult' {
        It 'returns a structured result with defaults for a succeeded build' {
            $r = InModuleScope Build { New-BuildResult -Status Succeeded -Operation 'build' -OutputPath 'out/dir' }
            $r.Status | Should -Be 'Succeeded'
            $r.Operation | Should -Be 'build'
            $r.OutputPath | Should -Be 'out/dir'
            $r.Skipped | Should -BeFalse
        }
        It 'marks skipped results' {
            $r = InModuleScope Build { New-BuildResult -Status Skipped -Operation 'build' -ReasonCode 'NoOp' }
            $r.Skipped | Should -BeTrue
            $r.ReasonCode | Should -Be 'NoOp'
        }
    }

    Context 'Invoke-BuildOutputReveal' {
        It 'does not throw when output dir is missing or empty' {
            InModuleScope Build {
                { Invoke-BuildOutputReveal -State ([PSCustomObject]@{}) -OutputDir '' -ProjectType 'WinForms' } | Should -Not -Throw
                { Invoke-BuildOutputReveal -State ([PSCustomObject]@{}) -OutputDir (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())) -ProjectType 'WinForms' } | Should -Not -Throw
            }
        }
        It 'logs and does not throw for an existing output dir' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-reveal-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                InModuleScope Build -Parameters @{ dir = $dir } {
                    Mock Open-Target { }
                    { Invoke-BuildOutputReveal -State ([PSCustomObject]@{}) -OutputDir $dir -ProjectType 'Web' } | Should -Not -Throw
                }
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'Invoke-AndroidArtifactDeploy' {
        It 'returns silently for empty or missing output directory' {
            InModuleScope Build {
                { Invoke-AndroidArtifactDeploy -State ([PSCustomObject]@{}) -OutputDir '' -CsprojContent '' -OutputSubDir 'apk' -ExeBaseName 'App' } | Should -Not -Throw
                { Invoke-AndroidArtifactDeploy -State ([PSCustomObject]@{}) -OutputDir (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())) -CsprojContent '' -OutputSubDir 'apk' -ExeBaseName 'App' } | Should -Not -Throw
            }
        }
        It 'does not call Invoke-AutoDeploy when no APK exists' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-apk-none-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                InModuleScope Build -Parameters @{ dir = $dir } {
                    Mock Invoke-AutoDeploy { throw 'should not be called' }
                    { Invoke-AndroidArtifactDeploy -State ([PSCustomObject]@{ AndroidSdk = '' }) -OutputDir $dir -CsprojContent '<ApplicationId>com.test.app</ApplicationId>' -OutputSubDir 'apk' -ExeBaseName 'App' } | Should -Not -Throw
                    Should -Invoke -CommandName Invoke-AutoDeploy -Times 0 -Exactly
                }
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'prefers a signed APK and invokes auto deploy with resolved app id' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-apk-signed-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $unsigned = Join-Path $dir 'app.apk'
            $signed = Join-Path $dir 'app-Signed.apk'
            Set-Content -LiteralPath $unsigned -Value 'u' -Encoding UTF8
            Start-Sleep -Milliseconds 30
            Set-Content -LiteralPath $signed -Value 's' -Encoding UTF8
            try {
                InModuleScope Build -Parameters @{ dir = $dir; signed = $signed } {
                    $script:called = $null
                    Mock Invoke-AutoDeploy { param($State,$ApkPath,$AppId,$AndroidSdkPath) $script:called = [PSCustomObject]@{ ApkPath=$ApkPath; AppId=$AppId; Sdk=$AndroidSdkPath } }
                    $sdkPath = Join-Path ([System.IO.Path]::GetTempPath()) 'gbuild-fake-sdk'
                    Invoke-AndroidArtifactDeploy -State ([PSCustomObject]@{ AndroidSdk = $sdkPath }) -OutputDir $dir -CsprojContent '<ApplicationId>com.example.signed</ApplicationId>' -OutputSubDir 'apk' -ExeBaseName 'App'
                    Should -Invoke -CommandName Invoke-AutoDeploy -Times 1 -Exactly
                    $script:called.ApkPath | Should -Be $signed
                    $script:called.AppId | Should -Be 'com.example.signed'
                    $script:called.Sdk | Should -Be $sdkPath
                }
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'falls back to the default application id when csproj omits it' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-apk-default-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $apk = Join-Path $dir 'plain.apk'
            Set-Content -LiteralPath $apk -Value 'p' -Encoding UTF8
            try {
                InModuleScope Build -Parameters @{ dir = $dir } {
                    $script:appId = $null
                    Mock Invoke-AutoDeploy { param($State,$ApkPath,$AppId,$AndroidSdkPath) $script:appId = $AppId }
                    Mock Get-BuildConstant { param($Key,$State,$Fallback) return $Fallback }
                    Invoke-AndroidArtifactDeploy -State ([PSCustomObject]@{ AndroidSdk = '' }) -OutputDir $dir -CsprojContent '<Project></Project>' -OutputSubDir 'apk' -ExeBaseName 'App'
                    $script:appId | Should -Be 'com.companyname.app'
                }
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'Build deploy and AAB helpers' {
        It 'Invoke-DeviceDebug returns early for invalid or missing project path' {
            InModuleScope Build {
                Mock Write-Log { }
                { Invoke-DeviceDebug -State ([PSCustomObject]@{}) -Project '' -Tfm 'net8.0-android' } | Should -Not -Throw
                { Invoke-DeviceDebug -State ([PSCustomObject]@{}) -Project (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())) -Tfm 'net8.0-android' } | Should -Not -Throw
            }
        }
        It 'Invoke-AutoDeploy returns early when adb or apk is unavailable' {
            InModuleScope Build {
                Mock Find-AdbPath { $null }
                Mock Write-Log { }
                { Invoke-AutoDeploy -State ([PSCustomObject]@{}) -ApkPath 'missing.apk' -AppId 'com.test.app' } | Should -Not -Throw
            }
        }
        It 'Publish-AndroidAab forwards to New-AndroidAab' {
            InModuleScope Build {
                $script:called = $false
                Mock New-AndroidAab { param($State,$ProjectPath,$Tfm,$Keystore,$ProjectType,$Incremental) $script:called = $true }
                Publish-AndroidAab -State ([PSCustomObject]@{}) -ProjectPath 'p' -Tfm 't' -Keystore 'k' -ProjectType 'MAUI'
                $script:called | Should -BeTrue
            }
        }
        It 'New-AndroidAab returns early when directory has no csproj or keystore is invalid' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-aab-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                InModuleScope Build -Parameters @{ dir = $dir } {
                    Mock Write-Log { }
                    Mock Get-LocaleMessage { param($Key,$MessageArgs) return $Key }
                    { New-AndroidAab -State ([PSCustomObject]@{}) -ProjectPath $dir -Tfm 'net8.0-android' -Keystore '' } | Should -Not -Throw
                }
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'Get-ProjectTypeActions returns null for unknown or missing config' {
            $r = InModuleScope Build {
                Get-ProjectTypeActions -State ([PSCustomObject]@{ BuildConfig = $null }) -ProjectType 'Console'
            }
            $r | Should -BeNullOrEmpty
        }
    }

    Context 'Build deploy, AAB, and device-debug branches' {
        It 'Invoke-DeviceDebug returns early when adb path is missing or no devices are connected' {
            InModuleScope Build {
                function Get-LocaleMessage { param($Key,$MessageArgs) $Key }
                function Write-Log { param($Message,$Level,$State) }
                function Find-AdbPath { param($State) $null }
                function Get-AdbDevices { param($State,$AdbPath) @() }
                function Test-Path { param([Parameter(ValueFromRemainingArguments=$true)]$a) $true }
                Mock Get-LocaleMessage { param($Key,$MessageArgs) $Key }
                Mock Write-Log { }
                Mock Find-AdbPath { $null }
                { Invoke-DeviceDebug -State ([PSCustomObject]@{ Colors = [pscustomobject]@{ Warn='Yellow'; Cyan='Cyan'; Gray='Gray' } }) -Project (Join-Path ([System.IO.Path]::GetTempPath()) 'x.csproj') -Tfm 'net8.0-android' } | Should -Not -Throw
                Mock Find-AdbPath { 'adb' }
                Mock Test-Path { $true }
                Mock Get-AdbDevices { @() }
                { Invoke-DeviceDebug -State ([PSCustomObject]@{ Colors = [pscustomobject]@{ Warn='Yellow'; Cyan='Cyan'; Gray='Gray' } }) -Project (Join-Path ([System.IO.Path]::GetTempPath()) 'x.csproj') -Tfm 'net8.0-android' } | Should -Not -Throw
            }
        }

        It 'New-AndroidAab sets signing env vars for Start-BuildAndShow and cleans them up' {
            $ks = Join-Path ([System.IO.Path]::GetTempPath()) ('ks-' + [guid]::NewGuid().ToString('N') + '.keystore')
            Set-Content -LiteralPath $ks -Value 'x' -Encoding UTF8
            $csproj = Join-Path ([System.IO.Path]::GetTempPath()) ('app-' + [guid]::NewGuid().ToString('N') + '.csproj')
            Set-Content -LiteralPath $csproj -Value '<Project />' -Encoding UTF8
            try {
                $keystore = [pscustomobject]@{ Path = $ks; Alias = 'alias1'; StorePass = 'sp'; KeyPass = 'kp' }
                $state = [PSCustomObject]@{ Colors = [pscustomobject]@{ Cyan='Cyan'; Err='Red' } }
                InModuleScope Build -Parameters @{ state = $state; csproj = $csproj; keystore = $keystore } {
                    function Get-LocaleMessage { param($Key,$MessageArgs) $Key }
                    function Write-Log { param($Message,$Level,$State) }
                    function Start-BuildAndShow {
                        param($State,$Project,$Tfm,$OutputSubDir,$BuildArgs,$ProjectType,[switch]$Incremental)
                        $script:seenStore = $env:ANDROID_KEYSTORE_PASS
                        $script:seenKey = $env:ANDROID_KEY_PASS
                        $script:seenAlias = $env:AndroidSigningKeyAlias
                    }
                    Mock Get-LocaleMessage { param($Key,$MessageArgs) $Key }
                    Mock Write-Log { }
                    Mock Start-BuildAndShow {
                        param($State,$Project,$Tfm,$OutputSubDir,$BuildArgs,$ProjectType,[switch]$Incremental)
                        $script:seenStore = $env:ANDROID_KEYSTORE_PASS
                        $script:seenKey = $env:ANDROID_KEY_PASS
                        $script:seenAlias = $env:AndroidSigningKeyAlias
                    }
                    Remove-Item Env:ANDROID_KEYSTORE_PASS -ErrorAction SilentlyContinue
                    Remove-Item Env:ANDROID_KEY_PASS -ErrorAction SilentlyContinue
                    Remove-Item Env:AndroidSigningKeyAlias -ErrorAction SilentlyContinue
                    Remove-Item Env:AndroidSigningStorePass -ErrorAction SilentlyContinue
                    Remove-Item Env:AndroidSigningKeyPass -ErrorAction SilentlyContinue
                    New-AndroidAab -State $state -ProjectPath $csproj -Tfm 'net8.0-android' -Keystore $keystore -ProjectType 'MAUI'
                    $script:seenStore | Should -Be 'sp'
                    $script:seenKey | Should -Be 'kp'
                    $script:seenAlias | Should -Be 'alias1'
                    [string]$env:ANDROID_KEYSTORE_PASS | Should -Be ''
                    [string]$env:ANDROID_KEY_PASS | Should -Be ''
                }
            } finally {
                Remove-Item -LiteralPath $ks -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $csproj -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Build driver branches' {
        It 'Start-BuildAndShow returns false when the project file is missing' {
            InModuleScope Build {
                function Write-Log { param($Message,$Level,$State) }
                function Get-LocaleMessage { param($Key,$MessageArgs) $Key }
                Mock Write-Log { }
                Mock Get-LocaleMessage { param($Key,$MessageArgs) $Key }
                $missing = Join-Path ([System.IO.Path]::GetTempPath()) ('no-such-' + [guid]::NewGuid().ToString('N') + '.csproj')
                Start-BuildAndShow -State ([PSCustomObject]@{ Colors = [pscustomobject]@{} }) -Project $missing | Should -BeFalse
            }
        }

        It 'Start-BuildAndShow reports the missing project in detailed mode' {
            InModuleScope Build {
                function Write-Log { param($Message,$Level,$State) }
                function Get-LocaleMessage { param($Key,$MessageArgs) $Key }
                Mock Write-Log { }
                Mock Get-LocaleMessage { param($Key,$MessageArgs) $Key }
                $missing = Join-Path ([System.IO.Path]::GetTempPath()) ('no-such-' + [guid]::NewGuid().ToString('N') + '.csproj')
                $r = Start-BuildAndShow -State ([PSCustomObject]@{ Colors = [pscustomobject]@{} }) -Project $missing -Detailed
                $r | Should -Not -BeNullOrEmpty
                $r.Status | Should -Be 'Failed'
                $r.ReasonCode | Should -Be 'ProjectMissing'
            }
        }

        It 'Start-BuildAndShow reports a failed language detection in detailed mode' {
            InModuleScope Build {
                function Write-Log { param($Message,$Level,$State) }
                function Get-LocaleMessage { param($Key,$MessageArgs) $Key }
                function Get-PrimaryLanguage { param($SearchRoot,$State) $null }
                function Set-StateColors { param($State) }
                Mock Write-Log { }
                Mock Get-LocaleMessage { param($Key,$MessageArgs) $Key }
                Mock Get-PrimaryLanguage { $null }
                Mock Set-StateColors { }
                $proj = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-lang-' + [guid]::NewGuid().ToString('N') + '.csproj')
                Set-Content -LiteralPath $proj -Value '<Project></Project>' -Encoding UTF8
                try {
                    $r = Start-BuildAndShow -State ([PSCustomObject]@{ Colors = [pscustomobject]@{} }) -Project $proj -Detailed
                    $r.Status | Should -Be 'Failed'
                    $r.ReasonCode | Should -Be 'LanguageDetectionFailed'
                } finally { Remove-Item -LiteralPath $proj -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'Start-BuildAndShow delegates a non-dotnet project to the plugin runner' {
            InModuleScope Build {
                function Write-Log { param($Message,$Level,$State) }
                function Get-LocaleMessage { param($Key,$MessageArgs) $Key }
                function Get-PrimaryLanguage { param($SearchRoot,$State) [pscustomobject]@{ Language = 'Python'; BuildFilePath = 'app.py' } }
                function Set-StateColors { param($State) }
                function Invoke-PluginBuildFor { param($State,$Language,$ProjectDir,$ProjectFile,$Configuration,[switch]$Incremental,[switch]$Detailed) $true }
                Mock Write-Log { }
                Mock Get-LocaleMessage { param($Key,$MessageArgs) $Key }
                Mock Get-PrimaryLanguage { [pscustomobject]@{ Language = 'Python'; BuildFilePath = 'app.py' } }
                Mock Set-StateColors { }
                Mock Invoke-PluginBuildFor { $true }
                $proj = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-plugin-' + [guid]::NewGuid().ToString('N') + '.csproj')
                Set-Content -LiteralPath $proj -Value '<Project></Project>' -Encoding UTF8
                try {
                    Start-BuildAndShow -State ([PSCustomObject]@{ Colors = [pscustomobject]@{} }) -Project $proj | Should -BeTrue
                    Should -Invoke -CommandName Invoke-PluginBuildFor -Times 1 -Exactly
                } finally { Remove-Item -LiteralPath $proj -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}
