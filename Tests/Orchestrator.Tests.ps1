#Requires -Version 5.1
#Requires -Module Pester

# PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS
. (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'PlatformShim.ps1'))

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildImport.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
$null = Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) (Join-Path 'Helpers' 'MockHelpers.psm1')) -Force -DisableNameChecking -ErrorAction Stop

Describe "Orchestrator Integration" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop

        # Build a state with Colors (New-FullTestState omits it) — Write-Info/_2Col
        # need a Colors object. Declared here (BeforeAll scope) so it is visible to the Its.
        $global:state = New-FullTestState
        $global:state | Add-Member -MemberType NoteProperty -Name Colors -Value ([PSCustomObject]@{ Info='Cyan';Succ='Green';Gray='DarkGray';Err='Red';Warn='Yellow';Header='Magenta' }) -Force -EA 0
        $os = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
        $global:state | Add-Member -MemberType NoteProperty -Name OS -Value $os -Force -EA 0
        $global:menu = @{
            '0' = @{ Supported = $true; Title = 'Exit' }
            'G' = @{ Supported = $true; Title = 'Google Cloud Run' }
            'C' = @{ Supported = $true; Title = 'Cache Statistics' }
        }
    }

    It "Import-ModuleOnDemand loads a module without throwing and is idempotent" {
        { Import-ModuleOnDemand -ModuleNames @('Cache') } | Should -Not -Throw
        { Import-ModuleOnDemand -ModuleNames @('Cache') } | Should -Not -Throw
    }

    It "Invoke-GuildChoice handles the exit choice '0' without throwing" {
        { Invoke-GuildChoice -Choice '0' -MenuConfig $global:menu -State $global:state } | Should -Not -Throw
    }

    It "Invoke-GuildChoice 'G' lazy-loads DeployTargets and degrades gracefully without gcloud" {
        { Invoke-GuildChoice -Choice 'G' -MenuConfig $global:menu -State $global:state -ProjectDir $global:state.ProjectRoot -ProjectType 'Web' } | Should -Not -Throw
    }

    It "Invoke-GuildChoice 'T' forwards the detected language" {
        $global:GBuildTestCapturedLanguage = $null
        Mock Invoke-PluginTestFor -ModuleName Orchestrator -MockWith {
            param($Language)
            $global:GBuildTestCapturedLanguage = $Language
            $true
        }
        try {
            $state = [PSCustomObject]@{
                BuildConfig = [PSCustomObject]@{}
                Colors = [PSCustomObject]@{ Info='Cyan';Succ='Green';Gray='DarkGray';Err='Red';Warn='Yellow';Header='Magenta' }
                LogLevel = 3
            }
            $menu = @{ T = @{ Supported = $true; Title = 'Tests' } }
            $context = @{ langInfo = [PSCustomObject]@{ Language = 'Python' } }
            Invoke-GuildChoice -Choice 'T' -MenuConfig $menu -State $state -ProjectDir $state.ProjectRoot -ProjectType 'Unknown' -PipelineContext $context
            $global:GBuildTestCapturedLanguage | Should -Be 'Python'
        }
        finally {
            Remove-Variable -Name GBuildTestCapturedLanguage -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It "Invoke-GuildChoice 'I' forwards the detected language" {
        $global:GBuildTestCapturedLanguage = $null
        Mock Invoke-PluginLintFor -ModuleName Orchestrator -MockWith {
            param($Language)
            $global:GBuildTestCapturedLanguage = $Language
            $true
        }
        try {
            # Explicit toggle: this test is about language forwarding, not the
            # lint default (TestLintEnabled defaults to $false, so an empty
            # BuildConfig would skip before reaching the language dispatch).
            $state = [PSCustomObject]@{
                BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ test = [PSCustomObject]@{ lintEnabled = $true } } }
                Colors = [PSCustomObject]@{ Info='Cyan';Succ='Green';Gray='DarkGray';Err='Red';Warn='Yellow';Header='Magenta' }
                LogLevel = 3
            }
            $menu = @{ I = @{ Supported = $true; Title = 'Lint' } }
            $context = @{ langInfo = [PSCustomObject]@{ Language = 'Node.js' } }
            Invoke-GuildChoice -Choice 'I' -MenuConfig $menu -State $state -ProjectDir $state.ProjectRoot -ProjectType 'Unknown' -PipelineContext $context
            $global:GBuildTestCapturedLanguage | Should -Be 'Node.js'
        }
        finally {
            Remove-Variable -Name GBuildTestCapturedLanguage -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It "Resolve-TargetFrameworks returns TFM objects for a Web project" {
        $r = Resolve-TargetFrameworks -Tfms @('net8.0', 'net8.0-android') -ProjectType 'Web' -DefaultTfm 'net8.0'
        $r | Should -Not -BeNullOrEmpty
        $r.AndroidTfm | Should -Be 'net8.0-android'
    }

    It "Test-PreFlight does not throw" {
        { Test-PreFlight -State $global:state } | Should -Not -Throw
    }
}

Describe "Orchestrator banner and hooks" {
    BeforeAll {
        $td = New-IntegrationTempDir
        $global:state = [PSCustomObject]@{
            ScriptRoot  = $td
            ProjectRoot = $td
            WorkingDir  = $td
            BuildConfig = [PSCustomObject]@{ }
            Colors      = [PSCustomObject]@{ Info='Cyan';Succ='Green';Gray='DarkGray';Err='Red';Warn='Yellow';Header='Magenta' }
            OS          = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
            LogLevel    = 3
        }
        $global:GState = [PSCustomObject]@{ ScriptRoot=$td; ProjectRoot=$td; BuildConfig=$null; LogLevel=3 }
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1')    -Force -DisableNameChecking -ErrorAction Stop
    }
    AfterAll {
        if (Test-Path $td) { Remove-Item $td -Recurse -Force -EA 0 }
        Remove-Variable -Name GState -Scope Global -Force -EA 0
    }

    It "Show-GBuildBanner renders without throwing" {
        { Show-GBuildBanner } | Should -Not -Throw
    }

    It "Format-GBuildBannerLines renders three equal-width lines" {
        $mod = Get-Module Orchestrator
        $lines = @( & $mod { Format-GBuildBannerLines -Text 'gbuild - PowerShell Build System' } )
        $lines.Count | Should -Be 3
        $lines[0] | Should -Match '^\+\=+\+$'
        $lines[1].Length | Should -Be $lines[0].Length
        $lines[2].Length | Should -Be $lines[0].Length
        $lines[2] | Should -Be $lines[0]
    }

    It "Format-GBuildBannerLines centers text and adapts to long locale strings" {
        $mod = Get-Module Orchestrator
        $long = 'gbuild - He thong Build PowerShell mo rong cho doanh nghiep ABCDEF'
        $lines = @( & $mod { param($t) Format-GBuildBannerLines -Text $t } $long )
        $lines[1].Length | Should -Be $lines[0].Length
        $lines[1] | Should -BeLike "*$long*"
        $at = $lines[1].IndexOf($long)
        $leftPad = $at - 2
        $rightPad = $lines[1].Length - $at - $long.Length - 2
        [Math]::Abs($leftPad - $rightPad) | Should -BeLessOrEqual 1
    }

    It "bool-returning helpers are never called bare (no stray True on the console)" {
        # A bare call to a bool-returning helper prints 'True'/'False' into the
        # build log. Every such call site must sink the return via [void], a
        # pipe to Out-Null, or an assignment.
        $path = Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1'
        $bare = @()
        foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8)) {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith('#') -or $t -match '^\s*Export-ModuleMember\b') { continue }
            foreach ($fn in @('Write-AnomalyHistory', 'Send-AnomalyAlertIfNeeded', 'Test-PreFlight', 'Write-RootCauseHistory')) {
                if ($t -match ('(?<!function\s)' + $fn + '\b') -and $t -notmatch 'Get-Command' -and $t -notmatch '\[void\]' -and $t -notmatch 'Out-Null' -and $t -notmatch '=' -and $t -notmatch '^\s*(if|elseif|while|until|switch|foreach|return|throw|param)\b') {
                    $bare += "$fn :: $t"
                }
            }
        }
        $bare | Should -BeNullOrEmpty
    }

    It "gate failure messages always name the stage (no raw tool message throw)" {
        # The raw gate message ("Command failed with exit code 2") never says
        # whether tests or lint failed. Every gate throw site must compose the
        # locale stage message with the tool detail instead of throwing the
        # raw message.
        $path = Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1'
        $raw = @()
        foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8)) {
            $t = $line.Trim()
            if ($t -match '^\$message = if \(\$(testGate|lintGate)\.Message\)') { $raw += $t }
        }
        $raw | Should -BeNullOrEmpty
    }

    It "Invoke-GBuildHook runs the before-build hook without throwing" {
        { Invoke-GBuildHook -State $global:state -HookName 'before-build' } | Should -Not -Throw
    }

    It "Invoke-GBuildHook runs the after-build hook without throwing" {
        { Invoke-GBuildHook -State $global:state -HookName 'after-build' -Success $true } | Should -Not -Throw
    }
}

