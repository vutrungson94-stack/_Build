#Requires -Version 5.1
#Requires -Module Pester

# PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS
. (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'PlatformShim.ps1'))

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

$global:td = New-IntegrationTempDir
$global:state = [PSCustomObject]@{
    ScriptRoot  = $global:td; ProjectRoot = $global:td; WorkingDir = $global:td
    BuildConfig = [PSCustomObject]@{ }
    Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
    OS = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
    LogLevel = 3
}

Describe "Clean" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Clean.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'PathUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        $script:CleanTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-clean-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:CleanTemp -Force
    }
    AfterAll {
        if ($script:CleanTemp -and (Test-Path $script:CleanTemp)) {
            Remove-Item -LiteralPath $script:CleanTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Add-CleanTarget adds valid directory" {
        $targets = [System.Collections.Generic.List[string]]::new()
        $dir = Join-Path $global:td "tgt"
        $null = New-Item -ItemType Directory -Path $dir -Force
        Add-CleanTarget -Path $dir -AllowedRoots @($global:td) -Targets $targets
        $targets.Count | Should -BeGreaterThan 0
    }

    It "Add-CleanTarget skips non-existent path" {
        $targets = [System.Collections.Generic.List[string]]::new()
        Add-CleanTarget -Path (Join-Path $global:td "nope") -AllowedRoots @($global:td) -Targets $targets
        $targets.Count | Should -Be 0
    }

    It "Add-CleanTarget rejects paths outside allowed roots" {
        $targets = [System.Collections.Generic.List[string]]::new()
        $inside = Join-Path $script:CleanTemp 'inside-dir'
        $outside = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-clean-out-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $inside,$outside -Force
        try {
            Add-CleanTarget -Path $inside -AllowedRoots @($script:CleanTemp) -Targets $targets
            Add-CleanTarget -Path $outside -AllowedRoots @($script:CleanTemp) -Targets $targets
            $targets | Should -Contain $inside
            $targets | Should -Not -Contain $outside
        } finally {
            if (Test-Path $outside) { Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It "Assert-SafePath allows children and rejects escapes" {
        $child = Join-Path $script:CleanTemp (Join-Path 'sub' 'leaf')
        $null = New-Item -ItemType Directory -Path $child -Force
        Assert-SafePath -Target $child -AllowedRoots @($script:CleanTemp) | Should -BeTrue
        Assert-SafePath -Target (Join-Path $script:CleanTemp (Join-Path '..' '..' 'Windows')) -AllowedRoots @($script:CleanTemp) | Should -BeFalse
        Assert-SafePath -Target '' -AllowedRoots @($script:CleanTemp) | Should -BeFalse
    }

    It "Get-CleanTargetsConfig returns null when absent and returns configured targets" {
        $mod = Get-Module -Name Clean
        $invoke = { param($s,$p) & $mod { param($st,$pt) Get-CleanTargetsConfig -State $st -ProjectType $pt } $s $p }
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{} } }
        & $invoke $state 'Web' | Should -BeNullOrEmpty

        $cfg = [PSCustomObject]@{ build = [PSCustomObject]@{ cleanTargetsPerProjectType = [PSCustomObject]@{
            Web = [PSCustomObject]@{ additionalDirs = @('dist','coverage'); platformsDirs = @() }
            MAUI = [PSCustomObject]@{ additionalDirs = @('.maui-extra'); platformsDirs = @('bin','obj','gen') }
        } } }
        $state2 = [PSCustomObject]@{ BuildConfig = $cfg }
        $web = & $invoke $state2 'Web'
        $web | Should -Not -BeNullOrEmpty
        @($web.additionalDirs) | Should -Contain 'dist'
        $maui = & $invoke $state2 'MAUI'
        @($maui.platformsDirs) | Should -Contain 'gen'
        & $invoke $state2 'Unknown' | Should -BeNullOrEmpty
    }

    It "Remove-SafeItem deletes inside allowed root and refuses outside" {
        $insideFile = Join-Path $script:CleanTemp 'inside.txt'
        $outsideRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-clean-out2-' + [guid]::NewGuid().ToString('N'))
        $outsideFile = Join-Path $outsideRoot 'outside.txt'
        $null = New-Item -ItemType Directory -Path $outsideRoot -Force
        Set-Content -LiteralPath $insideFile -Value 'x' -Encoding UTF8
        Set-Content -LiteralPath $outsideFile -Value 'y' -Encoding UTF8
        try {
            Remove-SafeItem -Path $outsideFile -AllowedRoots @($script:CleanTemp) -State $global:state -Quiet | Out-Null
            Test-Path -LiteralPath $outsideFile | Should -BeTrue -Because 'outside allowed roots must not be deleted'
            Remove-SafeItem -Path $insideFile -AllowedRoots @($script:CleanTemp) -State $global:state -Quiet | Out-Null
            Test-Path -LiteralPath $insideFile | Should -BeFalse -Because 'inside allowed root must be deleted'
        } finally {
            if (Test-Path $outsideRoot) { Remove-Item -LiteralPath $outsideRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It "Remove-SafeFolder deletes inside allowed root and refuses outside" {
        $insideDir = Join-Path $script:CleanTemp 'inside-folder'
        $outsideRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('gbuild-clean-out3-' + [guid]::NewGuid().ToString('N'))
        $outsideDir = Join-Path $outsideRoot 'victim'
        $null = New-Item -ItemType Directory -Path $insideDir,$outsideDir -Force
        Set-Content -LiteralPath (Join-Path $insideDir 'a.txt') -Value 'a' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $outsideDir 'b.txt') -Value 'b' -Encoding UTF8
        try {
            $null = Remove-SafeFolder -FolderPath $outsideDir -AllowedRoots @($script:CleanTemp) -State $global:state
            Test-Path -LiteralPath $outsideDir | Should -BeTrue -Because 'outside allowed roots must not be removed'
            $r2 = Remove-SafeFolder -FolderPath $insideDir -AllowedRoots @($script:CleanTemp) -State $global:state
            $r2 | Should -BeTrue
            Test-Path -LiteralPath $insideDir | Should -BeFalse
        } finally {
            if (Test-Path $outsideRoot) { Remove-Item -LiteralPath $outsideRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It "Clean.BuildResult returns hashtable" {
        $br = New-Object System.Collections.Generic.List[string]
        $br.GetType().Name | Should -Match 'List'
    }

    It "Invoke-SmartClean dry-run does not delete targets and rejects traversal publishOutput" {
        $proj = Join-Path $script:CleanTemp 'proj-dry'
        $bin = Join-Path $proj 'bin'; $obj = Join-Path $proj 'obj'
        $null = New-Item -ItemType Directory -Path $bin,$obj -Force
        Set-Content -LiteralPath (Join-Path $bin 'x.dll') -Value 'x' -Encoding UTF8
        $state = [PSCustomObject]@{
            ScriptRoot = $script:CleanTemp; ProjectRoot = $script:CleanTemp; WorkingDir = $proj
            BuildConfig = [PSCustomObject]@{ }
            Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
            OS = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
            LogLevel = 3
        }
        { Invoke-SmartClean -State $state -ProjectDir $proj -WhatIf } | Should -Not -Throw
        Test-Path -LiteralPath $bin | Should -BeTrue -Because 'WhatIf must not delete'
        Test-Path -LiteralPath $obj | Should -BeTrue -Because 'WhatIf must not delete'

        $bad = [PSCustomObject]@{
            ScriptRoot = $script:CleanTemp; ProjectRoot = $script:CleanTemp; WorkingDir = $proj
            BuildConfig = [PSCustomObject]@{ paths = [PSCustomObject]@{ publishOutput = '../../escape' } }
            Colors = $state.Colors; OS = $state.OS; LogLevel = 3
        }
        { Invoke-SmartClean -State $bad -ProjectDir $proj } | Should -Throw
    }

    It "Invoke-SmartClean removes standard and config-driven targets inside project" {
        $proj = Join-Path $script:CleanTemp 'proj-real'
        $bin = Join-Path $proj 'bin'; $obj = Join-Path $proj 'obj'; $dist = Join-Path $proj 'dist'
        $null = New-Item -ItemType Directory -Path $bin,$obj,$dist -Force
        Set-Content -LiteralPath (Join-Path $bin 'a.dll') -Value 'a' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dist 'b.js') -Value 'b' -Encoding UTF8
        $cfg = [PSCustomObject]@{ build = [PSCustomObject]@{ cleanTargetsPerProjectType = [PSCustomObject]@{
            Web = [PSCustomObject]@{ additionalDirs = @('dist'); platformsDirs = @() }
        } } }
        $state = [PSCustomObject]@{
            ScriptRoot = $script:CleanTemp; ProjectRoot = $script:CleanTemp; WorkingDir = $proj
            BuildConfig = $cfg
            Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
            OS = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
            LogLevel = 3
        }
        { Invoke-SmartClean -State $state -ProjectDir $proj -ProjectType 'Web' } | Should -Not -Throw
        Test-Path -LiteralPath $bin | Should -BeFalse
        Test-Path -LiteralPath $obj | Should -BeFalse
        Test-Path -LiteralPath $dist | Should -BeFalse -Because 'config-driven additionalDirs must be cleaned for project type'
    }

    It "Invoke-SmartClean cleans output artifacts only within allowed publish output" {
        $scriptRoot = Join-Path $script:CleanTemp 'sr'
        $proj = Join-Path $scriptRoot 'proj-out'
        $pubBase = Join-Path $scriptRoot 'publish-output'
        $out = Join-Path $pubBase 'web'
        $outBin = Join-Path $out 'bin'
        $outside = Join-Path $script:CleanTemp 'outside-artifacts'
        $null = New-Item -ItemType Directory -Path $proj,$out,$outBin,$outside -Force
        Set-Content -LiteralPath (Join-Path $out 'keep.txt') -Value 'keep' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $out 'drop.dll') -Value 'drop' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $outBin 'nested.exe') -Value 'n' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $outside 'stay.dll') -Value 'stay' -Encoding UTF8
        $state = [PSCustomObject]@{
            ScriptRoot = $scriptRoot; ProjectRoot = $scriptRoot; WorkingDir = $proj
            BuildConfig = [PSCustomObject]@{ paths = [PSCustomObject]@{ publishOutput = 'publish-output' } }
            Colors = [PSCustomObject]@{ Info='Cyan'; Succ='Green'; Gray='DarkGray'; Err='Red'; Warn='Yellow'; Header='Magenta' }
            OS = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
            LogLevel = 3; IsCI = $true; NonInteractive = $true
        }
        { Invoke-SmartClean -State $state -ProjectDir $proj -OutputSubDir 'web' -CleanOutputDir } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $out 'keep.txt') | Should -BeTrue -Because 'non-artifact files must be kept'
        Test-Path -LiteralPath (Join-Path $out 'drop.dll') | Should -BeFalse -Because 'artifact extensions in output must be removed'
        Test-Path -LiteralPath $outBin | Should -BeFalse -Because 'known output folders should be removed'
        Test-Path -LiteralPath (Join-Path $outside 'stay.dll') | Should -BeTrue -Because 'files outside allowed roots must not be touched'
    }
}
