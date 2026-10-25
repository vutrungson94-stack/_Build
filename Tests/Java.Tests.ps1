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
$global:javaState = [PSCustomObject]@{ ProjectRoot = [System.IO.Path]::GetTempPath() }

Describe 'Java plugin' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Plugins/Java.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    }
    AfterAll {
        Remove-Module Java -Force -ErrorAction SilentlyContinue
    }

    It 'Get-PluginInfo returns Java metadata' {
        $info = Get-PluginInfo
        $info.Name | Should -Be 'Java'
        $info.SupportedLanguages | Should -Contain 'Java'
        $info.BuildCommand | Should -Be 'build'
        $info.TestCommand | Should -Be 'test'
    }

    It 'exports the plugin contract surface' {
        # The contract lives in BasePlugin.Get-BasePluginContractFunctions;
        # every plugin must resolve the five core verbs plus the optional
        # Clean/Run lifecycle verbs so Loader dispatch stays wired.
        foreach ($fn in @('Get-PluginInfo', 'Invoke-PluginBuild', 'Invoke-PluginTest', 'Invoke-PluginLint', 'Invoke-PluginPreflight', 'Invoke-PluginClean', 'Invoke-PluginRun')) {
            Get-Command $fn -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "$fn must resolve after import"
        }
    }

    It 'Invoke-PluginBuild returns false without a manifest (graceful)' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_java_b_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            Invoke-PluginBuild -State $global:javaState -ProjectDir $tmp | Should -BeFalse
            (Invoke-PluginBuild -State $global:javaState -ProjectDir $tmp -Detailed).Status | Should -Be 'Failed'
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-PluginTest returns false without a manifest (graceful)' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_java_t_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            Invoke-PluginTest -State $global:javaState -ProjectDir $tmp | Should -BeFalse
            (Invoke-PluginTest -State $global:javaState -ProjectDir $tmp -Detailed).Status | Should -Be 'Skipped'
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-PluginLint degrades gracefully without a manifest' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_java_l_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            Invoke-PluginLint -State $global:javaState -ProjectDir $tmp | Should -BeFalse
            (Invoke-PluginLint -State $global:javaState -ProjectDir $tmp -Detailed).Status | Should -Be 'Skipped'
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-PluginPreflight returns a result hashtable' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_java_p_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $r = Invoke-PluginPreflight -State $global:javaState -ProjectDir $tmp
            $r.Passed | Should -BeOfType ([bool])
            # The manifest is always absent in an empty dir, so every
            # machine reports at least the manifest error here.
            $r.Errors.Count | Should -BeGreaterThan 0
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-PluginClean and Invoke-PluginRun do not throw without a manifest' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_java_c_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            { Invoke-PluginClean -State $global:javaState -ProjectDir $tmp } | Should -Not -Throw
            { Invoke-PluginRun -State $global:javaState -ProjectDir $tmp } | Should -Not -Throw
            Invoke-PluginClean -State $global:javaState -ProjectDir $tmp | Should -BeFalse
            Invoke-PluginRun -State $global:javaState -ProjectDir $tmp | Should -BeFalse
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
