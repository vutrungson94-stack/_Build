#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Files = '',
    [switch]$Use51Host,
    [switch]$Strict,
    [switch]$RequireNoSkips
)

Set-StrictMode -Version 1.0
$strictSkips = $Strict.IsPresent -or $RequireNoSkips.IsPresent

$script:Default51Files = @(
    'ModuleHygiene.Tests.ps1'
    'PS51Compat.Tests.ps1'
    'PathUtils.Tests.ps1'
    'Cache.Tests.ps1'
    'SharedUtils.Tests.ps1'
    'ErrorHandling.Tests.ps1'
    'Project.Tests.ps1'
    'Parallel.Tests.ps1'
    'BootstrapResilience.Tests.ps1'
)

if (-not $Use51Host) {
    if ($PSVersionTable.PSVersion.Major -eq 5) {
        $Use51Host = $true
    } else {
        # Skip the 5.1 re-exec on non-Windows platforms: SystemRoot is unset
        # and there is no powershell.exe to forward to.
        $sysRoot = $env:SystemRoot
        if (-not [string]::IsNullOrWhiteSpace($sysRoot)) {
            $ps51 = Join-Path $sysRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (Test-Path -LiteralPath $ps51 -PathType Leaf) {
                $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Use51Host')
                if (-not [string]::IsNullOrWhiteSpace($Files)) { $forward += @('-Files', $Files) }
                if ($Strict.IsPresent) { $forward += '-Strict' }
                if ($RequireNoSkips.IsPresent) { $forward += '-RequireNoSkips' }
                & $ps51 @forward
                exit $LASTEXITCODE
            }
        }
        # Linux/macOS: no powershell.exe available; run tests in current host
    }
}

$testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path -Resolve
$names = @()
if (-not [string]::IsNullOrWhiteSpace($Files)) {
    $names = @($Files -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    $names = @($script:Default51Files)
}
if ($names.Count -eq 0) {
    Write-Error '[PS51Smoke] no test files requested.'
    exit 1
}

$paths = New-Object System.Collections.Generic.List[string]
$missing = New-Object System.Collections.Generic.List[string]
foreach ($name in $names) {
    $path = if ([System.IO.Path]::IsPathRooted($name)) { $name } else { Join-Path $testRoot $name }
    if (Test-Path -LiteralPath $path -PathType Leaf) { $paths.Add([string]$path) }
    else { $missing.Add($name) }
}
if ($missing.Count -gt 0) {
    Write-Error ("[PS51Smoke] missing test file(s): {0}" -f ($missing -join ', '))
    exit 1
}
if ($paths.Count -eq 0) {
    Write-Error '[PS51Smoke] no test files resolved.'
    exit 1
}

Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop
$config = New-PesterConfiguration
$config.Run.Path = $paths.ToArray()
$config.Run.Exit = $false
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Normal'
try {
    $result = Invoke-Pester -Configuration $config
} catch {
    Write-Error ("[PS51Smoke] Pester invocation failed: {0}" -f $_.Exception.Message)
    exit 1
}
if ($null -eq $result) {
    Write-Error '[PS51Smoke] Pester returned no result.'
    exit 1
}

function Get-PesterCount {
    param([string]$Name)
    try {
        $property = $result.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) { return 0 }
        return [int]$property.Value
    } catch {
        return 0
    }
}

$passed = Get-PesterCount 'PassedCount'
$failed = Get-PesterCount 'FailedCount'
$skipped = Get-PesterCount 'SkippedCount'
$total = Get-PesterCount 'TotalCount'
if ($total -le 0) {
    try {
        if ($null -ne $result.Tests) { $total = @($result.Tests).Count }
    } catch { }
}
if ($total -lt ($passed + $failed + $skipped)) { $total = $passed + $failed + $skipped }
Write-Host ('[PS51Smoke] passed={0} failed={1} skipped={2} total={3} (powershell {4})' -f $passed, $failed, $skipped, $total, $PSVersionTable.PSVersion)
if ($total -le 0 -or $failed -gt 0 -or ($strictSkips -and $skipped -gt 0)) {
    exit 1
}
exit 0
