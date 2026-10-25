# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================
# Modules/StepBootstrap.ps1 - ONE bootstrap for every Steps\*.ps1 and Hooks\*.ps1
#
# WHY THIS FILE EXISTS
# A Step or a Hook has to work in two very different situations:
#
#   1. Inside a gbuild run, invoked by Orchestrator. Every shared module is
#      already loaded and this file does nothing.
#   2. Standalone - someone dot-sources "./Steps/pipeline-diagram.ps1" from a
#      shell, exactly as the help text documents. Nothing is loaded, and the
#      script is useless without Logging, SharedUtils, ConfigProvider, Locale
#      and PathUtils.
#
# That second case was solved by pasting a 10-line block into each of the six
# shipped Steps/Hooks. The copies had already diverged: three different module
# lists (two of them five modules, one of them eight), and two different probe
# sets for "is the session already bootstrapped". So the set a Step imports
# depended on which file it lived in, and nothing tested that they agreed.
#
# USAGE (dot-source, from a Step or Hook):
#     . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/StepBootstrap.ps1') -Sentinels @('Write-Log') -Modules @('Environment')
#
# -Sentinels  commands whose absence means "not bootstrapped yet". Any one
#             missing triggers the import. Defaults to the union of the three
#             sets the copies used, so behaviour is a superset of all of them.
# -Modules    extra modules this particular Step needs on top of the base set.
#
# The base set is deliberately small and stable: the five modules every consumer
# needs. Anything a Step needs beyond that is a per-Step decision and belongs in
# its -Modules list, where it is visible.
# ============================================================================

param(
    # Probe set: if ANY of these is missing, the session is not bootstrapped.
    [string[]]$Sentinels = @('Write-Log', 'Resolve-BuildState', 'Resolve-ConfigValue', 'Get-BuildConstant'),
    # Modules to import once the session is known to need them.
    [string[]]$Modules = @()
)
Set-StrictMode -Version 1.0


# Base set: Logging (Write-Log), SharedUtils, ConfigProvider (Resolve-ConfigValue,
# Resolve-BuildState, Get-ConfigValue), Locale (Get-LocaleMessage), PathUtils.
$__gbuildStepBootstrapBase = @('Logging', 'SharedUtils', 'ConfigProvider', 'Locale', 'PathUtils')
$__gbuildStepBootstrapAll = @($__gbuildStepBootstrapBase + $Modules |
                             Select-Object -Unique | Where-Object { $_ })

# Cheap no-op when the session is already bootstrapped. A Step runs on every
# build, so this check happens first and does no filesystem work in the common
# case.
$__gbuildStepBootstrapNeed = $false
foreach ($__gbuildStepBootstrapSentinel in $Sentinels) {
    if (-not (Get-Command $__gbuildStepBootstrapSentinel -ErrorAction SilentlyContinue)) {
        $__gbuildStepBootstrapNeed = $true
        break
    }
}

if ($__gbuildStepBootstrapNeed) {
    # Walk up from this script to the _Build root, marked by the Modules/
    # directory. The bounded loop is what makes it safe when the caller is a
    # bare copy with no _Build root anywhere above it.
    $__gbuildStepBootstrapRoot = $PSScriptRoot
    $__gbuildStepBootstrapDepth = 0
    while ($__gbuildStepBootstrapRoot -and $__gbuildStepBootstrapDepth -lt 6 -and
           -not (Test-Path -LiteralPath (Join-Path $__gbuildStepBootstrapRoot 'Modules') -PathType Container)) {
        $__gbuildStepBootstrapRoot = Split-Path $__gbuildStepBootstrapRoot -Parent
        $__gbuildStepBootstrapDepth++
    }
    if ($__gbuildStepBootstrapRoot) {
        foreach ($__gbuildStepBootstrapModule in $__gbuildStepBootstrapAll) {
            $__gbuildStepBootstrapPath = Join-Path (Join-Path $__gbuildStepBootstrapRoot 'Modules') "$__gbuildStepBootstrapModule.psm1"
            if (Test-Path -LiteralPath $__gbuildStepBootstrapPath -PathType Leaf) {
                # -Global: a Step dot-sources this file, so the modules must land
                # in the global session state to be visible to the rest of the
                # script and to anything the Step calls afterwards. A
                # variable-target import without -Global would leave the Step
                # half-bootstrapped, which is the exact failure this file
                # exists to prevent.
                Import-Module $__gbuildStepBootstrapPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
            }
        }
    }
}

# Never leave the working variables behind: a Step dot-sources this file into
# its own scope, and an __-prefixed name that leaked would be a second, silent
# copy of the bootstrap state.
Remove-Variable -Name __gbuildStepBootstrapBase, __gbuildStepBootstrapAll, __gbuildStepBootstrapNeed, `
    __gbuildStepBootstrapSentinel, __gbuildStepBootstrapRoot, __gbuildStepBootstrapDepth, `
    __gbuildStepBootstrapModule, __gbuildStepBootstrapPath -ErrorAction SilentlyContinue
