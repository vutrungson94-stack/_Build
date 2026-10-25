#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$here = Split-Path -Parent $PSCommandPath
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $here) 'Modules'

Describe "MockHelpers - real-infra gate" {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Helpers/MockHelpers.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "Test-RealInfraEnabled is false by default (mock-only)" {
        $old = $env:GBUILD_REAL_INFRA
        try {
            Remove-Item Env:\GBUILD_REAL_INFRA -ErrorAction SilentlyContinue
            Test-RealInfraEnabled | Should -BeFalse
        } finally {
            if ($null -ne $old) { $env:GBUILD_REAL_INFRA = $old } else { Remove-Item Env:\GBUILD_REAL_INFRA -ErrorAction SilentlyContinue }
        }
    }

    It "Test-RealInfraEnabled is true only with -RealInfra (env=1)" {
        $old = $env:GBUILD_REAL_INFRA
        try {
            $env:GBUILD_REAL_INFRA = '1'
            Test-RealInfraEnabled | Should -BeTrue
        } finally {
            if ($null -ne $old) { $env:GBUILD_REAL_INFRA = $old } else { Remove-Item Env:\GBUILD_REAL_INFRA -ErrorAction SilentlyContinue }
        }
    }

    It "New-IntegrationTempDir creates a unique temp directory" {
        $dir = New-IntegrationTempDir
        try {
            Test-Path $dir | Should -BeTrue
            (Get-Item $dir).PSIsContainer | Should -BeTrue
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
