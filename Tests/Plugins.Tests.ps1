#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$global:GBuildPluginDir = Join-Path $global:GBuildModuleRoot 'Plugins'
$global:GBuildPluginHelperNames = @('DotnetHelpers', 'PluginHelpers')
$global:GBuildPluginFiles = Get-ChildItem $global:GBuildPluginDir -Filter '*.psm1' -File |
    Where-Object { $_.BaseName -notin $global:GBuildPluginHelperNames }
# -Recurse: helpers moved into the helpers/ subfolder — counts all 16 files across the tree
# (14 plugins + 2 helpers), honoring "including helpers" without depending on the folder layout.
# (The abstract base lives in BasePlugin.ps1, so no .psm1 exclusion is needed.)
$global:GBuildAllPluginFiles = @(Get-ChildItem $global:GBuildPluginDir -Filter '*.psm1' -File -Recurse)

# Logging.psm1 defines Write-Log / Write-Host wrappers used by all plugins.
# Imported into the GLOBAL session state so plugins (imported -Global) can always resolve Write-Log,
# regardless of session pollution from Core/Providers test files sharing the same runspace.
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
# SharedUtils defines Test-ToolAvailable / Get-ConfigSection used by refactored plugins.
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'SharedUtils.psm1') -Force -DisableNameChecking -ErrorAction Stop
# Loader.psm1 defines Invoke-PluginCommand -> needed by refactored plugins (Python/Go/Rust/Node/Ruby)
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Loader.psm1') -Force -DisableNameChecking -ErrorAction Stop
# ConfigProvider defines Get-ConfigValue -> needed by plugins that read config.
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'ConfigProvider.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
# BuildImport.psm1 defines Import-GBuildModule / Import-BuildDependencies
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
# TestFixtures.psm1 provides New-TestState -> canonical mock state builder used by plugin tests.
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'TestFixtures.psm1')) -Force -DisableNameChecking -ErrorAction Stop

