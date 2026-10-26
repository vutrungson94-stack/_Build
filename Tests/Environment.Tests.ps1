#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "Environment" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Environment.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    BeforeEach {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_env_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $global:state = [PSCustomObject]@{
            ScriptRoot = $tempDir
            WorkingDir = $tempDir
            TempFiles  = [System.Collections.Generic.List[string]]::new()
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # ── Get-SafePath ────────────────────────────────────────────────────
    It "Get-SafePath returns a non-empty string for an existing directory" {
        $r = Get-SafePath -Path $tempDir
        $r | Should -Not -BeNullOrEmpty
    }

    It "Get-SafePath returns the original path for a non-existent path" {
        # The path must be syntactically native: POSIX GetFullPath on
        # 'C:\does\not\exist 123' yields a cwd-relative /.../C:\... string.
        $missing = if ($env:OS -eq 'Windows_NT') { 'C:\does\not\exist 123' } else { '/does/not/exist 123' }
        $r = Get-SafePath -Path $missing
        $r | Should -Be $missing
    }

    # ── Save/Read-JsonSafe round-trip ───────────────────────────────────
    It "Save-JsonSafe then Read-JsonSafe round-trips data" {
        $file = Join-Path $tempDir 't.json'
        Save-JsonSafe -Data @{ a = 1 } -FilePath $file
        $data = Read-JsonSafe -FilePath $file
        $data.a | Should -Be 1
    }

    It "Saved JSON file is readable back as valid UTF-8" {
        $file = Join-Path $tempDir 't.json'
        Save-JsonSafe -Data @{ a = 1 } -FilePath $file
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $bytes.Count | Should -BeGreaterThan 0
        $text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
        $text | Should -BeLike '*"a"*'
    }

    It "Read-JsonSafe returns null for a missing file" {
        Read-JsonSafe -FilePath (Join-Path $tempDir 'missing.json') | Should -Be $null
    }

    It "Read-JsonSafe returns null for corrupt JSON" {
        $file = Join-Path $tempDir 'corrupt.json'
        [System.IO.File]::WriteAllText($file, '{"a": }')
        Read-JsonSafe -FilePath $file | Should -Be $null
    }

    # ── Get-RuntimeIdentifier ────────────────────────────────────────────
    It "Get-RuntimeIdentifier returns a valid RID" {
        $rid = Get-RuntimeIdentifier
        $rid | Should -BeIn @('win-x64','win-arm64','osx-x64','osx-arm64','linux-x64','linux-arm64')
    }

    # ── Test-PortListening ───────────────────────────────────────────────
    It "Test-PortListening returns a bool for port 1" {
        $r = Test-PortListening -Port 1
        $r | Should -BeOfType [bool]
    }

    # ── Wait-PortRelease ─────────────────────────────────────────────────
    It "Wait-PortRelease is exported" {
        Get-Command Wait-PortRelease -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Wait-PortRelease returns true immediately for a closed port" {
        $r = Wait-PortRelease -Port 1 -Attempts 2 -DelayMs 1 -Mode 'Listening'
        $r | Should -Be $true
    }

    It "Wait-PortRelease Bindable mode returns true for a closed port" {
        $r = Wait-PortRelease -Port 1 -Attempts 2 -DelayMs 1 -Mode 'Bindable'
        $r | Should -Be $true
    }

    # ── Get-AvailableDrives ──────────────────────────────────────────────
    It "Get-AvailableDrives returns an array (or null) without throwing" {
        $r = Get-AvailableDrives
        ($r -is [System.Array]) -or ($null -eq $r) | Should -Be $true
    }

    # ── Register-TempFile ────────────────────────────────────────────────
    It "Register-TempFile adds path to State.TempFiles" {
        $f = Join-Path $tempDir 'tmp.txt'
        Set-Content -LiteralPath $f -Value 'x' -Encoding UTF8
        Register-TempFile -State $global:state -Path $f
        $global:state.TempFiles.Contains($f) | Should -Be $true
    }

    # ── Invoke-CompatibleChildItem ───────────────────────────────────────
    It "Invoke-CompatibleChildItem returns files under temp dir" {
        $f = Join-Path $tempDir 'child.txt'
        Set-Content -LiteralPath $f -Value 'x' -Encoding UTF8
        $items = Invoke-CompatibleChildItem -Path $tempDir -File
        $items.Count | Should -BeGreaterThan 0
    }
}
