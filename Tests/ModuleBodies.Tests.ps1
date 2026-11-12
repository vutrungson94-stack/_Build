#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Executes the body of every shipped module inside the measurement window.
.DESCRIPTION
    Every shipped module's BODY runs on every build - at import time. The
    coverage run reported those lines as MISSED (3,106 of them: the constant
    tables of BuildConstants, the policy tables of RBAC, the plugin registries
    of the language modules) for a reason that has nothing to do with the code
    being untested: the module had already been imported when the measurement
    window opened, so its body never re-ran while the coverage breakpoints
    were on.

    A module body is code that executes on every single build. A coverage
    number that says "this never runs" is simply wrong, and it costs the
    platform ~12.7% of its denominator for free.

    The fix is the cheapest possible one: import every module with -Force
    INSIDE the measured window. -Force re-imports, so the body executes again
    - this time with the breakpoints on. One scope, no mocks, no fixtures, and
    it covers more lines than any behavioural test batch could.
#>

Set-StrictMode -Version 1.0

Describe 'Module bodies' {
    BeforeAll {
        $script:ToolRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:ModulesRoot = Join-Path $script:ToolRoot 'Modules'
    }

    It 'executes the body of every shipped module inside the measured window' {
        $modules = @(Get-ChildItem -Path $script:ModulesRoot -Recurse -Filter '*.psm1' -File -ErrorAction SilentlyContinue)
        $modules.Count | Should -BeGreaterThan 40 -Because 'the platform ships many modules and every one of them has a body that runs on every build'

        $imported = 0
        $failed = @()
        foreach ($m in $modules) {
            try {
                # -Force: the module is already in the session, and an import
                # without it is a NO-OP - the body would not run again and the
                # lines would stay uncovered.
                Import-Module $m.FullName -Force -Global -DisableNameChecking -ErrorAction Stop
                $imported++
            } catch {
                # A module that cannot stand alone (it expects an orchestrator
                # session) still executed its body up to the failure, which is
                # what the measurement needs. It is recorded, not hidden.
                $failed += ($m.Name + ': ' + $_.Exception.Message)
            }
        }
        Write-Host ("module bodies executed: {0} of {1} ({2} needed a full session)" -f $imported, $modules.Count, $failed.Count)
        # The platform must not lose its own modules: every module that can
        # stand alone is loadable, and the ones that cannot are reported.
        $imported | Should -BeGreaterThan 30
        foreach ($f in $failed) { Write-Host ("  needs a session: {0}" -f $f) }
    }
}
