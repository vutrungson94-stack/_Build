#Requires -Version 5.1
Set-StrictMode -Version 1.0

<#
.SYNOPSIS
    Builds a full integration-test State object from the real gbuild.config.json.
.DESCRIPTION
    Loads the actual _Build/gbuild.config.json and its schema path into a State
    object mirroring what Start-GBuild produces at runtime. Used by integration
    tests that exercise config-driven behaviour across modules.
.PARAMETER BuildRoot
    Root of the _Build module tree (defaults to the parent of the Tests dir).
.PARAMETER ConfigPath
    Path to gbuild.config.json (defaults to _Build/gbuild.config.json).
#>
function New-FullTestState {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot '../../gbuild.config.json')
    )
    $cfg = $null
    if (Test-Path -LiteralPath $ConfigPath) {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction SilentlyContinue
        if ($raw) { $cfg = $raw | ConvertFrom-Json }
    }
    $state = [PSCustomObject]@{
        ScriptRoot    = (Split-Path -Parent $ConfigPath)
        ProjectRoot   = (Split-Path -Parent (Split-Path -Parent $ConfigPath))
        ConfigPath    = $ConfigPath
        BuildConfig   = $cfg
        CorrelationId = [guid]::NewGuid().ToString('N')
    }
    return $state
}

<#
.SYNOPSIS
    Creates a uniquely-named temporary directory for integration tests.
#>
function New-IntegrationTempDir {
    [CmdletBinding()]
    param()
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_it_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

<#
.SYNOPSIS
    Returns $true only when real external infrastructure (network/S3/SSH/OTLP) is
    opted in via the test runner's -RealInfra flag ($env:GBUILD_REAL_INFRA = '1').
.DESCRIPTION
    Tests that contact real services MUST gate themselves with:
        It "..." -Skip:(-not (Test-RealInfraEnabled)) { ... }
    Default (no -RealInfra) is mock-only, so CI never depends on live infrastructure.
#>
function Test-RealInfraEnabled {
    return ($env:GBUILD_REAL_INFRA -eq '1')
}

<#
.SYNOPSIS
    Writes a fake `ssh` executable into a directory for PATH-shim tests.
.DESCRIPTION
    Windows resolves ssh.cmd; POSIX resolves an executable file named `ssh`.
    The script is written in the shape the current platform can actually run.
    Create the file in a BeforeAll (or an It body) - never at file scope, since
    Pester's run phase does not see script-scope functions.
.PARAMETER Mode
    Ok = exit 0 silently; EchoOk = print "ok"; Fail = exit 1;
    Slow = sleep ~8s then exit 0 (for execution-timeout tests).
#>
function New-FakeSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [ValidateSet('Ok', 'EchoOk', 'Fail', 'Slow')][string]$Mode = 'Ok'
    )
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    if ($env:OS -eq 'Windows_NT') {
        $body = switch ($Mode) {
            'Ok'     { "@echo off`r`nexit /b 0" }
            'EchoOk' { "@echo off`r`necho ok" }
            'Fail'   { "@echo off`r`nexit /b 1" }
            'Slow'   { "@echo off`r`nping -n 8 127.0.0.1 >nul`r`nexit /b 0" }
        }
        Set-Content -Path (Join-Path $Directory 'ssh.cmd') -Value $body -Encoding ASCII
    } else {
        $body = switch ($Mode) {
            'Ok'     { "#!/bin/sh`nexit 0`n" }
            'EchoOk' { "#!/bin/sh`necho ok`n" }
            'Fail'   { "#!/bin/sh`nexit 1`n" }
            # exec: replace the shell so the timeout teardown kills the sleeper
            # itself. A forked sleep grandchild can outlive the tree kill and
            # hold the redirected pipes until the bounded drain times out.
            'Slow'   { "#!/bin/sh`nexec sleep 8`n" }
        }
        $sshPath = Join-Path $Directory 'ssh'
        [System.IO.File]::WriteAllText($sshPath, $body)
        & chmod +x $sshPath
    }
}

<#
.SYNOPSIS
    Writes a fake dotnet executable into a directory.
.DESCRIPTION
    Windows gets dotnet.cmd; POSIX gets an executable `dotnet` sh script,
    because a .cmd file cannot be launched there.
#>
function New-FakeDotnet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$Output = '',
        [int]$ExitCode = 0
    )
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    if ($env:OS -eq 'Windows_NT') {
        $path = Join-Path $Directory 'dotnet.cmd'
        $body = "@echo off`r`n"
        if ($Output) { $body += "echo $Output`r`n" }
        $body += "exit /b $ExitCode"
        Set-Content -Path $path -Value $body -Encoding ASCII
    } else {
        $path = Join-Path $Directory 'dotnet'
        $body = "#!/bin/sh`n"
        if ($Output) { $body += "echo $Output`n" }
        $body += "exit $ExitCode`n"
        [System.IO.File]::WriteAllText($path, $body)
        & chmod +x $path
    }
    return $path
}

Export-ModuleMember -Function @('New-FullTestState', 'New-IntegrationTempDir', 'Test-RealInfraEnabled', 'New-FakeSsh', 'New-FakeDotnet')
