#Requires -Version 5.1
#Requires -Module Pester

# ============================================================================
# gbuild - PowerShell Build System
# Copyright (c) 2026 Vu Trung Son (vutrungson94@gmail.com)
# Licensed under the MIT License. See LICENSE file for details.
# ============================================================================
# .env PARSING coverage.
#
# This file used to test Import-DotEnvFile / Remove-DotEnvFile, which wrote
# every key into the live process environment and cleared them again. Neither
# had a single production caller: build.envFile is served by
# ConfigProvider.Read-ConfigEnvironmentFile, which uses the READ-ONLY
# Read-DotEnvFile. The mutators were removed.
#
# The removal is a behaviour decision, not a cleanup. Read-DotEnvFile's own
# docblock states the reason: a build that writes into its own process
# environment leaks GBUILD_PROJECT and friends into every later step and into
# the next build in the same host. The parsing rules are unchanged and still
# worth pinning, so the coverage is kept against the function the system
# actually calls.
# ============================================================================

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "Read-DotEnvFile (.env parsing, no environment mutation)" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:dotenvTemp = New-IntegrationTempDir
        $global:dotenvFile = Join-Path $global:dotenvTemp '.env'
        Set-Content -Path $global:dotenvFile -Value @'
# comment line
FOO=bar
export BAZ=hello world
QUOTED="double quoted"
SINGLE='single quoted'
EMPTY=
NUM=42
with_inline =  value # trailing comment
'@
    }
    AfterAll {
        if ($global:dotenvTemp -and (Test-Path $global:dotenvTemp)) { Remove-Item $global:dotenvTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Loads key/value pairs from a .env file" {
        $loaded = Read-DotEnvFile -Path $global:dotenvFile
        $loaded.FOO | Should -Be 'bar'
        $loaded.NUM | Should -Be '42'
    }

    It "Handles export prefix, quoted values and inline comments" {
        $loaded = Read-DotEnvFile -Path $global:dotenvFile
        $loaded.BAZ | Should -Be 'hello world'
        $loaded.QUOTED | Should -Be 'double quoted'
        $loaded.SINGLE | Should -Be 'single quoted'
        $loaded.with_inline | Should -Be 'value'
    }

    It "Skips comments, blank lines and invalid keys" {
        $loaded = Read-DotEnvFile -Path $global:dotenvFile
        $loaded.ContainsKey('comment line') | Should -BeFalse
        $loaded.EMPTY | Should -Be ''
    }

    It "Returns an empty hashtable for a missing file" {
        $loaded = Read-DotEnvFile -Path (Join-Path $global:dotenvTemp 'missing.env')
        $loaded.Count | Should -Be 0
    }

    It "does not write the process environment" {
        # The property that distinguishes the surviving reader from the removed
        # mutator: reading a .env must leave the session untouched. A key set
        # here survives the read unchanged, and a key only present in the file
        # does not appear at all.
        [Environment]::SetEnvironmentVariable('GBUILD_DOTENV_PROBE', 'preset')
        try {
            $probeFile = Join-Path $global:dotenvTemp '.env-probe'
            Set-Content -Path $probeFile -Value "GBUILD_DOTENV_PROBE=from_file`nGBUILD_DOTENV_ABSENT=from_file"
            $null = Read-DotEnvFile -Path $probeFile
            [Environment]::GetEnvironmentVariable('GBUILD_DOTENV_PROBE') | Should -Be 'preset'
            [Environment]::GetEnvironmentVariable('GBUILD_DOTENV_ABSENT') | Should -BeNullOrEmpty
        } finally {
            [Environment]::SetEnvironmentVariable('GBUILD_DOTENV_PROBE', $null)
            [Environment]::SetEnvironmentVariable('GBUILD_DOTENV_ABSENT', $null)
        }
    }

    It "last duplicate key wins, matching the read-only contract" {
        $dupFile = Join-Path $global:dotenvTemp '.env-dup'
        Set-Content -Path $dupFile -Value "DUP=first`nDUP=second"
        $loaded = Read-DotEnvFile -Path $dupFile
        $loaded.DUP | Should -Be 'second'
    }
}