Describe "Resolve-TargetFrameworks from a .csproj" {
    BeforeAll {
        $td = New-IntegrationTempDir
        $csproj = Join-Path $td 'Sample.csproj'
        Set-Content -Path $csproj -Value '<Project><PropertyGroup><TargetFramework>net9.0-windows</TargetFramework></PropertyGroup></Project>' -Force
        $global:tfm = ([regex]::Match((Get-Content $csproj -Raw), '<TargetFramework>\s*([^<]+)\s*</TargetFramework>')).Groups[1].Value.Trim()
    }
    AfterAll { if (Test-Path $td) { Remove-Item $td -Recurse -Force -EA 0 } }

    It "parses the single TFM from a .csproj into a Windows TFM" {
        $r = Resolve-TargetFrameworks -Tfms @($global:tfm) -ProjectType 'WinForms' -DefaultTfm 'net9.0'
        $r | Should -Not -BeNullOrEmpty
        $r.WinTfm | Should -Be $global:tfm
    }

    It "returns empty platform TFMs when no platform TFM is present" {
        $r = Resolve-TargetFrameworks -Tfms @('net9.0') -ProjectType 'Web' -DefaultTfm 'net9.0'
        $r.WinTfm    | Should -BeNullOrEmpty
        $r.AndroidTfm | Should -BeNullOrEmpty
        $r.IosTfm     | Should -BeNullOrEmpty
        $r.MacTfm     | Should -BeNullOrEmpty
    }
}

