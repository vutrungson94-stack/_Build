#Requires -Version 5.1
#Requires -Module Pester
Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$global:GBuildTestRoot   = Split-Path -Parent $PSCommandPath
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "Documentation" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildTestRoot (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Documentation.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $td = New-IntegrationTempDir
        $modsDir = Join-Path $td 'mods'
        New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
        $tmpPs1 = Join-Path $modsDir 'TestMod.psm1'
        Set-Content -Path $tmpPs1 -Value 'function Test-Foo { <# .SYNOPSIS x #> param([string]$A) Write-Output $A }'
    }
    AfterAll {
        if (Test-Path $td) { Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Get-ModuleFunctions parses the function and its parameters" {
        $funcs = Get-ModuleFunctions -ModulePath $tmpPs1 -ModuleName 'TestMod'
        @($funcs).Count | Should -BeGreaterThan 0
        ($funcs | Where-Object { $_.Name -eq 'Test-Foo' }) | Should -Not -BeNullOrEmpty
        $foo = (@($funcs) | Where-Object { $_.Name -eq 'Test-Foo' })[0]
        $paramStr = $foo.Parameters -join ''
        $paramStr | Should -Match 'A'
        $paramStr | Should -Match 'String'
    }

    It "New-ModuleDocumentation generates API.md without literal token" {
        $out = Join-Path $td 'API.md'
        $path = New-ModuleDocumentation -ModulesDir $modsDir -OutputPath $out
        $path | Should -Not -BeNullOrEmpty
        Test-Path $path | Should -Be $true
        $content = Get-Content -Path $path -Raw
        $content | Should -Match '## TestMod'
        $content | Should -Match '### Test-Foo'
        $content | Should -Not -Match '\$\(\$func\.Name\)'
    }

    It "Show-GBuildHelp does not throw" {
        { Show-GBuildHelp } | Should -Not -Throw
    }

    It "Show-GBuildHelp contains locale and optional-feature guidance" {
        $helpText = Show-GBuildHelp 6>&1 | Out-String
        $helpText | Should -Match 'LANGUAGE TIP:'
        $helpText | Should -Match '-Locale list'
        $helpText | Should -Match 'OPTIONAL FEATURES'
        $helpText | Should -Match 'skipping them is not an error'
    }
}
