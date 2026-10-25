Set-StrictMode -Version 1.0

$modulePath = Join-Path $PSScriptRoot '../Modules/PluginSDK.psm1'
Import-Module $modulePath -Force -DisableNameChecking

Describe 'PluginSDK semver' {
    It 'Parses full semver with prerelease' {
        $v = ConvertTo-PluginVersion -Version '1.2.3-beta.1'
        $v.Valid | Should -BeTrue
        $v.Major | Should -Be 1
        $v.Minor | Should -Be 2
        $v.Patch | Should -Be 3
        $v.Prerelease | Should -Be 'beta.1'
    }

    It 'Compares versions numerically (not lexically)' {
        Compare-PluginVersion -Left '1.2.3' -Right '1.2.4' | Should -Be -1
        Compare-PluginVersion -Left '2.0.0' -Right '1.9.9' | Should -Be 1
        Compare-PluginVersion -Left '1.2.3' -Right '1.2.3' | Should -Be 0
    }

    It 'Orders release above prerelease' {
        Compare-PluginVersion -Left '1.0.0' -Right '1.0.0-beta' | Should -Be 1
    }

    It 'Evaluates caret, tilde and range constraints' {
        Test-PluginVersionConstraint -Version '1.9.0' -Constraint '^1.2.0' | Should -BeTrue
        Test-PluginVersionConstraint -Version '2.0.0' -Constraint '^1.2.0' | Should -BeFalse
        Test-PluginVersionConstraint -Version '1.5.0' -Constraint '>=1.2.0 <2.0.0' | Should -BeTrue
        Test-PluginVersionConstraint -Version '1.2.9' -Constraint '~1.2.0' | Should -BeTrue
        Test-PluginVersionConstraint -Version '1.3.0' -Constraint '~1.2.0' | Should -BeFalse
    }
}

Describe 'PluginSDK manifest' {
    It 'Reads every shipped sidecar manifest and validates it' {
        $files = Get-ChildItem -Path (Join-Path $PSScriptRoot '../Modules/Plugins/*.psm1') -File
        $files.Count | Should -BeGreaterThan 0
        foreach ($f in $files) {
            $mf = Get-PluginManifest -PluginPath $f.FullName
            $mf.manifestFound | Should -BeTrue -Because "$($f.BaseName) must ship a sidecar manifest"
            $t = Test-PluginManifest -Manifest $mf
            $t.Valid | Should -BeTrue -Because "$($f.BaseName): $(($t.Errors -join ';'))"
        }
    }

    It 'Synthesizes a manifest for plugins without a file' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_fakeplug_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.psm1')
        'function Get-PluginInfo { [PSCustomObject]@{ Name = ''FakeNoFile''; SupportedLanguages = @(''FakeLang''); Priority = 5 } }' | Set-Content -LiteralPath $tmp -Encoding UTF8
        try {
            $info = [PSCustomObject]@{ Name = 'FakeNoFile'; SupportedLanguages = @('FakeLang'); Priority = 5 }
            $mf = Get-PluginManifest -PluginPath $tmp -PluginInfo $info
            $mf.manifestFound | Should -BeFalse
            $mf.name | Should -Be 'FakeNoFile'
            $t = Test-PluginManifest -Manifest $mf
            $t.Valid | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Rejects a manifest missing required fields' {
        $bad = [PSCustomObject]@{ version = '1.0.0' }
        $t = Test-PluginManifest -Manifest $bad
        $t.Valid | Should -BeFalse
    }
}