Describe "Get-ActiveProfile" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "returns null when no profiles configured" {
        $st = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{} }
        Get-ActiveProfile -State $st -ProfileName 'Release' | Should -BeNullOrEmpty
    }

    It "returns null when profile does not exist" {
        $st = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    Debug = [PSCustomObject]@{ configuration = 'Debug' }
                }
            }
        }
        Get-ActiveProfile -State $st -ProfileName 'NonExistent' | Should -BeNullOrEmpty
    }

    It "resolves simple profile without extends" {
        $st = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    Release = [PSCustomObject]@{ configuration = 'Release'; optimize = $true }
                }
            }
        }
        $r = Get-ActiveProfile -State $st -ProfileName 'Release'
        $r.configuration | Should -Be 'Release'
        $r.optimize | Should -BeTrue
    }

    It "resolves inheritance chain via extends" {
        $st = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    base = [PSCustomObject]@{ config = 'Release'; shared = $true }
                    child = [PSCustomObject]@{ extends = 'base'; config = 'Debug' }
                }
            }
        }
        $r = Get-ActiveProfile -State $st -ProfileName 'child'
        $r.config | Should -Be 'Debug'
        $r.shared | Should -BeTrue
    }

    It "auto-includes default profile when not in chain" {
        $st = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    default = [PSCustomObject]@{ baseSetting = 'from-default' }
                    CI      = [PSCustomObject]@{ ciOnly = $true }
                }
            }
        }
        $r = Get-ActiveProfile -State $st -ProfileName 'CI'
        $r.ciOnly | Should -BeTrue
        $r.baseSetting | Should -Be 'from-default'
    }
}

