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

    It "committed Docs/API is in sync with the module inventory" {
        # Docs/api-reference.md and Docs/API/*.md are GENERATED output, not
        # hand-written prose. They drifted 70 functions / 2 pages behind the
        # modules because nothing compared the two, so a deleted function
        # (Alerting.Invoke-BuildSecretProtect) stayed documented and a new one
        # (Alerting.Get-AlertRotationHours) was missing. This gate regenerates
        # into a temp dir and fails on ANY diff; refresh with
        # Show-GBuildHelp -Modules (gbuild.ps1 -Help -Modules).
        $buildRoot = Split-Path -Parent $global:GBuildModuleRoot
        $modulesDir = [System.IO.Path]::GetFullPath($global:GBuildModuleRoot)
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gbuild-doccheck-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $generatedIndex = Join-Path $tmp 'api-reference.md'
            $generatedPages = Join-Path $tmp 'API'
            $null = New-ModuleDocumentation -ModulesDir $modulesDir -OutputPath $generatedIndex -PerModuleDir $generatedPages
            $generatedIndex | Should -Not -BeNullOrEmpty
            $committedIndex = Join-Path $buildRoot 'Docs/api-reference.md'
            $committedPages = Join-Path $buildRoot 'Docs/API'
            (Test-Path -LiteralPath $committedIndex -PathType Leaf) | Should -BeTrue
            (Test-Path -LiteralPath $committedPages -PathType Container) | Should -BeTrue
            $normalize = {
                param([string]$Path)
                # Normalize line endings so the gate is platform-independent:
                # committed docs are LF in git (text=eol=lf) while the generator
                # may emit CRLF on Windows. Compare content, not line endings.
                ((@(Get-Content -LiteralPath $Path -Encoding UTF8) -join [Environment]::NewLine) -replace "`r", '')
            }
            $generatedText = & $normalize $generatedIndex
            $committedText = & $normalize $committedIndex
            $committedText | Should -Be $generatedText -Because 'Docs/api-reference.md is generated output; run Show-GBuildHelp -Modules to refresh it'
            $generatedPageNames = @(@(Get-ChildItem -LiteralPath $generatedPages -Filter '*.md' -File) | ForEach-Object { $_.Name } | Sort-Object)
            $committedPageNames = @(@(Get-ChildItem -LiteralPath $committedPages -Filter '*.md' -File) | ForEach-Object { $_.Name } | Sort-Object)
            ($committedPageNames -join '|') | Should -Be ($generatedPageNames -join '|') -Because 'Docs/API page set must match the module inventory'
            foreach ($name in $generatedPageNames) {
                $g = & $normalize (Join-Path $generatedPages $name)
                $c = & $normalize (Join-Path $committedPages $name)
                $c | Should -Be $g -Because "Docs/API/$name is generated output; refresh it with Show-GBuildHelp -Modules"
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
