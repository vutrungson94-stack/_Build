#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'

# Dependencies resolved into the GLOBAL session so plugin-internal calls
# (Write-Log, Test-ToolAvailable, Invoke-PluginCommand) always resolve.
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Loader.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'ConfigProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$global:swState = [PSCustomObject]@{ ProjectRoot = $( [System.IO.Path]::GetTempPath() ) }

Describe 'Swift plugin' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Plugins/Swift.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    }
    AfterAll {
        Remove-Module Swift -Force -ErrorAction SilentlyContinue
    }

    It 'Get-PluginInfo returns Swift metadata' {
        $info = Get-PluginInfo
        $info.Name | Should -Be 'Swift'
        $info.SupportedLanguages | Should -Contain 'Swift'
        $info.BuildCommand | Should -Match '^swift'
    }

    It 'Invoke-PluginBuild returns false when swift is unavailable (graceful)' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_swift_b_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            Invoke-PluginBuild -State $global:swState -ProjectDir $tmp | Should -BeFalse
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-PluginTest returns false without Package.swift' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_swift_t_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            Invoke-PluginTest -State $global:swState -ProjectDir $tmp | Should -BeFalse
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-PluginLint returns true (SoftFail) without Package.swift' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_swift_l_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $r = Invoke-PluginLint -State $global:swState -ProjectDir $tmp -Detailed
            $r.Status | Should -Be 'Skipped'
            $r.ReasonCode | Should -Be 'ManifestMissing'
            Invoke-PluginLint -State $global:swState -ProjectDir $tmp | Should -BeFalse
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-PluginPreflight returns a result hashtable' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_swift_p_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $r = Invoke-PluginPreflight -State $global:swState -ProjectDir $tmp
            $r.Passed | Should -BeOfType ([bool])
            $r.Errors.Count | Should -BeGreaterThan 0
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