Describe "Test-BuildConfig validation" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "returns true for a valid config" {
        $st = New-FullTestState
        $ok = Test-BuildConfig -State $st
        $ok | Should -BeTrue
    }
}

Describe "Target catalog & list" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Menu.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:tcState = [PSCustomObject]@{
            ScriptRoot    = (Split-Path -Parent $PSCommandPath)
            BuildConfig   = [PSCustomObject]@{
                build = [PSCustomObject]@{
                    menu = [PSCustomObject]@{
                        moduleMap = [PSCustomObject]@{
                            1 = @('Build', 'Android')
                            2 = @('Build', 'Deploy')
                        }
                    }
                }
            }
            OS          = if ($IsWindows){'Windows'}elseif($IsMacOS){'MacOS'}else{'Linux'}
            Colors = [PSCustomObject]@{ Info='Cyan';Succ='Green';Gray='DarkGray';Err='Red';Warn='Yellow';Header='Magenta' }
        }
    }

    It "Get-TargetCatalog returns ordered rows with Key, Label, Title, Modules, DefaultFor" {
        $rows = @(Get-TargetCatalog -State $global:tcState)
        $rows | Should -Not -BeNullOrEmpty
        $first = $rows[0]
        $first.Key | Should -Be '1'
        $first.Label | Should -Be 'Debug on Android Device'
        $first.Modules | Should -Be @('Build', 'Android')
        # MAUI default is TFM-conditional (androidTfm -> '2', windowsTfm -> '8',
        # else '12') per build.menu.defaultActions, so the catalog attributes it
        # to every candidate ID. '1' (manual debug) is never a default for MAUI.
        $row2 = @($rows | Where-Object { $_.Key -eq '2' })[0]
        $row2.DefaultFor | Should -Contain 'MAUI'
    }

    It "Show-TargetList prints without throwing" {
        { Show-TargetList -State $global:tcState } | Should -Not -Throw
    }
}

Describe "Fatal action choices" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'RBAC.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "includes the execution-fatal actions X, Z, O, D by default" {
        # A 100%-failed distributed run (X), a Degraded chaos drill (Z), a
        # failed cluster submit (O) and a failed doctor check (D) used to exit
        # 0 because none of them was in the fatal set.
        $fatal = @(Get-FatalActionChoices)
        $fatal | Should -Contain 'X'
        $fatal | Should -Contain 'Z'
        $fatal | Should -Contain 'O'
        $fatal | Should -Contain 'D'
    }

    It "is a superset of the RBAC privileged set, with no duplicates" {
        $fatal = @((Get-FatalActionChoices) | ForEach-Object { [string]$_ })
        $priv = @((Get-RbacPrivilegedActions) | ForEach-Object { [string]$_ })
        foreach ($k in $priv) { $fatal | Should -Contain $k }
        $fatal.Count | Should -Be (@($fatal | Sort-Object -Unique).Count) -Because 'a duplicated key is the drift signature this list exists to prevent'
    }

    It "honours the build.targetCatalog.fatalChoices operator override" {
        $st = New-FullTestState
        $st | Add-Member -MemberType NoteProperty -Name 'BuildConfig' -Value ([PSCustomObject]@{
            build = [PSCustomObject]@{
                targetCatalog = [PSCustomObject]@{ fatalChoices = @('X', 'Q') }
            }
        }) -Force
        $fatal = @(Get-FatalActionChoices -State $st)
        $fatal | Should -Be @('X', 'Q')
    }
}