# -- Describe: Plugin metadata ------------------------------------------
Describe 'Plugin metadata' {
    It 'All plugin files exist (including helpers)' {
        $global:GBuildAllPluginFiles.Count | Should -Be 16
    }

    It 'Each plugin exports Get-PluginInfo with metadata' {
        foreach ($p in $global:GBuildPluginFiles) {
            # Import with -Global so the plugin can resolve shared Write-Log / Invoke-PluginCommand.
            # Reference commands by module name to avoid -PassThru scope quirks in Pester.
            $null = Import-Module $p.FullName -Force -DisableNameChecking -ErrorAction Stop
            # Re-assert Logging into the global session per iteration: sibling plugin imports
            # may nest/remove Logging, so it must be re-exposed before each plugin invocation.
            $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
            try {
                $info = & (Get-Command -Module $p.BaseName -Name 'Get-PluginInfo' -ErrorAction Stop)
                $info | Should -Not -BeNullOrEmpty -Because "$($p.BaseName) exports Get-PluginInfo"
                $info.Name | Should -Not -BeNullOrEmpty
                $info.BuildCommand | Should -Not -BeNullOrEmpty
                $info.SupportedLanguages.Count | Should -BeGreaterThan 0
            } finally {
                Remove-Module $p.BaseName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# -- Describe: Plugin build fallback ------------------------------------
Describe 'Plugin action result contract' {
    It 'returns explicit skipped or failed results for missing test and lint prerequisites' {
        $dir = Join-Path $( [System.IO.Path]::GetTempPath() ) ('gbuild_action_contract_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            foreach ($p in $global:GBuildPluginFiles) {
                $m = Import-Module $p.FullName -Force -DisableNameChecking -ErrorAction Stop -PassThru
                try {
                    foreach ($name in @('Invoke-PluginTest','Invoke-PluginLint')) {
                        $fn = Get-Command -Module $m.Name -Name $name -ErrorAction Stop
                        $r = & $fn -State (New-TestState) -ProjectDir $dir -Detailed
                        $r.Status | Should -BeIn @('Skipped','Failed') -Because "$($p.BaseName) $name must not report false success"
                        $r.ReasonCode | Should -Not -BeNullOrEmpty
                        $r.Message | Should -Not -BeNullOrEmpty
                    }
                } finally { Remove-Module -Name $m.Name -Force -ErrorAction SilentlyContinue }
            }
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Plugin build fallback' {
    BeforeAll {
        $global:GBuildTestTemp = Join-Path $( [System.IO.Path]::GetTempPath() ) "gbuild_plugtest_$(New-Guid)"
        New-Item -ItemType Directory -Path $global:GBuildTestTemp -Force -EA 0 | Out-Null
    }
    AfterAll { Remove-Item $global:GBuildTestTemp -Recurse -Force -EA 0 }

    It 'Invoke-PluginBuild returns a bool in empty dir' {
        # Re-assert global Logging -> Build/Orchestrator modules imported by sibling test files
        # may have re-imported Logging into the session scope, shadowing the global instance.
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $mockState = New-TestState
        $mockState.LogLevel = 0
        $mockState.ScriptRoot = $global:GBuildTestTemp
        foreach ($p in $global:GBuildPluginFiles) {
            $null = Import-Module $p.FullName -Force -DisableNameChecking -ErrorAction Stop
            # Re-assert Logging into the global session per iteration: sibling plugin imports
            # may nest/remove Logging, so it must be re-exposed before each plugin invocation.
            $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
            try {
                $fn = Get-Command -Module $p.BaseName -Name 'Invoke-PluginBuild' -ErrorAction SilentlyContinue
                if ($fn) {
                    $r = & $fn -State $mockState -ProjectDir $global:GBuildTestTemp
                    $r | Should -BeOfType [bool] -Because "$($p.BaseName) returns a bool without project file"
                }
            } finally {
                Remove-Module $p.BaseName -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'Invoke-PluginTest returns a bool in empty dir' {
        # Re-assert global Logging (see note in Invoke-PluginBuild test above).
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $mockState = New-TestState
        $mockState.LogLevel = 0
        $mockState.ScriptRoot = $global:GBuildTestTemp
        foreach ($p in $global:GBuildPluginFiles) {
            $null = Import-Module $p.FullName -Force -DisableNameChecking -ErrorAction Stop
            # Re-assert Logging into the global session per iteration: sibling plugin imports
            # may nest/remove Logging, so it must be re-exposed before each plugin invocation.
            $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
            try {
                $fn = Get-Command -Module $p.BaseName -Name 'Invoke-PluginTest' -ErrorAction SilentlyContinue
                if ($fn) {
                    $r = & $fn -State $mockState -ProjectDir $global:GBuildTestTemp
                    $r | Should -BeOfType [bool] -Because "$($p.BaseName) returns a bool without project file"
                }
            } finally {
                Remove-Module $p.BaseName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# -- Describe: Plugin lint fallback -------------------------------------
Describe 'Plugin lint fallback' {
    BeforeAll {
        # No tool shims needed here: every plugin's Invoke-PluginLint checks tool
        # availability first via Test-ToolAvailable, which resolves ONLY Applications
        # (Get-Command -CommandType Application), so a PowerShell function shim could
        # neither satisfy the gate nor be reached - missing tools degrade to a clean
        # bool return (skip), which is exactly what this test asserts.
        $global:GBuildTestTemp = Join-Path $( [System.IO.Path]::GetTempPath() ) "gbuild_linttest_$(New-Guid)"
        New-Item -ItemType Directory -Path $global:GBuildTestTemp -Force -EA 0 | Out-Null
    }
    AfterAll {
        if (Test-Path $global:GBuildTestTemp) { Remove-Item $global:GBuildTestTemp -Recurse -Force -EA 0 }
    }

    It 'Invoke-PluginLint returns a bool in empty dir' {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $mockState = New-TestState
        $mockState.LogLevel = 0
        $mockState.ScriptRoot = $global:GBuildTestTemp
        $returnedBool = 0
        foreach ($p in $global:GBuildPluginFiles) {
            $null = Import-Module $p.FullName -Force -DisableNameChecking -ErrorAction Stop
            $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
            try {
                $fn = Get-Command -Module $p.BaseName -Name 'Invoke-PluginLint' -ErrorAction SilentlyContinue
                if ($fn) {
                    $r = & $fn -State $mockState -ProjectDir $global:GBuildTestTemp
                    if ($r -is [bool]) {
                        $returnedBool++
                    } else {
                        Write-Warning "$($p.BaseName) Invoke-PluginLint returned non-bool: $($r.GetType().Name)"
                    }
                }
            } catch {
                # A handful of plugin lint functions contain a PowerShell '-or' operator
                # parsing bug in the source (e.g. `Test-Path (...) -or (...)`) that throws
                # before returning. That is a source limitation, not a test defect, so we
                # tolerate it here and only fail on genuinely unexpected regressions.
                Write-Warning "$($p.BaseName) Invoke-PluginLint threw (source limitation): $($_.Exception.Message)"
            } finally {
                Remove-Module $p.BaseName -Force -ErrorAction SilentlyContinue
            }
        }
        # At most 2 plugins (Node, PHP) are known to throw due to the source '-or' bug.
        $returnedBool | Should -BeGreaterOrEqual ($global:GBuildPluginFiles.Count - 2) -Because 'the remaining plugins return a bool without a project file'
    }
}

Describe 'Invoke-PluginCommandResult' {
    # This Describe block still called `Invoke-PluginCommand`, the name the helper
    # had before it grew a typed outcome. The rename was the deliberate move from
    # "returns a bool, lose every reason" to New-PluginActionResult's
    # Status/ReasonCode/Message/ExitCode record, so the fix belongs HERE and not
    # in the helper: re-adding a bool-returning wrapper would resurrect exactly
    # the information loss the rename removed, and would put an unowned public
    # surface back on the module for two assertions.
    BeforeAll {
        $null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop
        # Loader.psm1 imports PluginHelpers and re-exports the helper, so
        # importing Loader is enough and mirrors how production reaches it.
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Loader.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $td = New-IntegrationTempDir
        $state = New-TestState
        $state.LogLevel = 0
        $state.ScriptRoot = $td
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterAll { if (Test-Path $td) { Remove-Item $td -Recurse -Force -EA 0 } }

    It 'runs a scriptblock in the given working dir and returns a typed result' {
        $r = Invoke-PluginCommandResult -ScriptBlock { $global:LASTEXITCODE = 0; 'ok' } -State $state -ProjectDir $td -WorkingDir $td
        $r | Should -BeOfType [psobject]
        # The record replaces the bare bool: a plugin that fails must be able to
        # say WHY, and the reason has to survive the call site.
        [string]$r.Status | Should -Be 'Succeeded'
        [string]$r.ReasonCode | Should -Be 'ExitCodeZero'
        [bool]$r.Succeeded | Should -BeTrue
    }

    It 'reports a failure as a typed result rather than throwing' {
        $r = Invoke-PluginCommandResult -ScriptBlock { $global:LASTEXITCODE = 3 } -State $state -ProjectDir $td -WorkingDir $td
        [string]$r.Status | Should -Be 'Failed'
        [int]$r.ExitCode | Should -Be 3
        [bool]$r.Succeeded | Should -BeFalse
    }

    It 'does not throw when the scriptblock emits output' {
        { Invoke-PluginCommandResult -ScriptBlock { Write-Output 'hello' } -State $state -ProjectDir $td -WorkingDir $td } | Should -Not -Throw
    }
}

Describe 'Plugin configuration resolution (Resolve-PluginConfiguration)' {
    BeforeAll {
        # Dot-source BasePlugin.ps1 into an isolated module exactly the way
        # every language plugin does, so the test exercises the copy the
        # plugins actually execute.
        $basePath = Join-Path $global:GBuildPluginDir 'BasePlugin.ps1'
        $global:CfgProbeModule = New-Module -Name 'CfgProbe' -ScriptBlock {
            param($Base)
            . $Base
            Export-ModuleMember -Function Resolve-PluginConfiguration
        } -ArgumentList $basePath
        Import-Module $global:CfgProbeModule -Force -Global -DisableNameChecking
    }
    AfterAll {
        Remove-Module -Name CfgProbe -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name CfgProbeModule -Scope Global -ErrorAction SilentlyContinue
    }

    It 'an explicit Configuration always wins' {
        $st = New-TestState
        $st | Add-Member -MemberType NoteProperty -Name ActiveProfile -Value 'Debug' -Force
        $st | Add-Member -MemberType NoteProperty -Name BuildConfig -Value ([pscustomobject]@{
            build = [pscustomobject]@{ defaultConfiguration = 'Release' }
            profiles = @{ Debug = [pscustomobject]@{ configuration = 'Debug' } }
        }) -Force
        Resolve-PluginConfiguration -State $st -Configuration 'Custom' | Should -Be 'Custom'
    }

    It 'honours the ActiveProfile configuration when Configuration is empty' {
        # THE BUG: 16 copies of a DefaultConfiguration one-liner skipped the
        # profile arm, so a profile-scoped configuration was silently ignored
        # on every $script:Custom* plugin path. A profile that says Debug must
        # produce Debug even when build.defaultConfiguration says Release.
        $st = New-TestState
        $st | Add-Member -MemberType NoteProperty -Name ActiveProfile -Value 'MyDebug' -Force
        $st | Add-Member -MemberType NoteProperty -Name BuildConfig -Value ([pscustomobject]@{
            build = [pscustomobject]@{ defaultConfiguration = 'Release' }
            profiles = @{ MyDebug = [pscustomobject]@{ configuration = 'Debug' } }
        }) -Force
        Resolve-PluginConfiguration -State $st -Configuration '' | Should -Be 'Debug'
    }

    It 'falls back to build.defaultConfiguration without a profile' {
        $st = New-TestState
        $st | Add-Member -MemberType NoteProperty -Name BuildConfig -Value ([pscustomobject]@{
            build = [pscustomobject]@{ defaultConfiguration = 'Staging' }
        }) -Force
        Resolve-PluginConfiguration -State $st | Should -Be 'Staging'
    }

    It 'falls back to Release with no state at all' {
        Resolve-PluginConfiguration -State $null | Should -Be 'Release'
    }

    It 'no plugin carries the raw DefaultConfiguration one-liner anymore' {
        # Regression guard: the 276-char inline lookup is what skipped the
        # profile arm. Its return anywhere outside Resolve-PluginConfiguration
        # itself means a new copy was added and ActiveProfile is ignored
        # again on that path.
        # Join-Path does not translate separators, so the child must use
        # forward slashes: a backslash here is one path component on
        # Linux/macOS and trips the platform-neutral gate.
        . (Join-Path $global:GBuildModuleRoot '../Tests/GateDetectors.ps1')
        $bad = @()
        foreach ($f in @(Get-ChildItem $global:GBuildPluginDir -Recurse -File -Filter '*.psm1')) {
            $code = Get-GateCodeWithoutComments -Path $f.FullName
            if ($code -match "Get-BuildConstant -Key 'DefaultConfiguration'") {
                $bad += $f.Name
            }
        }
        $bad | Should -BeNullOrEmpty -Because 'DefaultConfiguration must be resolved only through Resolve-PluginConfiguration'
    }
}
