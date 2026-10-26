#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'

BeforeAll {
    $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    $null = Import-Module (Join-Path $global:GBuildModuleRoot 'PathUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
}
AfterAll {
    Remove-Module PathUtils -Force -ErrorAction SilentlyContinue
}

Describe 'Edge Cases - path traversal & permission/error safety' {

    BeforeAll {
        $global:ecBase = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbedge_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $global:ecBase -Force | Out-Null
    }
    AfterAll {
        if ($global:ecBase -and (Test-Path $global:ecBase)) { Remove-Item $global:ecBase -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Test-SafePath rejects a rooted absolute escape outside the base (permission boundary)' {
        Test-SafePath -Path (Join-Path ( [System.IO.Path]::GetTempPath() ) 'gbedge-escape.txt') -Base $global:ecBase | Should -BeFalse
    }

    It 'Test-SafePath resolves a relative path against the base and contains it (no bypass switch)' {
        # The -AllowRelative switch was removed: it returned $true unconditionally,
        # silently disabling the guard for any caller that passed it. Relative
        # paths are resolved against Base first, then contained - there is no
        # bypass. A relative path that stays inside passes; one with '..' that
        # escapes does not.
        Test-SafePath -Path 'sub/deep/file.txt' -Base $global:ecBase | Should -BeTrue
        Test-SafePath -Path '../escape.txt' -Base $global:ecBase | Should -BeFalse
    }

    It 'Test-SafePath correctly contains a path when the base has a trailing separator' {
        $baseTrail = $global:ecBase.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        Test-SafePath -Path 'child.txt' -Base $baseTrail | Should -BeTrue
    }

    It 'Write-ErrorSafe swallows a thrown error (e.g. permission denied) without throwing and returns $null' {
        { Write-ErrorSafe -ScriptBlock { throw 'permission denied' } -Message 'op failed' } | Should -Not -Throw
        Write-ErrorSafe -ScriptBlock { throw 'permission denied' } -Message 'op failed' | Should -BeNullOrEmpty
    }

    It 'Write-ErrorSafe returns the script block result on success (no silent swallow)' {
        Write-ErrorSafe -ScriptBlock { 42 } -Message 'op ok' | Should -Be 42
    }
}
