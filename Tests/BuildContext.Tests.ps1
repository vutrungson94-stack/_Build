$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent $here) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'BuildContext — class construction' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'BuildContext.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Import-Module (Join-Path $global:GBuildModuleRoot 'Container.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    It 'New-BuildContext returns a BuildContext with defaults' {
        $ctx = New-BuildContext
        $ctx.GetType().Name | Should -Be 'BuildContext'
        $ctx.ErrorLog.GetType().Name | Should -Be 'ArrayList'
        $ctx.ErrorLog.Count | Should -Be 0
        $ctx.Colors.Header | Should -Be 'Magenta'
    }

    It 'BuildContext exposes LogError / AddTempFile / ResolvePath' {
        $ctx = New-BuildContext
        $ctx.LogError('boom', 'Test')
        $ctx.ErrorLog.Count | Should -Be 1
        $ctx.ErrorLog[0].Category | Should -Be 'Test'
        $tmpFile = Join-Path $TestDrive 'x.tmp'
        $ctx.AddTempFile($tmpFile)
        $ctx.TempFiles.Count | Should -Be 1
    }

    It 'ResolvePath returns rooted path unchanged' {
        $ctx = New-BuildContext
        $projRoot = Join-Path $TestDrive 'proj'
        $ctx.ProjectRoot = $projRoot
        $absPath = Join-Path (Join-Path $TestDrive 'abs') 'y.txt'
        $ctx.ResolvePath($absPath) | Should -Be $absPath
        $ctx.ResolvePath('rel.txt') | Should -Be (Join-Path $projRoot 'rel.txt')
    }
}

Describe 'BuildContext — DI registration' {
    BeforeAll {
        Import-Module (Join-Path $global:GBuildModuleRoot 'BuildContext.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Import-Module (Join-Path $global:GBuildModuleRoot 'Container.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    It 'Seeds known properties from a PSCustomObject seed' {
        $seed = [PSCustomObject]@{
            ScriptRoot   = (Join-Path $TestDrive 'sr')
            ProjectRoot  = (Join-Path $TestDrive 'pr')
            TenantId     = 't1'
            CorrelationId = 'c1'
            OS           = 'Windows'
        }
        $ctx = New-BuildContext -Seed $seed
        $ctx.ScriptRoot | Should -Be $seed.ScriptRoot
        $ctx.ProjectRoot | Should -Be $seed.ProjectRoot
        $ctx.TenantId | Should -Be 't1'
        $ctx.CorrelationId | Should -Be 'c1'
    }

    It 'Registers and resolves BuildContext via DI container' {
        Clear-Services
        $seed = [PSCustomObject]@{ ScriptRoot = $TestDrive; ProjectRoot = $TestDrive; TenantId = 't1'; OS = 'Windows' }
        Register-Service -Name 'BuildContext' -Factory { New-BuildContext -Seed $seed } -Singleton
        $svc = Resolve-Service 'BuildContext'
        $svc.GetType().Name | Should -Be 'BuildContext'
        $svc.TenantId | Should -Be 't1'
    }

    It 'Coerces PSCustomObject seed Colors to hashtable (repeat-in-session regression)' {
        # Logging.Set-StateColors stamps GState.Colors as PSCustomObject; the
        # re-seed in Orchestrator.Resolve-BuildSdk used to throw 'Exception
        # setting "Colors"... Cannot convert PSCustomObject to Hashtable' on
        # the second Start-GBuild in one session, aborting the build.
        $seed = [PSCustomObject]@{
            ScriptRoot = $TestDrive
            Colors = [PSCustomObject]@{ Gray = 'DarkGray'; Warn = 'Yellow'; Err = 'Red'; Succ = 'Green'; Info = 'Cyan'; Header = 'Magenta'; White = 'White' }
        }
        { $ctx = New-BuildContext -Seed $seed } | Should -Not -Throw
        $ctx = New-BuildContext -Seed $seed
        $ctx.Colors.GetType().Name | Should -Be 'Hashtable'
        $ctx.Colors['Info'] | Should -Be 'Cyan'
        $ctx.Colors['Err'] | Should -Be 'Red'
    }

    It 'Passes hashtable seed Colors through unchanged' {
        $seed = [PSCustomObject]@{
            ScriptRoot = $TestDrive
            Colors = @{ Info = 'Cyan'; Err = 'Red' }
        }
        $ctx = New-BuildContext -Seed $seed
        $ctx.Colors.GetType().Name | Should -Be 'Hashtable'
        $ctx.Colors['Info'] | Should -Be 'Cyan'
    }

    It 'ConvertTo-ColorsHashtable coerces every shape to hashtable (never throws)' {
        $r1 = & (Get-Module BuildContext) { ConvertTo-ColorsHashtable -Colors ([PSCustomObject]@{ Info = 'Cyan'; Err = 'Red' }) }
        $r1.GetType().Name | Should -Be 'Hashtable'
        $r1['Info'] | Should -Be 'Cyan'
        $r2 = & (Get-Module BuildContext) { ConvertTo-ColorsHashtable -Colors @{ Info = 'Cyan' } }
        $r2.GetType().Name | Should -Be 'Hashtable'
        $r2['Info'] | Should -Be 'Cyan'
        $r3 = & (Get-Module BuildContext) { ConvertTo-ColorsHashtable -Colors $null }
        $r3.GetType().Name | Should -Be 'Hashtable'
        $r3['Header'] | Should -Be 'Magenta'
        $r4 = & (Get-Module BuildContext) { ConvertTo-ColorsHashtable -Colors 'garbage' }
        $r4.GetType().Name | Should -Be 'Hashtable'
        $r4['Header'] | Should -Be 'Magenta'
    }
}
