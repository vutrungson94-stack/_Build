#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'

# PS 5.1 does NOT define $IsWindows/$IsLinux/$IsMacOS automatic variables (PS7 does,
# as read-only constants). Helper functions evaluate at Pester discovery-time without
# ever reassigning the automatic variables, so -Skip conditions work on both engines.
function Test-IsWindowsHost {
    try { return [bool]$IsWindows }
    catch { return ($PSVersionTable.Platform -eq 'Win32NT') -or ($PSVersionTable.OS -like '*Windows*') -or ($env:OS -eq 'Windows_NT') }
}
function Test-IsUnixHost {
    try { return [bool]$IsLinux -or [bool]$IsMacOS }
    catch { return -not (Test-IsWindowsHost) }
}

BeforeAll {
    $null = Import-Module (Join-Path $global:GBuildModuleRoot 'PathUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    $global:sep = [System.IO.Path]::DirectorySeparatorChar
}
AfterAll {
    Remove-Module PathUtils -Force -ErrorAction SilentlyContinue
}

Describe 'Cross-Platform Path Handling' {
    It 'ConvertTo-ForwardSlash produces a separator-agnostic canonical form' {
        ConvertTo-ForwardSlash -Path 'repo\src\file.cs' | Should -Be 'repo/src/file.cs'
    }

    It 'Format-Path yields the same logical path for backslash and forward-slash input' {
        $a = Format-Path -Path 'repo\src'
        $b = Format-Path -Path 'repo/src'
        ($a -replace '\\', '/') | Should -Be ($b -replace '\\', '/')
    }

    It 'Format-Path collapses mixed separators to OS separator on the current platform' {
        $r = Format-Path -Path 'a/b\c/d'
        $r | Should -Not -Match '\\\\'   # no doubled separators
        ($r -replace '\\', '/') | Should -Be 'a/b/c/d'
    }

    It 'Format-Path anchors a relative path under Base' {
        $base = Join-Path $env:TEMP 'gplat_base'
        $r = Format-Path -Path 'sub\child' -Base $base
        $r | Should -Be (Join-Path $base 'sub\child')
    }

    It 'Get-SafeJoinPath is consistent regardless of input separator style' {
        $win = Get-SafeJoinPath -Base 'C:\repo' -Child 'src\mod'
        $mix = Get-SafeJoinPath -Base 'C:\repo' -Child 'src/mod'
        ($win -replace '\\', '/') | Should -Be ($mix -replace '\\', '/')
    }

    It 'Test-SafePath contains a Windows-style nested path under a Windows base' -Skip:(-not (Test-IsWindowsHost)) {
        $base = 'C:\gbplat\root'
        Test-SafePath -Path 'C:\gbplat\root\sub\file' -Base $base | Should -BeTrue
    }

    It 'Test-SafePath rejects a Windows-style escape outside the base' -Skip:(-not (Test-IsWindowsHost)) {
        $base = 'C:\gbplat\root'
        Test-SafePath -Path 'C:\gbplat\root\..\..\Windows\system32' -Base $base | Should -BeFalse
    }

    It 'Test-SafePath contains a Unix-style nested path under a Unix base' -Skip:(-not (Test-IsUnixHost)) {
        $base = '/srv/repo'
        Test-SafePath -Path '/srv/repo/sub/file' -Base $base | Should -BeTrue
    }

    It 'Test-SafePath rejects a Unix-style traversal outside the base' -Skip:(-not (Test-IsUnixHost)) {
        $base = '/srv/repo'
        Test-SafePath -Path '/srv/repo/../../etc/passwd' -Base $base | Should -BeFalse
    }
}
