$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $here) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'Release - version resolution' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Release.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'Get-BuildReleaseVersion falls back to 0.0.0 without a project' {
        $v = Get-BuildReleaseVersion -ProjectDir '' -ProjectName 'demo'
        $v.Version | Should -Be '0.0.0'
        $v.ProjectName | Should -Be 'demo'
        $v.Commit | Should -Not -BeNullOrEmpty
    }

    It 'Get-BuildReleaseVersion reads the version from the project file' {
        $dir = Join-Path $TestDrive 'proj'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Demo.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><Version>2.3.4</Version></PropertyGroup></Project>'
        $v = Get-BuildReleaseVersion -ProjectDir $dir -ProjectName 'demo'
        $v.Version | Should -Be '2.3.4'
    }
}

Describe 'Release - packaging' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'Release.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $script:src = Join-Path $TestDrive 'publish'
        New-Item -ItemType Directory -Path $script:src -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:src 'app.exe') -Value 'binary'
        Set-Content -LiteralPath (Join-Path $script:src 'readme.txt') -Value 'hello'
        New-Item -ItemType Directory -Path (Join-Path $script:src 'obj') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path (Join-Path $script:src 'obj') 'junk.dll') -Value 'junk'
    }

    It 'New-BuildReleasePackage is skipped when there is no output' {
        $r = New-BuildReleasePackage -SourceDir (Join-Path $TestDrive 'nope') -ProjectName 'demo'
        $r.Status | Should -Be 'Skipped'
    }

    It 'New-BuildReleasePackage creates the archive, the checksum and the manifest' {
        $out = Join-Path $TestDrive 'release'
        $r = New-BuildReleasePackage -SourceDir $script:src -ProjectRoot $TestDrive -ProjectName 'demo' -OutputDir $out
        $r.Status | Should -Be 'Succeeded'
        Test-Path -LiteralPath $r.Archive | Should -BeTrue
        Test-Path -LiteralPath $r.Checksum | Should -BeTrue
        Test-Path -LiteralPath $r.Manifest | Should -BeTrue

        $hash = (Get-FileHash -LiteralPath $r.Archive -Algorithm SHA256).Hash.ToLowerInvariant()
        (Get-Content -LiteralPath $r.Checksum -Raw).Should -Match ([regex]::Escape($hash))

        $manifest = Get-Content -LiteralPath $r.Manifest -Raw | ConvertFrom-Json
        $manifest.project | Should -Be 'demo'
        $manifest.sha256 | Should -Be $hash
        $manifest.sizeBytes | Should -BeGreaterThan 0
    }

    It 'New-BuildReleasePackage leaves build junk out of the archive' {
        $out = Join-Path $TestDrive 'release2'
        $r = New-BuildReleasePackage -SourceDir $script:src -ProjectRoot $TestDrive -ProjectName 'demo' -OutputDir $out
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($r.Archive)
        try {
            $names = @($zip.Entries | ForEach-Object { $_.FullName })
            ($names -join ';') | Should -Not -Match 'obj'
            ($names -join ';') | Should -Match 'app\.exe'
        }
        finally { $zip.Dispose() }
    }

    It 'New-BuildReleasePackage copies the package to the destination' {
        $out = Join-Path $TestDrive 'release3'
        $dest = Join-Path $TestDrive 'shared'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        $r = New-BuildReleasePackage -SourceDir $script:src -ProjectRoot $TestDrive -ProjectName 'demo' -OutputDir $out -DestinationDir $dest
        $r.Copied | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $r.Copied | Should -BeTrue
        Test-Path -LiteralPath ($r.Copied + '.sha256') | Should -BeTrue
        Test-Path -LiteralPath ($r.Copied + '.json') | Should -BeTrue
    }
}
