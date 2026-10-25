#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "Affected Detection" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Cache.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:affectedTemp = New-IntegrationTempDir
        $global:affectedState = [PSCustomObject]@{ ScriptRoot = $global:affectedTemp; CorrelationId = 'affected-it' }
        Initialize-BuildCache -State $global:affectedState -CacheDir 'cache' | Out-Null

        $global:projA = Join-Path $global:affectedTemp 'projA'
        $global:projB = Join-Path $global:affectedTemp 'projB'
        New-Item -ItemType Directory -Path $global:projA -Force | Out-Null
        New-Item -ItemType Directory -Path $global:projB -Force | Out-Null
        $global:projAPath = Join-Path $global:projA 'A.csproj'
        $global:projBPath = Join-Path $global:projB 'B.csproj'
        '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>' | Set-Content -Path $global:projAPath -Force
        '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>' | Set-Content -Path $global:projBPath -Force
    }
    AfterAll {
        if ($global:affectedTemp -and (Test-Path $global:affectedTemp)) { Remove-Item $global:affectedTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Returns a result object with Affected/Unchanged/Mode properties" {
        $res = Get-AffectedProjects -ProjectFiles @($global:projAPath, $global:projBPath) -SkipGitDiff -State $global:affectedState
        $res | Should -Not -BeNullOrEmpty
        $res.Affected -is [string[]] | Should -BeTrue
        $res.Unchanged -is [string[]] | Should -BeTrue
        $res.Mode | Should -Be 'Hash'
    }

    It "Marks projects with no cached fingerprint as affected" {
        $res = Get-AffectedProjects -ProjectFiles @($global:projAPath, $global:projBPath) -SkipGitDiff -State $global:affectedState
        $res.Affected.Count | Should -Be 2
        $res.Unchanged.Count | Should -Be 0
    }

    It "Marks a project unchanged once its fingerprint matches a successful build" {
        Invoke-BuildWithCache -ProjectPath $global:projAPath -CacheKey 'test-build-A' -BuildAction { return 'ok' } -State $global:affectedState | Out-Null
        $res = Get-AffectedProjects -ProjectFiles @($global:projAPath, $global:projBPath) -SkipGitDiff -State $global:affectedState
        $res.Unchanged | Should -Contain $global:projAPath
        $res.Affected | Should -Contain $global:projBPath
    }

    It "Marks a project affected again after its content changes" {
        '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework><Nullable>enable</Nullable></PropertyGroup></Project>' | Set-Content -Path $global:projAPath -Force
        $res = Get-AffectedProjects -ProjectFiles @($global:projAPath, $global:projBPath) -SkipGitDiff -State $global:affectedState
        $res.Affected | Should -Contain $global:projAPath
    }

    It "Git mode: only the project touched by working-tree changes is affected" -Skip:((-not (Get-Command git -ErrorAction SilentlyContinue))) {
        $gitRoot = New-IntegrationTempDir
        try {
            $gitProjA = Join-Path $gitRoot 'ProjA'
            $gitProjB = Join-Path $gitRoot 'ProjB'
            New-Item -ItemType Directory -Path $gitProjA -Force | Out-Null
            New-Item -ItemType Directory -Path $gitProjB -Force | Out-Null
            $aCsproj = Join-Path $gitProjA 'A.csproj'
            $bCsproj = Join-Path $gitProjB 'B.csproj'
            '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>' | Set-Content -Path $aCsproj -Force
            '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>' | Set-Content -Path $bCsproj -Force

            Push-Location $gitRoot
            try {
                & git init -q 2>$null
                & git config user.name 'test'
                & git config user.email 'test@example.com'
                # Save fingerprints first (simulate a prior successful build of both projects)
                Invoke-BuildWithCache -ProjectPath $aCsproj -CacheKey 'git-build-A' -BuildAction { return 'ok' } -State $global:affectedState | Out-Null
                Invoke-BuildWithCache -ProjectPath $bCsproj -CacheKey 'git-build-B' -BuildAction { return 'ok' } -State $global:affectedState | Out-Null
                & git add -A 2>$null
                & git commit -m 'initial' -q 2>$null
                # Touch only A
                '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework><Nullable>enable</Nullable></PropertyGroup></Project>' | Set-Content -Path $aCsproj -Force
            } finally {
                Pop-Location
            }

            $res = Get-AffectedProjects -ProjectFiles @($aCsproj, $bCsproj) -State $global:affectedState
            $res.Mode | Should -Be 'Git+Hash'
            $res.Affected | Should -Contain $aCsproj
            $res.Unchanged | Should -Contain $bCsproj
            $res.ChangedFiles.Count | Should -BeGreaterThan 0
        } finally {
            if ($gitRoot -and (Test-Path $gitRoot)) { Remove-Item $gitRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
