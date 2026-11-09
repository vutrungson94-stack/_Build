#Re#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'

BeforeAll {
    $null = Import-Module (Join-Path $global:GBuildModuleRoot 'PathUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
}
AfterAll {
    Remove-Module PathUtils -Force -ErrorAction SilentlyContinue
}

Describe 'PathUtils - core path helpers' {
    It 'ConvertTo-ForwardSlash replaces backslashes with forward slashes' {
        ConvertTo-ForwardSlash -Path 'a\b\c\d.txt' | Should -Be 'a/b/c/d.txt'
    }

    It 'ConvertTo-ForwardSlash is a no-op for already-forward paths' {
        ConvertTo-ForwardSlash -Path 'a/b/c' | Should -Be 'a/b/c'
    }

    It 'Format-Path collapses mixed separators to the OS separator' {
        $r = Format-Path -Path 'a/b\c/d'
        $r | Should -Not -Match '\\\\'   # no doubled separators
        ($r -replace '\\', '/') | Should -Be 'a/b/c/d'
    }

    It 'Format-Path anchors a relative path under Base' {
        $base = Join-Path $( [System.IO.Path]::GetTempPath() ) 'gbutil_base'
        $r = Format-Path -Path 'sub\child' -Base $base
        $r | Should -Be (Join-Path $base 'sub\child')
    }

    It 'Get-SafeJoinPath joins with the OS separator and normalizes' {
        $base = Join-Path $( [System.IO.Path]::GetTempPath() ) 'repo'; $r = Get-SafeJoinPath -Base $base -Child 'src/mod'
        $r | Should -Be (Join-Path $base 'src/mod')
    }
}

Describe 'PathUtils - security (path traversal guard)' {
    BeforeAll {
        $global:ptBase = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbutil_safe_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $global:ptBase -Force | Out-Null
    }
    AfterAll {
        if ($global:ptBase -and (Test-Path $global:ptBase)) { Remove-Item $global:ptBase -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Test-SafePath accepts a nested child path' {
        Test-SafePath -Path 'sub/child.txt' -Base $global:ptBase | Should -BeTrue
    }

    It 'Test-SafePath accepts the base directory itself' {
        Test-SafePath -Path $global:ptBase -Base $global:ptBase | Should -BeTrue
    }

    It 'Test-SafePath rejects parent traversal (../)' {
        Test-SafePath -Path '../../../etc/passwd' -Base $global:ptBase | Should -BeFalse
    }

    It 'Test-SafePath rejects a rooted escape outside the base' {
        Test-SafePath -Path (Join-Path ( [System.IO.Path]::GetTempPath() ) 'escape-outside.txt') -Base $global:ptBase | Should -BeFalse
    }

    It 'Test-SafePath rejects mixed-separator traversal' {
        Test-SafePath -Path 'sub\..\..\secret' -Base $global:ptBase | Should -BeFalse
    }

    It 'Test-NoReparsePointInPath accepts a not-yet-created child under the temp root' {
        # Regression (macOS CI 2026-11-09): every temp path goes through
        # /var -> /private/var, an OS alias that Resolve-Path does NOT resolve
        # (proven on a Windows junction and on the macOS runner). The walk must
        # STOP at the alias instead of rejecting the path; without it
        # Steps/CacheProvider/Deploy/Distributed fail on macOS with
        # "Archive path escaped output directory".
        $out = Join-Path $global:ptBase 'out'
        New-Item -ItemType Directory -Path $out -Force | Out-Null
        Test-NoReparsePointInPath -Path (Join-Path $out 'build-output.zip') | Should -BeTrue
    }

    It 'Test-NoReparsePointInPath stops at the OS aliases (/var, /tmp), not above them' -Skip:([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
        # On macOS /var and /tmp are symlinks to /private/var and /private/tmp.
        # The walk must treat them as the boundary, exactly as it treats a
        # project root: a symlink ABOVE the boundary is infrastructure, a
        # symlink BELOW it is a traversal.
        Test-NoReparsePointInPath -Path '/var/folders/xx/T/gbutil/out/build-output.zip' | Should -BeTrue
        Test-NoReparsePointInPath -Path '/tmp/gbutil/out/build-output.zip' | Should -BeTrue
    }
}

Describe 'PathUtils - Resolve-NativePath (entrypoint contract)' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'PathUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $script:ptIsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    }

    It 'returns null for empty input' {
        Resolve-NativePath -Path '' | Should -BeNullOrEmpty
        Resolve-NativePath -Path '   ' | Should -BeNullOrEmpty
    }

    It 'resolves an already-native absolute path to itself' {
        $probe = if ($script:ptIsWin) { "$env:SystemDrive\Users" } else { '/tmp' }
        $got = Resolve-NativePath -Path $probe
        $got | Should -Not -BeNullOrEmpty
        $got | Should -Be ([System.IO.Path]::GetFullPath($probe))
    }

    It 'maps Git-Bash drive form to a native path on Windows, passes through on Unix' {
        $got = Resolve-NativePath -Path '/c/Users/test'
        if ($script:ptIsWin) {
            $got | Should -Be 'C:\Users\test'
        } else {
            $got | Should -Not -BeNullOrEmpty
        }
    }
}

# --- Project-root resolution -------------------------------------------------
# gbuild.ps1 used to set ProjectRoot to the launch directory verbatim, so a run
# from a directory with no build file wrote .gbuild-state.gbuildstate,
# .gbuildcache\ and build-reports\ into THAT directory -- including a volume root
# (F:\.gbuildcache was observed). Resolve-BuildProjectRoot now owns the decision.
Describe 'PathUtils - project root resolution' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'PathUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $script:ptRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('gbutil_proj_' + [guid]::NewGuid().ToString('N'))
        $script:ptNested = Join-Path $script:ptRoot 'src\app\lib'
        New-Item -ItemType Directory -Path $script:ptNested -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:ptRoot 'package.json') -Value '{"name":"probe"}' -Encoding UTF8
    }
    AfterAll {
        if ($script:ptRoot -and (Test-Path $script:ptRoot)) { Remove-Item $script:ptRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Test-BuildProjectMarker detects a build file at the directory top level' {
        Test-BuildProjectMarker -Path $script:ptRoot | Should -BeTrue
    }

    It 'Test-BuildProjectMarker rejects a directory with no build file' {
        Test-BuildProjectMarker -Path $script:ptNested | Should -BeFalse
    }

    It 'Test-BuildProjectMarker rejects a missing or empty path without throwing' {
        Test-BuildProjectMarker -Path '' | Should -BeFalse
        Test-BuildProjectMarker -Path (Join-Path $script:ptRoot 'does-not-exist') | Should -BeFalse
    }

    It 'Resolve-BuildProjectRoot walks UP from a subdirectory to the owning project' {
        $r = Resolve-BuildProjectRoot -StartDir $script:ptNested
        $r.HasMarker | Should -BeTrue
        $r.Root | Should -Be ([System.IO.Path]::GetFullPath($script:ptRoot))
        $r.Explicit | Should -BeFalse
        $r.Depth | Should -BeGreaterThan 0
    }

    It 'Resolve-BuildProjectRoot honours -ExplicitProject over discovery' {
        $r = Resolve-BuildProjectRoot -StartDir $script:ptNested -ExplicitProject $script:ptRoot
        $r.Explicit | Should -BeTrue
        $r.Root | Should -Be ([System.IO.Path]::GetFullPath($script:ptRoot))
    }

    It 'Resolve-BuildProjectRoot reports HasMarker=$false and keeps the start dir when the walk is bounded out' {
        $orphan = Join-Path ([System.IO.Path]::GetTempPath()) ('gbutil_orphan_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $orphan -Force | Out-Null
        try {
            # -MaxDepth 1 checks the directory itself and its parent only, so the
            # walk cannot escape into a real project higher up the tree.
            $r = Resolve-BuildProjectRoot -StartDir $orphan -MaxDepth 1
            $r.HasMarker | Should -BeFalse
            $r.Root | Should -Be ([System.IO.Path]::GetFullPath($orphan))
            $r.Explicit | Should -BeFalse
        } finally { Remove-Item $orphan -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Test-BuildVolumeRoot identifies a filesystem volume root' {
        $vol = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($script:ptRoot))
        Test-BuildVolumeRoot -Path $vol | Should -BeTrue
        Test-BuildVolumeRoot -Path $script:ptRoot | Should -BeFalse
        Test-BuildVolumeRoot -Path '' | Should -BeFalse
    }

    It 'Resolve-BuildProjectRoot flags a volume root so the launcher can refuse it' {
        $vol = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($script:ptRoot))
        $r = Resolve-BuildProjectRoot -StartDir $vol -MaxDepth 1
        $r.Root | Should -Be $vol
        # A volume root that carries no build file is exactly the case the
        # launcher must refuse (this is how F:\ got .gbuildcache).
        if (-not $r.HasMarker) { $r.IsVolumeRoot | Should -BeTrue }
    }

    It 'Test-BuildProjectMarker finds a build file when one is added later' {
        $late = Join-Path $script:ptRoot 'late_marker_dir'
        New-Item -ItemType Directory -Path $late -Force | Out-Null
        try {
            Test-BuildProjectMarker -Path $late | Should -BeFalse
            Set-Content -LiteralPath (Join-Path $late 'CMakeLists.txt') -Value 'project(x)' -Encoding UTF8
            Test-BuildProjectMarker -Path $late | Should -BeTrue
        } finally { Remove-Item $late -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
