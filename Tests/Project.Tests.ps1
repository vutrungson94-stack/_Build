#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "Project Integration (csproj type detection)" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Project.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Locale.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
        $global:state = [PSCustomObject]@{ CurrentTfm = 'net8.0'; CorrelationId = 'proj-it' }
        $global:temp = New-IntegrationTempDir

        $web = Join-Path $global:temp 'Web.csproj'
        Set-Content -LiteralPath $web -Value @'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
</Project>
'@

        $maui = Join-Path $global:temp 'Maui.csproj'
        Set-Content -LiteralPath $maui -Value @'
<Project Sdk="Microsoft.NET.Sdk.Razor">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <UseMaui>true</UseMaui>
  </PropertyGroup>
</Project>
'@

        $console = Join-Path $global:temp 'Console.csproj'
        Set-Content -LiteralPath $console -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <OutputType>Exe</OutputType>
  </PropertyGroup>
</Project>
'@

        $avalonia = Join-Path $global:temp 'Avalonia.csproj'
        Set-Content -LiteralPath $avalonia -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <OutputType>Exe</OutputType>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Avalonia" Version="11.0.0" />
  </ItemGroup>
</Project>
'@

        $multi = Join-Path $global:temp 'Multi.csproj'
        Set-Content -LiteralPath $multi -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFrameworks>net8.0;net8.0-android;net8.0-ios</TargetFrameworks>
    <OutputType>Exe</OutputType>
  </PropertyGroup>
</Project>
'@
    }
    AfterAll {
        if ($global:temp -and (Test-Path $global:temp)) { Remove-Item $global:temp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Detects a Web SDK project as type Web" {
        $m = Get-ProjectMetadata -CsprojPath (Join-Path $global:temp 'Web.csproj') -State $global:state
        $m.ProjectType | Should -Be 'Web'
    }

    It "Detects a MAUI project via UseMaui" {
        $m = Get-ProjectMetadata -CsprojPath (Join-Path $global:temp 'Maui.csproj') -State $global:state
        $m.ProjectType | Should -Be 'MAUI'
    }

    It "Detects a Console Exe project" {
        $m = Get-ProjectMetadata -CsprojPath (Join-Path $global:temp 'Console.csproj') -State $global:state
        $m.ProjectType | Should -Be 'Console'
    }

    It "Detects an Avalonia project via PackageReference" {
        $m = Get-ProjectMetadata -CsprojPath (Join-Path $global:temp 'Avalonia.csproj') -State $global:state
        $m.ProjectType | Should -Be 'Avalonia'
    }

    It "Parses multiple TargetFrameworks from TargetFrameworks node" {
        $m = Get-ProjectMetadata -CsprojPath (Join-Path $global:temp 'Multi.csproj') -State $global:state
        $m.Tfms.Count | Should -Be 3
        $m.Tfms -contains 'net8.0-android' | Should -BeTrue
    }

    It "Returns Unknown for a missing csproj without throwing" {
        { Get-ProjectMetadata -CsprojPath (Join-Path $global:temp 'Nope.csproj') -State $global:state } | Should -Not -Throw
        (Get-ProjectMetadata -CsprojPath (Join-Path $global:temp 'Nope.csproj') -State $global:state).ProjectType | Should -Be 'Unknown'
    }

    It "keeps a single auto-detection root as a full path" {
        $root = Join-Path $global:temp 'single-root'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $csprojPath = Join-Path $root 'Single.csproj'
        Set-Content -LiteralPath $csprojPath -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>'
        $state = [PSCustomObject]@{ ScriptRoot = $root; ProjectRoot = $root; WorkingDir = $root }
        $found = Find-Project -State $state
        $found.FullName | Should -Be $csprojPath
    }
}