Describe "Bootstrap state-mutation compatibility" {    It "Start-GBuild sets StartTime via the Add-Member primitive, never direct assignment" {
        # Direct `$State.StartTime = ...` throws "cannot be found on this
        # object" when StartTime is absent on restricted-adapter hosts and on
        # deserialized states. Lock the safe pattern (house tripwire style).
        $orchPath = Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1'
        $text = Get-Content -LiteralPath $orchPath -Raw -Encoding UTF8
        $text | Should -Not -Match '\$State\.StartTime\s*='
        $text | Should -Match "Set-BuildStateProperty -State \`$State -Name 'StartTime'"
    }
}

Describe "Resolve-AutoBuildChoice (no blind fallback)" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Logging.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $script:choiceState = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{
                build = [PSCustomObject]@{
                    menu = [PSCustomObject]@{
                        defaultActions = [PSCustomObject]@{ WinForms = '8'; default = '12' }
                    }
                }
            }
            Colors = [PSCustomObject]@{ Info='Cyan';Succ='Green';Gray='DarkGray';Err='Red';Warn='Yellow';Header='Magenta' }
            LogLevel = 3
        }
        $script:winMenu = @{
            '8'  = @{ Label = 'Publish WinForms App'; Supported = $true }
            '12' = @{ Label = 'Build default'; Supported = $false }
        }
        $script:plainMenu = @{
            '12' = @{ Label = 'Build default'; Supported = $true }
        }
    }

    It "keeps the product default when supported (WinForms -> '8')" {
        $ctx = [PSCustomObject]@{ tfmInfo = [PSCustomObject]@{ AndroidTfm = ''; WinTfm = '' } }
        Resolve-AutoBuildChoice -MenuConfig $script:winMenu -State $script:choiceState -ProjectType 'WinForms' -BuildContext $ctx | Should -Be '8'
    }

    It "falls back to '12' for unknown types when the menu supports it" {
        $ctx = [PSCustomObject]@{ tfmInfo = [PSCustomObject]@{ AndroidTfm = ''; WinTfm = '' } }
        Resolve-AutoBuildChoice -MenuConfig $script:plainMenu -State $script:choiceState -ProjectType 'Klingon' -BuildContext $ctx | Should -Be '12'
    }

    It "returns '' instead of an invalid choice when neither default nor '12' is supported" {
        $ctx = [PSCustomObject]@{ tfmInfo = [PSCustomObject]@{ AndroidTfm = ''; WinTfm = '' } }
        $dead = @{ '8' = @{ Label = 'Publish WinForms App'; Supported = $false }; '12' = @{ Label = 'Build default'; Supported = $false } }
        { Resolve-AutoBuildChoice -MenuConfig $dead -State $script:choiceState -ProjectType 'WinForms' -BuildContext $ctx } | Should -Not -Throw
        Resolve-AutoBuildChoice -MenuConfig $dead -State $script:choiceState -ProjectType 'WinForms' -BuildContext $ctx | Should -Be ''
    }
}

