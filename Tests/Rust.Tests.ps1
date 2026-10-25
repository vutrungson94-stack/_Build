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
$global:rsState = [PSCustomObject]@{ ProjectRoot = [System.IO.Path]::GetTempPath() }

Describe 'Rust plugin' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Plugins/Rust.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    }
    AfterAll {
        Remove-Module Rust -Force -ErrorAction SilentlyContinue
    }

    It 'Get-PluginInfo returns Rust metadata' {
        $info = Get-PluginInfo
        $info.Name | Should -Be 'Rust'
        $info.SupportedLanguages | Should -Contain 'Rust'
        $info.BuildCommand | Should -Be 'cargo build'
        $info.TestCommand | Should -Be 'cargo test'
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
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_rust_b_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            Invoke-PluginBuild -State $global:rsState -ProjectDir $tmp | Should -BeFalse
            (Invoke-PluginBuild -State $global:rsState -ProjectDir $tmp -Detailed).Status | Should -Be 'Failed'
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-PluginTest returns false without a manifest (graceful)' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_rust_t_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            Invoke-PluginTest -State $global:rsState -ProjectDir $tmp | Should -BeFalse
            (Invoke-PluginTest -State $global:rsState -ProjectDir $tmp -Detailed).Status | Should -Be 'Skipped'
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-PluginLint degrades gracefully without a manifest' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_rust_l_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            # SoftFail: a missing lint toolchain reports success-shaped output,
            # so only the result SHAPE is asserted here, not the boolean.
            Invoke-PluginLint -State $global:rsState -ProjectDir $tmp | Should -BeOfType ([bool])
            (Invoke-PluginLint -State $global:rsState -ProjectDir $tmp -Detailed).Status | Should -Be 'Skipped'
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-PluginPreflight returns a result hashtable' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_rust_p_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $r = Invoke-PluginPreflight -State $global:rsState -ProjectDir $tmp
            $r.Passed | Should -BeOfType ([bool])
            # The manifest is always absent in an empty dir, so every
            # machine reports at least the manifest error here.
            $r.Errors.Count | Should -BeGreaterThan 0
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-PluginClean and Invoke-PluginRun do not throw without a manifest' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_rust_c_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            { Invoke-PluginClean -State $global:rsState -ProjectDir $tmp } | Should -Not -Throw
            { Invoke-PluginRun -State $global:rsState -ProjectDir $tmp } | Should -Not -Throw
            Invoke-PluginClean -State $global:rsState -ProjectDir $tmp | Should -BeFalse
            Invoke-PluginRun -State $global:rsState -ProjectDir $tmp | Should -BeFalse
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
