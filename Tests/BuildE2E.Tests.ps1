#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    BuildE2E - end-to-end build pipeline verification (real dotnet).
.DESCRIPTION
    Proves the gbuild build pipeline actually runs through Start-BuildAndShow
    with a real .NET SDK. On machines without a valid SDK (e.g. the sandbox
    with a fake dotnet stub) every test is SKIPPED, not failed, so the suite
    stays green in environments where a real build is impossible.
    No hardcoded paths - all directories derive from $PSScriptRoot / $TestDrive.
#>

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

function Test-RealDotnet {
    $dotnet = Get-Command 'dotnet' -ErrorAction SilentlyContinue
    if (-not $dotnet) { return $false }
    try {
        $out = & dotnet --version 2>$null
        return ($LASTEXITCODE -eq 0 -and ($out -match '^\d+\.\d+'))
    } catch { return $false }
}



$skip = (-not (Test-RealDotnet))

Describe "Build E2E - real dotnet pipeline" -Skip:$skip {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Environment.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Build.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildContext.psm1') -Force -DisableNameChecking -ErrorAction Stop

        $root = Join-Path $TestDrive 'e2e'
        $projectDir = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $projectDir -Force
        $proj = Join-Path $projectDir 'E2EApp.csproj'
        $content = '<Project Sdk="Microsoft.NET.Sdk">' + [Environment]::NewLine +
            '  <PropertyGroup>' + [Environment]::NewLine +
            '    <OutputType>Exe</OutputType>' + [Environment]::NewLine +
            '    <TargetFramework>net8.0</TargetFramework>' + [Environment]::NewLine +
            '    <Nullable>enable</Nullable>' + [Environment]::NewLine +
            '    <ImplicitUsings>enable</ImplicitUsings>' + [Environment]::NewLine +
            '  </PropertyGroup>' + [Environment]::NewLine +
            '</Project>'
        Set-Content -Path $proj -Value $content -Encoding UTF8 -Force
        $prog = Join-Path $projectDir 'Program.cs'
        Set-Content -Path $prog -Value 'Console.WriteLine("E2E-OK");' -Encoding UTF8 -Force
        $global:proj = $proj
        $global:projectDir = $projectDir

        $state = New-BuildContext
        $state.ProjectRoot = $root
        $state.ScriptRoot  = $PSScriptRoot
        $state.DotnetCmd   = 'dotnet'
        $state.OS          = Get-OSPlatform
        $global:state = $state
    }

    It "Start-BuildAndShow builds a real project and produces output" {
        $ok = Start-BuildAndShow -State $global:state -Project $global:proj -Tfm 'net8.0' -OutputSubDir 'web' -ProjectType 'Web' -Incremental
        $ok | Should -BeTrue
        $outDir = Join-Path (Join-Path $global:state.ProjectRoot 'publish-output') 'web'
        Test-Path -Path $outDir | Should -BeTrue
    }

    It "Build failure path returns false for missing project" {
        $ok = Start-BuildAndShow -State $global:state -Project (Join-Path $global:projectDir 'Nope.csproj') -Tfm 'net8.0'
        $ok | Should -BeFalse
    }

    AfterAll {
        if (Get-Module Build) { Remove-Module Build -Force }
        if (Get-Module BuildContext) { Remove-Module BuildContext -Force }
        if (Get-Module Environment) { Remove-Module Environment -Force }
        if (Get-Module Logging) { Remove-Module Logging -Force }
    }
}