Describe "Cluster config path (no top-level drift)" {
    It "Orchestrator gates cluster daemons on build.cluster, never top-level 'cluster'" {
        # The shipped config only defines build.cluster (same path Menu 'O'
        # and ClusterOrchestrator init use). A top-level 'cluster' read always
        # returns $null, silently disabling the health job / leader election /
        # operator wiring. Lock the canonical path (house tripwire style).
        $orchFiles = @(Get-ChildItem -LiteralPath $global:GBuildModuleRoot -Filter 'Orchestrator*.ps*' -File -Recurse)
        $text = ($orchFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
        $text | Should -Match "Get-ConfigSection -State \`$State -Path 'build.cluster'"
        $text | Should -Not -Match "-Path 'cluster'"
    }
}

Describe "Quiet operational logging" {
    BeforeAll {
        $script:orchFiles = @(Get-ChildItem -LiteralPath $global:GBuildModuleRoot -Filter 'Orchestrator*.ps*' -File -Recurse)
        $script:orchText = ($script:orchFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    }

    It "does not emit a locale hint during normal builds" {
        $script:orchText | Should -Not -Match 'Write-Log "\[LOCALE\]'
    }

    It "keeps scoped and skipped-step summaries at Debug" {
        # Asserted on the locale KEY rather than the message text. The previous
        # form, 'Write-Log "\[SCOPE\].*''Debug'' \$State', coupled the level
        # assertion to the hardcoded English wording, so routing the message
        # through the i18n layer - which is the point of that layer - broke a
        # test that was never about the wording. The key is the stable identity
        # of the message; the level is what this test is actually about.
        foreach ($key in @('log.orchestrator.m67', 'log.orchestrator.m80')) {
            $script:orchText | Should -Match ([regex]::Escape("Get-LocaleMessage -Key '$key'")) -Because "$key must still be emitted"
            $script:orchText | Should -Match ([regex]::Escape("'$key'") + ".+?'Debug'") -Because "$key must be emitted at Debug"
        }
    }

    It "keeps automatic hook dispatch at Debug" {
        foreach ($key in @('log.orchestrator.m95', 'log.orchestrator.m96')) {
            $script:orchText | Should -Match ([regex]::Escape("'$key'") + ".+?'Debug'") -Because "$key must be emitted at Debug"
        }
    }

    It "ships an English value for every locale key the orchestrator emits" {
        # A key with no en.json entry would make Get-LocaleMessage fall through
        # to printing the key NAME into the build log, which is worse than an
        # untranslated message because it looks like a crash.
        $en = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $global:GBuildModuleRoot) 'Locales/en.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $keys = @([regex]::Matches($script:orchText, "Get-LocaleMessage -Key '(log\.orchestrator\.[A-Za-z0-9]+)'") |
                    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $keys.Count | Should -BeGreaterThan 50 -Because 'the orchestrator is the largest log emitter; a near-empty set means the scan is broken'
        $missing = @($keys | Where-Object { $en.PSObject.Properties.Name -notcontains $_ })
        $missing | Should -BeNullOrEmpty -Because "these keys are emitted but not defined in en.json: $($missing -join ', ')"
    }

    It "refreshes modules from the current gbuild tree on each launcher invocation" {
        $launcherText = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $global:GBuildModuleRoot) 'gbuild.ps1') -Raw -Encoding UTF8
        $launcherText | Should -Match '\$gbuildModulePrefix'
        $launcherText | Should -Match 'Remove-Module -Name \$gbuildLoadedModule\.Name'
    }
}

