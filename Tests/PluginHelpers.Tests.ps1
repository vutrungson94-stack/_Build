#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'

# SharedUtils provides Test-ToolAvailable; Logging provides Write-Log - both used by the helpers.
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

# Minimal non-null state object (functions only use it for logging).
$global:phState = [PSCustomObject]@{ ProjectRoot = $( [System.IO.Path]::GetTempPath() ) }

Describe 'PluginHelpers (shared single-tool plugin skeleton)' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Plugins/helpers/PluginHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    }
    AfterAll {
        Remove-Module PluginHelpers -Force -ErrorAction SilentlyContinue
    }

    It 'Resolve-PluginManifest returns explicit ProjectFile when present' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_ph_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $mf = Join-Path $tmp 'mix.exs'; New-Item -ItemType File -Path $mf -Force | Out-Null
        try {
            Resolve-PluginManifest -ProjectFile $mf -ProjectDir $tmp -ManifestFiles @('mix.exs') | Should -Be $mf
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Resolve-PluginManifest falls back to manifest found in ProjectDir' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_ph2_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $mf = Join-Path $tmp 'go.mod'; New-Item -ItemType File -Path $mf -Force | Out-Null
        try {
            Resolve-PluginManifest -ProjectDir $tmp -ManifestFiles @('go.mod', 'mix.exs') | Should -Be $mf
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Resolve-PluginManifest returns null when nothing found' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_ph3_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            Resolve-PluginManifest -ProjectDir $tmp -ManifestFiles @('nope.x') | Should -BeNullOrEmpty
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Resolve-PluginManifest resolves manifest given a Unix-style (forward-slash) ProjectDir' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_ph4_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $mf = Join-Path $tmp 'go.mod'; New-Item -ItemType File -Path $mf -Force | Out-Null
        $unixDir = $tmp -replace '\\', '/'
        try {
            Resolve-PluginManifest -ProjectDir $unixDir -ManifestFiles @('go.mod') | Should -Be $mf
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Get-SimplePluginPreflight reports missing tool as warning (universal success, not error)' {
        $r = Get-SimplePluginPreflight -ToolName 'zzz_no_such_tool_xyz' -ManifestFiles @('mix.exs') -ManifestLabel 'mix.exs' -State $global:phState -ProjectDir $( [System.IO.Path]::GetTempPath() )
        $r.Passed | Should -BeTrue
        ($r.Warnings -join ',') | Should -Match 'Missing tool'
        $r.Errors.Count | Should -Be 0
    }

    It 'Resolve-PluginBuild returns null when tool missing' {
        Resolve-PluginBuild -ToolName 'zzz_no_such_tool_xyz' -ToolNotFoundMsg 'x' -ManifestFiles @('mix.exs') -State $global:phState -ProjectDir $( [System.IO.Path]::GetTempPath() ) | Should -BeNullOrEmpty
    }

    It 'Invoke-SimplePluginTest returns false when tool missing' {
        Invoke-SimplePluginTest -ToolName 'zzz_no_such_tool_xyz' -ToolNotFoundMsg 'x' -ManifestFiles @('mix.exs') -TestCommand 'mix test' -State $global:phState -ProjectDir $( [System.IO.Path]::GetTempPath() ) | Should -BeFalse
    }

    It 'Invoke-SimplePluginLint returns true with SoftFail when tool missing' {
        Invoke-SimplePluginLint -ToolName 'zzz_no_such_tool_xyz' -ToolNotFoundMsg 'x' -ManifestFiles @('mix.exs') -LintCommand 'mix format' -State $global:phState -ProjectDir $( [System.IO.Path]::GetTempPath() ) -SoftFail | Should -BeTrue
    }

    It 'rejects an explicit ProjectFile outside the manifest contract' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_ph_reject_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $valid = Join-Path $tmp 'package.json'; $invalid = Join-Path $tmp 'notes.txt'
        New-Item -ItemType File -Path $valid -Force | Out-Null
        New-Item -ItemType File -Path $invalid -Force | Out-Null
        try {
            Resolve-PluginManifest -ProjectFile $invalid -ProjectDir $tmp -ManifestFiles @('package.json') | Should -BeNullOrEmpty
            Resolve-PluginManifest -ProjectFile $valid -ProjectDir $tmp -ManifestFiles @('package.json') | Should -Be $valid
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'uses child exit status instead of stdout as command success' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_ph_command_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $r = Invoke-PluginCommandResult -ScriptBlock { $global:LASTEXITCODE = 9; 'stdout is not success' } -State $global:phState -ProjectDir $tmp
            $r.Status | Should -Be 'Failed'
            $r.ExitCode | Should -Be 9
            (ConvertTo-PluginActionResult -Value 'stdout' -Operation 'plugin.test').Status | Should -Be 'Failed'
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'treats PowerShell errors as failures without promoting native stderr alone' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_ph_error_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $powerShellError = Invoke-PluginCommandResult -ScriptBlock { Write-Error 'bad' } -State $global:phState -ProjectDir $tmp
            $powerShellError.Status | Should -Be 'Failed'
            $powerShellError.Succeeded | Should -BeFalse
            $nativeStderr = Invoke-PluginCommandResult -ScriptBlock { & cmd.exe /d /c 'echo native-stderr 1>&2 & exit /b 0' } -State $global:phState -ProjectDir $tmp
            $nativeStderr.Status | Should -Be 'Succeeded'
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'cache key includes canonical path, configuration, plugin, toolchain, and input hash' {
        $a = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_key_a_' + [guid]::NewGuid().ToString('N'))
        $b = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_key_b_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $a,$b -Force | Out-Null
        $plugin = @{ Info = @{ Name = 'Node'; Version = '1.0.0'; ToolName = 'npm' }; Path = (Join-Path $global:GBuildModuleRoot 'Plugins/Node.psm1') }
        $k1 = Get-PluginCacheKey -Plugin $plugin -ProjectDir $a -ProjectFile (Join-Path $a 'package.json') -Configuration Release -InputHash one
        $k2 = Get-PluginCacheKey -Plugin $plugin -ProjectDir $b -ProjectFile (Join-Path $b 'package.json') -Configuration Release -InputHash one
        $k3 = Get-PluginCacheKey -Plugin $plugin -ProjectDir $a -ProjectFile (Join-Path $a 'package.json') -Configuration Debug -InputHash one
        $k4 = Get-PluginCacheKey -Plugin $plugin -ProjectDir $a -ProjectFile (Join-Path $a 'package.json') -Configuration Release -InputHash two
        $k1 | Should -Not -Be $k2
        $k1 | Should -Not -Be $k3
        $k1 | Should -Not -Be $k4
        $k1 | Should -Match 'plugin-build-v2'
        $k1 | Should -Match ([regex]::Escape('Release'))
        try { Remove-Item $a,$b -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}
