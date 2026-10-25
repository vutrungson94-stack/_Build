# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================

# Tier1Modules.ps1 - SINGLE SOURCE for the Tier-1 bootstrap module list.
#
# The same 20 core module names used to be hardcoded in TWO places:
#   - Modules/Orchestrator.psm1 (the eager import prologue), and
#   - gbuild.ps1 (the -SelfTest Tier-1 import probe),
# and the hygiene test only regex-matched the FIRST occurrence, so the second
# copy could drift invisibly (it already had: the SelfTest copy additionally
# carried Logging + Orchestrator). Both files now dot-source this file instead.
#
# Pure data: no imports, no side effects, PS 5.1-parseable. Safe to dot-source
# from a .ps1 launcher scope AND from inside a .psm1 module scope, before any
# other module is loaded. Consumers add their own extras on top of Core:
#   - Orchestrator prologue: Logging (separate, cycle-safe) + Core + Providers
#   - gbuild.ps1 -SelfTest:   Logging + Core + Orchestrator + Providers

function Get-Tier1ModuleList {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

Set-StrictMode -Version 1.0
    return @{
        Core = @(
            'PathUtils', 'ErrorHandling', 'Environment', 'SDK', 'Project',
            'Menu', 'Loader', 'LanguageDetector', 'EventBus', 'Metrics',
            'Alerting', 'Container', 'CredentialVault', 'BuildContext',
            'IContract', 'ConfigProvider', 'SharedUtils', 'Locale', 'RBAC',
            'Report'
        )
        Providers = @(
            'BuildStrategyProvider', 'EnvironmentProvider', 'AndroidSdkProvider'
        )
    }
}