Describe 'Fail-closed orchestration and entrypoint semantics' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'DeployTargets.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $global:entrypointState = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{}
            Colors = [PSCustomObject]@{ Info='Cyan';Succ='Green';Gray='DarkGray';Err='Red';Warn='Yellow';Header='Magenta' }
            LogLevel = 3
        }
        $global:entrypointMenu = @{ T = @{ Supported = $true; Title = 'Tests' }; I = @{ Supported = $true; Title = 'Lint' } }
    }

    It 'throws for an invalid choice' {
        { Invoke-GuildChoice -Choice 'invalid' -MenuConfig @{ '12' = @{ Supported = $true; Title = 'Build' } } -State $global:entrypointState } | Should -Throw
    }

    It 'throws when a build wrapper returns a failed result' {
        Mock Start-ProjectPublish -ModuleName Orchestrator -MockWith { return [PSCustomObject]@{ Status = 'Failed'; Message = 'build false'; ReasonCode = 'FalseResult' } }
        { Invoke-GuildChoice -Choice '12' -MenuConfig @{ '12' = @{ Supported = $true; Title = 'Build' } } -State $global:entrypointState -DefaultTfm 'net8.0' } | Should -Throw
    }

    It 'throws when test dispatch returns false or null' {
        Mock Invoke-PluginTestFor -ModuleName Orchestrator -MockWith { return $false }
        { Invoke-GuildChoice -Choice 'T' -MenuConfig $global:entrypointMenu -State $global:entrypointState -ProjectType 'Python' } | Should -Throw
        Mock Invoke-PluginTestFor -ModuleName Orchestrator -MockWith { return $null }
        { Invoke-GuildChoice -Choice 'T' -MenuConfig $global:entrypointMenu -State $global:entrypointState -ProjectType 'Python' } | Should -Throw
    }

    It 'propagates deploy false from the registered wrapper' {
        Mock Invoke-DeployTarget -ModuleName Orchestrator -MockWith { return $false }
        $orchestrator = Get-Module Orchestrator
        $result = $orchestrator.Invoke({ param($s,$d,$t) Invoke-RegisteredDeploy -Choice 'G' -State $s -ProjectDir $d -ProjectType $t }, @($global:entrypointState, 'project', 'Web'))
        $result | Should -BeFalse
    }

    It 'returns zero for help, target list, and syntax guide paths' {
        $pwshPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $gbuildPath = Join-Path (Split-Path -Parent $global:GBuildModuleRoot) 'gbuild.ps1'
        foreach ($arguments in @(@('-Help'), @('-Target','list'), @('-SyntaxCheck'))) {
            # The call operator preserves a repository path containing spaces
            # (for example, "...\TRUNG SON\_Build\gbuild.ps1"). Start-Process
            # -ArgumentList joins its array with spaces, which split that same
            # path and tested PowerShell argument parsing instead of gbuild.
            & $pwshPath -NoProfile -NonInteractive -File $gbuildPath @arguments
            $exitCode = $LASTEXITCODE
            if ($null -eq $exitCode) { $exitCode = 0 }
            $exitCode | Should -Be 0
        }
    }

    It 'returns nonzero when the entrypoint receives a build failure' {
        $pwshPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $gbuildPath = Join-Path (Split-Path -Parent $global:GBuildModuleRoot) 'gbuild.ps1'
        & $pwshPath -NoProfile -NonInteractive -File $gbuildPath -Target '__wave1_invalid_target__'
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
        $exitCode | Should -Not -Be 0
    }
}

Describe 'Runtime config toggle contracts' {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildConstants.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'BuildProgress.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Metrics.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It 'resolves test and lint independently' {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ test = [PSCustomObject]@{ enabled = $false; lintEnabled = $true } } } }
        $flags = Get-BuildTestConfig -State $state
        $flags.TestEnabled | Should -BeFalse
        $flags.LintEnabled | Should -BeTrue
    }

    It 'uses the legacy test/lint switch only when canonical values are absent' {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ runTestLint = $false } } }
        $flags = Get-BuildTestConfig -State $state
        $flags.TestEnabled | Should -BeFalse
        $flags.LintEnabled | Should -BeFalse
        $state.BuildConfig.build | Add-Member -MemberType NoteProperty -Name test -Value ([PSCustomObject]@{ enabled = $true; lintEnabled = $false }) -Force
        $flags = Get-BuildTestConfig -State $state
        $flags.TestEnabled | Should -BeTrue
        $flags.LintEnabled | Should -BeFalse
    }

    It 'skips explicit test and lint menu actions when their toggles are disabled' {
        $state = [PSCustomObject]@{
            BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ test = [PSCustomObject]@{ enabled = $false; lintEnabled = $false } } }
            Colors = [PSCustomObject]@{ Info='Cyan';Succ='Green';Gray='DarkGray';Err='Red';Warn='Yellow';Header='Magenta' }
            LogLevel = 3
        }
        $menu = @{ T = @{ Supported = $true; Title = 'Tests' }; I = @{ Supported = $true; Title = 'Lint' } }
        (Invoke-GuildChoice -Choice 'T' -MenuConfig $menu -State $state).Skipped | Should -BeTrue
        (Invoke-GuildChoice -Choice 'I' -MenuConfig $menu -State $state).Skipped | Should -BeTrue
    }

    It 'makes progress.enabled the master switch' {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ build = [PSCustomObject]@{ progress = [PSCustomObject]@{ enabled = $false; streamOutput = $true } } } }
        (Get-ProgressConfig -State $state).Enabled | Should -BeFalse
        $seen = [System.Collections.Generic.List[string]]::new()
        $result = Invoke-WithLiveOutput -ScriptBlock { 'progress-disabled' } -State $state -OnLine { param($line) $seen.Add($line) }
        $result.ExitCode | Should -Be 0
        @($result.Output) | Should -Contain 'progress-disabled'
        $seen.Count | Should -Be 0
    }

