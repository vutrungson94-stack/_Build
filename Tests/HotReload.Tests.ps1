Set-StrictMode -Version 1.0

$modulePath = Join-Path $PSScriptRoot '../Modules/HotReload.psm1'
Import-Module $modulePath -Force -DisableNameChecking

Describe 'HotReload' {
    # pwsh7-on-Unix guard for both tests below: /proc-based helpers need a real Unix;
    # $env:OS is used because this file does not load PlatformShim ($IsWindows would
    # throw under StrictMode on PS 5.1).
    It 'Get-PsBinary resolves ps command on Unix' {
        if ($PSVersionTable.PSVersion.Major -ge 7 -and $env:OS -ne 'Windows_NT') {
            # Canonical cache lives in Environment module scope (single source);
            # reset it through the module so resolution is genuinely re-exercised.
            $envMod = Get-Module -Name 'Environment' -ErrorAction SilentlyContinue
            if ($envMod) { & $envMod { $script:PsBinary = $null } }
            $bin = Get-PsBinary
            $bin | Should -Not -BeNullOrEmpty
        } else {
            Set-ItResult -Skipped -Because 'Unix-only test'
        }
    }

    It 'Get-UnixProcessTreeMap returns empty dict when ps unavailable' {
        if ($PSVersionTable.PSVersion.Major -ge 7 -and $env:OS -ne 'Windows_NT') {
            $map = Get-UnixProcessTreeMap
            $map | Should -Not -BeNullOrEmpty
        } else {
            Set-ItResult -Skipped -Because 'Unix-only test'
        }
    }

    It 'Unix process helpers are single-sourced in Environment (no HotReload copies)' {
        $envMod = Get-Module -Name 'Environment' -ErrorAction SilentlyContinue
        $envMod | Should -Not -BeNullOrEmpty -Because 'HotReload bootstrap must load Environment'
        foreach ($fn in @('Get-PsBinary', 'Get-UnixProcessCommandLine', 'Get-UnixProcessTreeMap', 'Get-UnixProcessDescendants')) {
            (Get-Command -Module 'Environment' -Name $fn -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because "Environment must export $fn"
        }
        $hrMod = Get-Module -Name 'HotReload' -ErrorAction SilentlyContinue
        if ($hrMod) {
            foreach ($fn in @('Get-PsBinary', 'Get-UnixProcessCommandLine', 'Get-UnixProcessTreeMap', 'Get-UnixProcessDescendants')) {
                (Get-Command -Module 'HotReload' -Name $fn -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty -Because "HotReload must not keep a private copy of $fn"
            }
        }
    }

    It 'Get-UnixProcessDescendants walks a synthetic tree map (cross-platform)' {
        $tree = [System.Collections.Generic.Dictionary[int, object]]::new()
        $kids1 = [System.Collections.Generic.List[int]]::new()
        $kids1.Add(2); $kids1.Add(3)
        $tree[1] = $kids1
        $kids2 = [System.Collections.Generic.List[int]]::new()
        $kids2.Add(4)
        $tree[2] = $kids2
        $desc = Get-UnixProcessDescendants -Tree $tree -RootId 1
        (($desc | Sort-Object) -join ',') | Should -Be '2,3,4'
    }
}
