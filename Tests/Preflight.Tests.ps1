Set-StrictMode -Version 1.0

$modulePath = Join-Path $PSScriptRoot '../Modules/Preflight.psm1'
Import-Module $modulePath -Force -DisableNameChecking

Describe 'Preflight' {
    It 'Test-ProjectManifest returns Passed for valid JSON' {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tmp -Value '{"name":"test","version":"1.0"}' -Encoding UTF8
            $result = Test-ProjectManifest -Path $tmp -State $null
            $result.Passed | Should -Be $true
        } finally { Remove-Item $tmp -Force -EA SilentlyContinue }
    }

    It 'Test-ProjectManifest returns Passed for valid XML' {
        $tmp = [System.IO.Path]::GetTempFileName() + '.xml'
        try {
            Set-Content -Path $tmp -Value '<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>' -Encoding UTF8
            $result = Test-ProjectManifest -Path $tmp -State $null
            $result.Passed | Should -Be $true
        } finally { Remove-Item $tmp -Force -EA SilentlyContinue }
    }

    It 'Test-ProjectManifest returns Failed for missing file' {
        $missing = if ($IsWindows) { 'C:\nonexistent\file.csproj' } else { '/nonexistent/file.csproj' }
        $result = Test-ProjectManifest -Path $missing -State $null
        $result.Passed | Should -Be $false
        $result.Errors.Count | Should -BeGreaterThan 0
    }

    It 'Test-ProjectManifest returns Failed for invalid XML' {
        $tmp = [System.IO.Path]::GetTempFileName() + '.xml'
        try {
            Set-Content -Path $tmp -Value '<invalid xml' -Encoding UTF8
            $result = Test-ProjectManifest -Path $tmp -State $null
            $result.Passed | Should -Be $false
        } finally { Remove-Item $tmp -Force -EA SilentlyContinue }
    }

    It 'Invoke-PreflightValidation returns result with expected keys' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $state = [PSCustomObject]@{
                BuildConfig = [PSCustomObject]@{
                    build = [PSCustomObject]@{ preflight = [PSCustomObject]@{ checkSyntax = $false; checkNetwork = $false; checkDiskSpace = $false; checkManifest = $false } }
                    health = [PSCustomObject]@{ endpoints = @() }
                }
            }
            $result = Invoke-PreflightValidation -State $state -ProjectDir $tmpDir
            $result.ContainsKey('Passed') | Should -Be $true
            $result.ContainsKey('Checks') | Should -Be $true
        } finally { Remove-Item $tmpDir -Recurse -Force -EA SilentlyContinue }
    }

    It 'honors preflight checkTools and requiredTools' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild_preflight_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $state = [PSCustomObject]@{
                ProjectRoot = $tmpDir
                WorkingDir = $tmpDir
                OS = 'Windows'
                BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ preflight = [PSCustomObject]@{
                    enabled = $true
                    checkSyntax = $false
                    checkManifest = $false
                    checkDiskSpace = $false
                    checkNetwork = $false
                    checkTools = $false
                    requiredTools = @('gbuild_missing_contract_tool')
                } } }
            }
            $disabled = Invoke-PreflightValidation -State $state -ProjectDir $tmpDir
            $disabled.Checks.Name | Should -Not -Contain 'Tools'
            $state.BuildConfig.build.preflight.checkTools = $true
            $enabled = Invoke-PreflightValidation -State $state -ProjectDir $tmpDir
            $enabled.Checks.Name | Should -Contain 'Tools'
            $enabled.Passed | Should -BeFalse
            $enabled.Errors -join ' ' | Should -Match 'gbuild_missing_contract_tool'
        } finally { Remove-Item $tmpDir -Recurse -Force -EA SilentlyContinue }
    }

    It 'validates the module dependency graph, and can be turned off' {
        # This is the production wiring for Modules/ModuleDependencies.psm1. Until
        # it existed, the platform's own validator for missing dependencies and
        # import cycles ran ONLY under `gbuild -SelfTest`, i.e. never during a
        # build - so a broken module graph surfaced deep inside a plugin with no
        # hint that the graph was at fault.
        $modulesRoot = Join-Path $PSScriptRoot '../Modules'
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('pf_graph_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $preflight = @{
                enabled = $true
                checkSyntax = $false
                checkManifest = $false
                checkDiskSpace = $false
                checkNetwork = $false
                checkTools = $false
                requiredTools = @()
                endpoints = @()
            }
            $state = [PSCustomObject]@{
                WorkingDir = $tmpDir
                ModulesRoot = (Resolve-Path $modulesRoot).Path
                OS = 'Windows'
                BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ preflight = [PSCustomObject]@{ enabled = $true; checkModuleGraph = $true } } }
            }
            # The real graph must validate cleanly - this asserts the shipped
            # module set has no missing dependency and no cycle.
            $on = Invoke-PreflightValidation -State $state -ProjectDir $tmpDir
            $on.Checks.Name | Should -Contain 'ModuleGraph' -Because 'the validator must be reachable from a normal build, not only from -SelfTest'
            ($on.Checks | Where-Object { $_.Name -eq 'ModuleGraph' }).Passed | Should -BeTrue

            $state.BuildConfig.build.preflight.checkModuleGraph = $false
            $off = Invoke-PreflightValidation -State $state -ProjectDir $tmpDir
            $off.Checks.Name | Should -Not -Contain 'ModuleGraph' -Because 'a check that cannot be disabled is not a configurable check'
        } finally { Remove-Item $tmpDir -Recurse -Force -EA SilentlyContinue }
    }
}
