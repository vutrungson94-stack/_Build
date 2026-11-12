#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Locale.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'HotReload.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'HotReload helper coverage' {
    It 'delegates to plugin run for non-dotnet projects when available' {
        $state = [PSCustomObject]@{}
        InModuleScope HotReload -Parameters @{ state = $state } {
            Mock Invoke-PluginRunFor { param($State,$Language,$ProjectDir) return $true }
            { Invoke-HotReload -State $state -ProjPath (Join-Path ([System.IO.Path]::GetTempPath()) 'demo.txt') -ProjectDir ([System.IO.Path]::GetTempPath()) -ProjectType 'Python' } | Should -Not -Throw
        }
    }

    It 'falls back for non-dotnet projects when plugin run is unavailable and cleans up watch job' {
        $proj = Join-Path ([System.IO.Path]::GetTempPath()) ('hr-' + [guid]::NewGuid().ToString('N') + '.csproj')
        Set-Content -LiteralPath $proj -Value '<Project></Project>' -Encoding UTF8
        try {
            # Exercise Windows cleanup branch even on non-Windows runners by
            # stubbing Get-CimInstance when absent (regression: Linux pwsh has no
            # Get-CimInstance, so mocks must not assume the cmdlet exists).
            $state = [PSCustomObject]@{ DotnetCmd = 'dotnet'; OS = 'Windows' }
            InModuleScope HotReload -Parameters @{ state = $state; proj = $proj } {
                function Invoke-PluginRunFor { param($State,$Language,$ProjectDir) return $false }
                function Resolve-PublishOutputDir { param($State) 'publish' }
                function Get-BuildRootDirectory { param($State) [System.IO.Path]::GetTempPath() }
                function Invoke-SafeRemove { param($Path,$AllowedRoots,[switch]$Recurse,[switch]$Force) }
                function Invoke-SmartClean { param($State,$ProjectDir,$CsprojPath,$ProjectType) }
                function Stop-ProcessByPort { param($State,$ProjectDir,$ProjectType,$ExeName) }
                function Get-SafePath { param($Path) $Path }
                function Resolve-LogMessage { param($Key,$Fallback,$MessageArgs) if ($Fallback) { $Fallback } else { $Key } }
                function Get-BuildConstant { param($Key,$Fallback) $Fallback }
                function Write-Log { param($Message,$Level,$State) }
                if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
                    function script:Get-CimInstance { param([Parameter(ValueFromRemainingArguments=$true)]$Remaining) @() }
                }
                Mock Invoke-PluginRunFor { $false }
                Mock Resolve-PublishOutputDir { 'publish' }
                Mock Get-BuildRootDirectory { [System.IO.Path]::GetTempPath() }
                Mock Invoke-SafeRemove { }
                Mock Invoke-SmartClean { }
                Mock Stop-ProcessByPort { }
                Mock Get-SafePath { param($Path) $Path }
                Mock Resolve-LogMessage { param($Key,$Fallback) if ($Fallback) { $Fallback } else { $Key } }
                Mock Get-BuildConstant { param($Key,$Fallback) $Fallback }
                Mock Write-Log { }
                Mock Receive-Job { @() }
                Mock Stop-Job { }
                Mock Remove-Job { }
                Mock Start-Sleep { }
                Mock Get-CimInstance { @() }
                { Invoke-HotReload -State $state -ProjPath $proj -ProjectDir ([System.IO.Path]::GetDirectoryName($proj)) -ProjectType 'Python' } | Should -Not -Throw
            }
        } finally { Remove-Item -LiteralPath $proj -Force -ErrorAction SilentlyContinue }
    }

    It 'cleans up watch job on Unix cleanup path (regression: no Get-CimInstance dependency)' {
        $proj = Join-Path ([System.IO.Path]::GetTempPath()) ('hr-' + [guid]::NewGuid().ToString('N') + '.csproj')
        Set-Content -LiteralPath $proj -Value '<Project></Project>' -Encoding UTF8
        try {
            $state = [PSCustomObject]@{ DotnetCmd = 'dotnet'; OS = 'Linux' }
            InModuleScope HotReload -Parameters @{ state = $state; proj = $proj } {
                function Invoke-PluginRunFor { param($State,$Language,$ProjectDir) return $false }
                function Resolve-PublishOutputDir { param($State) 'publish' }
                function Get-BuildRootDirectory { param($State) [System.IO.Path]::GetTempPath() }
                function Invoke-SafeRemove { param($Path,$AllowedRoots,[switch]$Recurse,[switch]$Force) }
                function Invoke-SmartClean { param($State,$ProjectDir,$CsprojPath,$ProjectType) }
                function Stop-ProcessByPort { param($State,$ProjectDir,$ProjectType,$ExeName) }
                function Get-SafePath { param($Path) $Path }
                function Resolve-LogMessage { param($Key,$Fallback,$MessageArgs) if ($Fallback) { $Fallback } else { $Key } }
                function Get-BuildConstant { param($Key,$Fallback) $Fallback }
                function Write-Log { param($Message,$Level,$State) }
                function Get-UnixProcessTreeMap { @{} }
                function Get-UnixProcessCommandLine { param($ProcessId) '' }
                function Get-UnixProcessDescendants { param($Tree,$RootId) @() }
                Mock Invoke-PluginRunFor { $false }
                Mock Resolve-PublishOutputDir { 'publish' }
                Mock Get-BuildRootDirectory { [System.IO.Path]::GetTempPath() }
                Mock Invoke-SafeRemove { }
                Mock Invoke-SmartClean { }
                Mock Stop-ProcessByPort { }
                Mock Get-SafePath { param($Path) $Path }
                Mock Resolve-LogMessage { param($Key,$Fallback) if ($Fallback) { $Fallback } else { $Key } }
                Mock Get-BuildConstant { param($Key,$Fallback) $Fallback }
                Mock Write-Log { }
                Mock Receive-Job { @() }
                Mock Stop-Job { }
                Mock Remove-Job { }
                Mock Start-Sleep { }
                Mock Get-UnixProcessTreeMap { @{} }
                Mock Get-Process { @() } -ParameterFilter { $Name -eq 'dotnet' }
                { Invoke-HotReload -State $state -ProjPath $proj -ProjectDir ([System.IO.Path]::GetDirectoryName($proj)) -ProjectType 'Python' } | Should -Not -Throw
            }
        } finally { Remove-Item -LiteralPath $proj -Force -ErrorAction SilentlyContinue }
    }
}
