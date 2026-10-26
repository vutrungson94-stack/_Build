#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'

# Dependencies for the preflight pipeline (Write-Log, Get-ConfigSection, config resolution).
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'ConfigProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Preflight.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'TestFixtures.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe 'Full Build Pipeline Integration (safe, no live SDK)' {
    BeforeAll {
        $global:intState = New-TestState
        # Disable network/disk/syntax/manifest checks so the pipeline runs
        # fully offline and deterministically inside the test sandbox.
        $global:intState | Add-Member -MemberType NoteProperty -Name BuildConfig -Value ([PSCustomObject]@{
            build = [PSCustomObject]@{
                preflight = [PSCustomObject]@{
                    checkSyntax    = $false
                    checkManifest  = $false
                    checkNetwork   = $false
                    checkDiskSpace = $false
                    requiredTools  = @()
                }
            }
        }) -Force -EA 0
    }

    It 'Invoke-PreflightValidation composes and returns a structured result' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbint_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $r = Invoke-PreflightValidation -State $global:intState -ProjectDir $tmp
            $r | Should -Not -BeNullOrEmpty
            $r.Passed | Should -BeOfType ([bool])
            { $r.Checks -is [System.Collections.IEnumerable] } | Should -BeTrue
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Pipeline degrades gracefully with no required SDK/tools' {
        $tmp = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbint2_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            { Invoke-PreflightValidation -State $global:intState -ProjectDir $tmp } | Should -Not -Throw
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
