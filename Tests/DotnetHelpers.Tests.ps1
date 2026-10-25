#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'

# Logging (Write-Log), SharedUtils (Test-ToolAvailable) and Loader (Invoke-PluginCommand)
# are used by the dotnet helper functions.
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Loader.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

# Minimal non-null state object (functions only use it for logging).
$global:dhState = [PSCustomObject]@{ ProjectRoot = $env:TEMP }

Describe 'DotnetHelpers (shared dotnet/avalonia helpers)' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Plugins/helpers/DotnetHelpers.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    }
    AfterAll {
        Remove-Module DotnetHelpers -Force -ErrorAction SilentlyContinue
    }

    It 'Get-DotnetPreflightResult returns a result hashtable' {
        $tmp = Join-Path $env:TEMP ('gbuild_dh_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $r = Get-DotnetPreflightResult -State $global:dhState -ProjectDir $tmp
            $r.Passed | Should -BeOfType ([bool])
            $r.Warnings.Count | Should -BeGreaterThan 0
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Resolve-DotnetProjectFile prefers an explicit project file over directory scan' {
        $tmp = Join-Path $env:TEMP ('gbuild_dh4_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-Item -ItemType File -Path (Join-Path $tmp 'App.csproj') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $tmp 'Other.fsproj') -Force | Out-Null
            $explicit = Join-Path $tmp 'Other.fsproj'
            $r = Resolve-DotnetProjectFile -ProjectFile $explicit -ProjectDir $tmp
            $r.Name | Should -Be 'Other.fsproj'
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Resolve-DotnetProjectFile scans all supported project types when no explicit file is given' {
        $tmp = Join-Path $env:TEMP ('gbuild_dh5_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-Item -ItemType File -Path (Join-Path $tmp 'App.vbproj') -Force | Out-Null
            $r = Resolve-DotnetProjectFile -ProjectDir $tmp
            $r.Name | Should -Be 'App.vbproj'
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Resolve-DotnetProjectFile returns null when no project file exists' {
        $tmp = Join-Path $env:TEMP ('gbuild_dh6_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $r = Resolve-DotnetProjectFile -ProjectDir $tmp
            $null | Should -Be $r
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Invoke-NpmBuildIfPresent is a no-op without package.json (does not throw)' {
        $tmp = Join-Path $env:TEMP ('gbuild_dh2_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            { Invoke-NpmBuildIfPresent -State $global:dhState -ProjectDir $tmp } | Should -Not -Throw
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Invoke-DotnetTest returns true (skip) when no test projects exist' {
        $tmp = Join-Path $env:TEMP ('gbuild_dh3_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $r = Invoke-DotnetTest -State $global:dhState -ProjectDir $tmp -Detailed
            $r.Status | Should -Be 'Skipped'
            $r.ReasonCode | Should -Be 'NoTests'
            Invoke-DotnetTest -State $global:dhState -ProjectDir $tmp | Should -BeFalse
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Resolve-DotnetCommand coerces a polluted array DotnetCmd to the real path' {
        # Regression: upstream output pollution turned State.DotnetCmd into an
        # array, and binding it to Test-ToolAvailable -ToolName crashed
        # Preflight with "Cannot process argument transformation on parameter
        # 'ToolName'. Cannot convert value to type System.String."
        #
        # Resolve-DotnetCommand now prefers an SDK-capable muxer over
        # State.DotnetCmd, so the outcome depends on whether SDK.psm1 happens to
        # be loaded - which differs between a bare Pester run and the canonical
        # isolated scope runner. Both outcomes are correct; what must never happen
        # is the stringified array, so that is asserted directly.
        $mod = Get-Module DotnetHelpers
        $r = & $mod { param($s) Resolve-DotnetCommand -State $s } ([PSCustomObject]@{ DotnetCmd = @($true, 'C:\fake\dotnet.exe') })
        $r | Should -BeOfType [string]
        $r | Should -Not -BeNullOrEmpty
        $r | Should -Not -Match 'True'          # never the stringified array
        if ($r -ne 'C:\fake\dotnet.exe') {
            # The SDK-capable branch won; it must genuinely be SDK-capable.
            $out = & $r '--list-sdks' 2>&1
            $LASTEXITCODE | Should -Be 0
            @($out).Count | Should -BeGreaterThan 0
        }
    }

    It 'Resolve-DotnetCommand falls back to dotnet for missing or non-string DotnetCmd' {
        # Same load-order caveat as above: with no usable State.DotnetCmd the
        # result is the bare tool name, or an SDK-capable muxer when one can be
        # resolved. What must not happen is the stringified junk leaking through.
        $mod = Get-Module DotnetHelpers
        $r1 = & $mod { param($s) Resolve-DotnetCommand -State $s } ([PSCustomObject]@{ })
        $r1 | Should -BeOfType [string]
        $r1 | Should -Not -BeNullOrEmpty
        $r2 = & $mod { param($s) Resolve-DotnetCommand -State $s } ([PSCustomObject]@{ DotnetCmd = @($true, $null) })
        $r2 | Should -BeOfType [string]
        $r2 | Should -Not -BeNullOrEmpty
        $r2 | Should -Not -Match 'True'
        if ($r2 -ne 'dotnet') {
            $out = & $r2 '--list-sdks' 2>&1
            $LASTEXITCODE | Should -Be 0
            @($out).Count | Should -BeGreaterThan 0
        }
    }

    It 'Get-DotnetPreflightResult does not throw on a polluted array DotnetCmd' {
        $tmp = Join-Path $env:TEMP ('gbuild_dh7_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $polluted = [PSCustomObject]@{ ProjectRoot = $env:TEMP; DotnetCmd = @($true, 'zzz_no_such_tool_xyz') }
            { Get-DotnetPreflightResult -State $polluted -ProjectDir $tmp } | Should -Not -Throw
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