It 'gates OTLP export with the telemetry root toggle' {
        $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{ telemetry = [PSCustomObject]@{ enabled = $false; otel = [PSCustomObject]@{ enabled = $true; endpoint = 'http://127.0.0.1:4318' } } } }
        $config = Get-TelemetryConfig -State $state
        $config.enabled | Should -BeFalse
        $config.otel.enabled | Should -BeFalse
        Send-OtelMetrics -State $state -OtelEndpoint 'http://127.0.0.1:4318' | Should -BeFalse
    }
}

Describe "Start-GBuild bootstrap failures exit nonzero" {
    BeforeAll {
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -DisableNameChecking -ErrorAction Stop
    }

    It "throws and records exit 1 when no build state exists" {
        # The GState-not-initialized path used to bare `return` (exit 0).
        # Save + clear every global Start-GBuild could resolve, then restore.
        $hadGState = Test-Path Variable:global:GState
        $savedGState = if ($hadGState) { $global:GState } else { $null }
        $hadServices = (Test-Path Variable:global:GBuildServices) -and $null -ne $global:GBuildServices -and $global:GBuildServices.ContainsKey('BuildContext')
        $savedService = if ($hadServices) { $global:GBuildServices['BuildContext'] } else { $null }
        try {
            Remove-Variable -Name GState -Scope Global -Force -ErrorAction SilentlyContinue
            if ($hadServices) { $global:GBuildServices.Remove('BuildContext') }
            if (Get-Command Reset-GBuildExitCode -ErrorAction SilentlyContinue) { Reset-GBuildExitCode }
            { Start-GBuild } | Should -Throw -Because 'a run with no state must fail, not exit 0'
            if (Get-Command Get-GBuildExitCode -ErrorAction SilentlyContinue) {
                Get-GBuildExitCode | Should -Be 1
            }
        } finally {
            if ($hadGState) { $global:GState = $savedGState }
            if ($hadServices) { $global:GBuildServices['BuildContext'] = $savedService }
            if (Get-Command Reset-GBuildExitCode -ErrorAction SilentlyContinue) { Reset-GBuildExitCode }
        }
    }

    It "every bootstrap failure site records an exit code and throws (no bare return)" {
        # House-tripwire style: the five early-return sites (no state, core
        # commands, invalid config, missing SDK, failed/unavailable infra
        # verification) each exited 0 after logging Err. Each must now contain
        # Set-GBuildExitCode + throw in its failure branch.
        $orchPath = Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1'
        $text = Get-Content -LiteralPath $orchPath -Raw -Encoding UTF8
        $sites = @(
            @{ Name = 'no-state';                 Reason = 'no-state' },
            @{ Name = 'core-commands';            Reason = 'core-commands' },
            @{ Name = 'invalid-config';           Reason = 'invalid-config' },
            @{ Name = 'sdk-missing';              Reason = 'sdk-missing' },
            @{ Name = 'infra-verification';       Reason = 'infra-verification' },
            @{ Name = 'infra-unavailable';        Reason = 'infra-verification-unavailable' }
        )
        foreach ($s in $sites) {
            $text | Should -Match ([regex]::Escape(("Set-GBuildExitCode -Code")) + '.*' + ([regex]::Escape(("-Reason '" + $s.Reason + "'")))) -Because ("bootstrap failure '{0}' must record an exit code" -f $s.Name)
        }
        # And the throw must be present in Start-GBuild (not just the record):
        # count throw statements inside the Start-GBuild body.
        $startIdx = $text.IndexOf('function Start-GBuild')
        $startIdx | Should -BeGreaterThan 0
        $body = $text.Substring($startIdx)
@([regex]::Matches($body, '(?m)^\s*throw\b')).Count | Should -BeGreaterThan 5 -Because 'each bootstrap failure path throws after recording'
    }
}