Describe 'PluginSDK compatibility' {
    BeforeAll {
        $script:SdkState = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ plugins = [PSCustomObject]@{ enabled = $true } } }
        }
    }

    It 'Accepts the shipped Node manifest under default policy' {
        $mf = Get-PluginManifest -PluginPath (Join-Path $PSScriptRoot '../Modules/Plugins/Node.psm1')
        $c = Test-PluginCompatibility -Manifest $mf -State $script:SdkState
        $c.Compatible | Should -BeTrue
    }

    It 'Honors the disabled block-list' {
        $mf = Get-PluginManifest -PluginPath (Join-Path $PSScriptRoot '../Modules/Plugins/Node.psm1')
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ plugins = [PSCustomObject]@{ enabled = $true; disabled = @('Node') } } } }
        $c = Test-PluginCompatibility -Manifest $mf -State $st
        $c.Compatible | Should -BeFalse
    }

    It 'Blocks prereleases unless explicitly allowed' {
        $mf = New-PluginManifestTemplate -Name 'Pre' -SupportedLanguages @('PreLang')
        $mf.version = '2.0.0-beta.1'
        $deny = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ plugins = [PSCustomObject]@{ enabled = $true; allowPrerelease = $false } } } }
        (Test-PluginCompatibility -Manifest $mf -State $deny).Compatible | Should -BeFalse
        $allow = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ plugins = [PSCustomObject]@{ enabled = $true; allowPrerelease = $true } } } }
        (Test-PluginCompatibility -Manifest $mf -State $allow).Compatible | Should -BeTrue
    }

    It 'Rejects plugins newer than the SDK API' {
        $mf = New-PluginManifestTemplate -Name 'Future' -SupportedLanguages @('FutureLang')
        $mf.apiVersion = '99.0.0'
        $c = Test-PluginCompatibility -Manifest $mf -State $script:SdkState
        $c.Compatible | Should -BeFalse
    }
}

Describe 'PluginSDK dependencies' {
    It 'Orders Avalonia after Dotnet and detects no missing deps' {
        $files = Get-ChildItem -Path (Join-Path $PSScriptRoot '../Modules/Plugins/*.psm1') -File
        $mfs = @($files | ForEach-Object { Get-PluginManifest -PluginPath $_.FullName })
        $dep = Resolve-PluginDependencies -Manifests $mfs
        $dep.Valid | Should -BeTrue
        $dep.Missing.Count | Should -Be 0
        $names = @($dep.Ordered | ForEach-Object { $_.name })
        $names | Should -Contain 'Dotnet'
        $names | Should -Contain 'Avalonia'
        $names.IndexOf('Dotnet') | Should -BeLessThan $names.IndexOf('Avalonia')
    }

    It 'Reports missing and circular dependencies' {
        $a = New-PluginManifestTemplate -Name 'A' -SupportedLanguages @('ALang')
        $a | Add-Member -MemberType NoteProperty -Name 'dependencies' -Value @([PSCustomObject]@{ name = 'Ghost'; version = '*' }) -Force
        $dep = Resolve-PluginDependencies -Manifests @($a)
        $dep.Missing | Should -Contain 'Ghost'
        $b = New-PluginManifestTemplate -Name 'B' -SupportedLanguages @('BLang')
        $b | Add-Member -MemberType NoteProperty -Name 'dependencies' -Value @([PSCustomObject]@{ name = 'C' }) -Force
        $c = New-PluginManifestTemplate -Name 'C' -SupportedLanguages @('CLang')
        $c | Add-Member -MemberType NoteProperty -Name 'dependencies' -Value @([PSCustomObject]@{ name = 'B' }) -Force
        $dep2 = Resolve-PluginDependencies -Manifests @($b, $c)
        $dep2.Valid | Should -BeFalse
    }
}

Describe 'PluginSDK - P0 binding regressions' {
    It 'rejects an invalid sidecar without synthesizing a valid manifest' {
        $dir = Join-Path $TestDrive 'sdk-invalid'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $module = Join-Path $dir 'BadJson.psm1'
        Set-Content -LiteralPath $module -Value 'function Get-PluginInfo { [PSCustomObject]@{ Name = "BadJson" } }' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'BadJson.plugin.json') -Value '{bad' -Encoding UTF8
        $manifest = Get-PluginManifest -PluginPath $module
        $manifest.manifestFound | Should -BeTrue
        (Test-PluginManifest -Manifest $manifest).Valid | Should -BeFalse
    }
    It 'rejects an entryPoint that escapes the plugin module path' {
        $module = Join-Path (Join-Path $PSScriptRoot '../Modules/Plugins') 'Node.psm1'
        $manifest = Get-PluginManifest -PluginPath $module
        $manifest.entryPoint = '..\Other.psm1'
        (Test-PluginManifest -Manifest $manifest).Valid | Should -BeFalse
    }
    It 'marks missing dependencies invalid' {
        $manifest = New-PluginManifestTemplate -Name 'NeedsGhost' -SupportedLanguages @('Test')
        $manifest.dependencies = @([PSCustomObject]@{ name = 'Ghost'; version = '1.0.0' })
        (Resolve-PluginDependencies -Manifests @($manifest)).Valid | Should -BeFalse
    }
}
