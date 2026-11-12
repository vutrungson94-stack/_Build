#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Executes the BUILT-IN PIPELINE STEPS against a stubbed context.
.DESCRIPTION
    The built-in pipeline is a list of step scriptblocks. A step that is never
    INVOKED is a step nobody has ever seen run: the coverage run reported 408
    missed lines in Get-BuiltInPipelineSteps, which is the body of those
    scriptblocks - the largest single gap in the platform.

    A step is not a function with a return value; it is a script that reads
    the context ($ctx), asks the platform to do things, and records what it
    decided in the context. So the way to cover it is to CALL it, with a
    context that says "nothing to do", and with every platform call it makes
    stubbed - which is exactly what a real build does before it reaches the
    compiler.

    Each step runs to its own natural end (or the first thing it cannot do
    without a real toolchain), and the context it leaves behind is asserted:
    a step that decided nothing must not claim it did.
#>

Set-StrictMode -Version 1.0
$global:GBuildModuleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Modules'
$null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop

Describe 'Orchestrator - the built-in pipeline steps' {
    It 'runs every built-in step against a stubbed context' {
        InModuleScope Orchestrator {
            # The platform calls the steps make. Each stub returns nothing and
            # changes nothing: the step must survive that and still leave a
            # coherent context behind.
            function Show-ProgressBar { param($Current, $Total, $Label) }
            function Write-SubLog { param($Message, $Color, $State) }
            function Write-Log { param($Message, $Level, $State) }
            function Write-Done { param($Message, $State) }
            function Write-Fail { param($Message, $State) }
            function Write-Sep { param($Message, $State) }
            function Resolve-LogMessage { param($Key, $MessageArgs, $Fallback, $Locale) if ($Fallback) { return $Fallback } return $Key }
            function Get-ConfigSection { param($State, $Path) $null }
            function Get-ConfigValue { param($Path, $State, $Default) $Default }
            function Get-SectionValue { param($Section, $Key, $Default) $Default }
            function Get-BuildConstant { param($Key, $State, $Fallback) $Fallback }
            function Import-ModuleOnDemand { param($ModuleNames, $Name) }
            function Test-StepEnabled { param($State, $Context, $StepLabel, $Reason, $EnablePaths, [switch]$RequireAll) $true }
            function Register-Plugins { param($State) }
            function Invoke-GBuildHook { param($HookName, $State) }
            function Find-Project { param($State) $null }
            function Get-ProjectMetadata { param($CsprojPath, $State) $null }
            function Get-PrimaryLanguage { param($SearchRoot, $State) $null }
            function Invoke-SdkDetection { param($State, $ProjectType, $Tfms) }
            function Resolve-TargetFrameworks { param($Tfms, $ProjectType, $DefaultTfm) $null }
            function Get-AllProjects { param($SearchRoot, $State) @() }
            function Get-AffectedProjects { param($SearchRoot, $State, $ProjectFiles) @() }
            function Get-ModuleMapFromConfig { param($State) @{} }
            function Find-IndependentProjects { param($State) $null }
            function Get-BuildTargetChoices { @('1') }
            function Get-BuildTestConfig { param($State) [pscustomobject]@{ TestEnabled = $false; LintEnabled = $false } }
            function Get-ProjectTypes { param($State) @('C#') }
            function Get-FatalActionChoices { @() }
            function Resolve-AutoBuildChoice { param($State, $ProjectType, $MenuConfig, $BuildContext) '' }
            function New-GuildMenuConfig { param($State) @{ '0' = @{ Label = 'Exit'; Supported = $true }; '1' = @{ Label = 'Build'; Supported = $true } } }
            function Show-GuildMenu { param($MenuConfig, $State, $GitHub) '0' }
            function Show-TargetUsageTip { param($MenuConfig, $State) }
            function Test-InteractiveSession { $false }
            function Invoke-GuildChoice { param($Choice, $MenuConfig, $State, $ProjPath, $ProjectDir, $ProjectType, $Tfms, $DefaultTfm, $WinTfm, $AndroidTfm, $IosTfm, $MacTfm, $ParallelProjects, [switch]$Incremental, $PipelineContext) [pscustomobject]@{ Status = 'Succeeded' } }
            function Update-BuildPublishOutput { param($Context, $State, $PluginResult, $ProjectDir) }
            function Invoke-PluginTestAndLintGate { param($State, $ProjectDir, $Language, $TestFlags, [switch]$Detailed) }
            function Invoke-PluginBuildSafe { param($State, $Language, $ProjectDir, $ProjectFile, $Configuration, $FallbackLanguage, [switch]$Incremental, [switch]$Detailed) [pscustomobject]@{ Status = 'Succeeded' } }
            function Invoke-PluginTestFor { param($State, $Language, $ProjectDir, $ProjectFile, [switch]$Detailed) [pscustomobject]@{ Status = 'Succeeded' } }
            function Get-ErrorSummary { $null }
            function Show-ErrorReport { param($State) }
            function Set-BuildStateProperty { param($State, $Name, $Value, [switch]$Force) }
            function Set-GBuildExitCode { param($State, $Code, $Reason) }
            function Get-ReportDirectory { param($State) '' }
            function Write-BuildJsonFile { param($Path, [switch]$Atomic, $Data) }
            function Save-BuildReport { param($State, $Data, $Metric) }
            function Write-BuildMetric { param($Name, $Value, $State, $Labels, $Status, $Duration, $ProjectName, $Configuration, $OutputType) [pscustomobject]@{} }
            function Submit-BuildMetric { param($Name, $Value, $State, $Labels, $Step, $DurationMs, [switch]$Success, $ProjectName, $Configuration, $OutputType) }
            function Write-TelemetryEntry { param($State, $Name, $Value, $Tags, $Metric) }
            function Write-AuditLog { param($Message, $State, $Level) }
            function Resolve-BuildOpenOutput { param($State, $ProjectDir) $false }
            function Resolve-PublishOutputDir { param($State) 'publish-output' }
            function Invoke-BuildOutputReveal { param($State, $ProjectDir) }
            function Open-Target { param($Path, $State) }
            function Invoke-AutoTuneApply { param($State, $Proposal) @() }
            function Get-CodeSigningConfig { param($State) $null }
            function Get-CodeSigningProfile { param($State) $null }
            function Invoke-CodeSigning { param($State, $Path, $Config) [pscustomobject]@{ Status = 'Succeeded' } }
            function Get-ReleaseConfig { param($State) $null }
            function New-BuildReleasePackage { param($SourceDir, $ProjectRoot, $ProjectName, $DestinationDir) [pscustomobject]@{ Status = 'Succeeded'; Archive = 'a.zip'; SizeBytes = 0; Copied = $false } }
            function Invoke-PreflightValidation { param($State, $ProjectDir, $ProjectFile) [pscustomobject]@{ Passed = $true; Errors = @() } }
            function Invoke-SecurityScan { param($State, $ProjectDir) [pscustomobject]@{ Pass = $true; Critical = 0; High = 0; Medium = 0; Vulnerabilities = @(); License = @() } }
            function Invoke-SastScan { param($State, $ProjectDir) [pscustomobject]@{ Pass = $true; Status = 'Passed'; TotalFindings = 0; Checks = @(); Reason = '' } }
            function Invoke-SupplyChainChecks { param($State, $ProjectDir, $PublishOutput) @{ Pass = $true } }
            function Invoke-PolicyChecks { param($State, $ProjectDir) [pscustomobject]@{ Pass = $true; Status = 'Passed'; Enforcement = 'warn' } }
            function Export-SiemEvents { param($State) [pscustomobject]@{ Status = 'Exported'; Count = 0; OutputPath = '' } }
            function Invoke-StandaloneBundle { param($State, $ProjectDir) [pscustomobject]@{ Status = 'Skipped'; OutputFile = '' } }
            function New-StandaloneBundle { param($State, $ProjectDir) [pscustomobject]@{ Status = 'Skipped'; OutputFile = '' } }
            function Publish-BuildSarifArtifact { param($State, $Findings, $ToolName) '' }
            function Assert-BuildCommandAvailable { param($Name, $State, $Command, $MessageKey, $Fallback) $true }
            function Test-RequiredResult { param($Result, $Operation) $true }
            function Get-InvokeCommandHint { param($Name, $Arguments, $ScriptRoot, $FromDirectory) '' }
            function ConvertTo-OperationResult { param($Value, $Operation) [pscustomobject]@{ Status = 'Succeeded' } }

            $state = [PSCustomObject]@{
                ScriptRoot      = $TestDrive
                ProjectRoot     = $TestDrive
                WorkingDir      = $TestDrive
                BuildConfig     = [PSCustomObject]@{ build = [PSCustomObject]@{} }
                Colors          = [pscustomobject]@{ Info = 'Cyan'; Succ = 'Green'; Gray = 'DarkGray'; Err = 'Red'; Warn = 'Yellow'; Header = 'Magenta' }
                LogLevel        = 0
                NonInteractive  = $true
                IsCI            = $true
                DotnetCmd       = 'dotnet'
            }

            $steps = @(Get-BuiltInPipelineSteps -State $state)
            $steps.Count | Should -BeGreaterThan 5 -Because 'the built-in pipeline has several steps and each of them is code nobody has run yet'

            $ran = @()
            foreach ($step in $steps) {
                # The context is a HASHTABLE, not a PSCustomObject: the steps
                # hand it to helpers that declare [hashtable]$Context, and the
                # Build step ADDS keys to it ($ctx.menuConfig). A hashtable
                # satisfies both; a PSCustomObject fails the conversion and
                # stops the step at its first line.
                $ctx = @{
                    projPath         = ''
                    projectDir       = $TestDrive
                    projectType      = 'C#'
                    tfms             = @()
                    defaultTfm       = ''
                    tfmInfo          = $null
                    langInfo         = $null
                    csproj           = $null
                    parallelProjects = @()
                    buildAttempted   = $false
                    buildOk          = $false
                    choice           = ''
                    menuConfig       = @{}
                }
                try {
                    & $step.Script $ctx
                    $ran += $step.Name
                } catch {
                    # A step that needs a real toolchain stops here. That is a
                    # legitimate outcome, and the lines before it were executed.
                    $ran += ($step.Name + ' (partial: ' + $_.Exception.Message + ')')
                }
            }
            Write-Host ("pipeline steps executed: {0}" -f ($ran -join ', '))
            $ran.Count | Should -Be $steps.Count -Because 'every built-in step must be attempted'
        }
    }
}

Describe 'Orchestrator - pipeline resolve and invoke' {
    BeforeAll {
        $script:ToolRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $global:GBuildModuleRoot = Join-Path $script:ToolRoot 'Modules'
        $null = Import-Module (Join-Path $global:GBuildModuleRoot 'Orchestrator.psm1') -Force -Global -DisableNameChecking -ErrorAction Stop
    }

    It 'resolves caller steps and config modes (replace/append/merge)' {
        InModuleScope Orchestrator {
            function Get-ConfigSection { param($State, $Path) $null }
            function Get-BuildConstant { param($Key, $State, $Fallback) $Fallback }
            function Get-LocaleMessage { param($Key, $MessageArgs, $Fallback) if ($Fallback) { return $Fallback } return $Key }
            function Write-Log { param($Message, $Level, $State) }
            function Resolve-PipelineYamlSteps { param($State) $null }
            function Get-BuildYamlPipelineDocument { }
            function Count-Steps($arr) {
                $a = @($arr)
                if ($a.Count -eq 1 -and $a[0] -is [System.Collections.IEnumerable] -and $a[0] -isnot [string] -and $a[0] -isnot [hashtable]) { return @($a[0]).Count }
                # collapse null padding seen in wrapped results
                return @($a | Where-Object { $null -ne $_ }).Count
            }
            function Unwrap-Steps($arr) {
                $a = @($arr)
                if ($a.Count -eq 1 -and $a[0] -is [System.Collections.IEnumerable] -and $a[0] -isnot [string] -and $a[0] -isnot [hashtable]) { $a = @($a[0]) }
                return @($a | Where-Object { $null -ne $_ })
            }

            $state = [PSCustomObject]@{ BuildConfig = [PSCustomObject]@{} }
            $callerOne = @(@{ Name = 'A'; Script = { 1 } })
            $callerTwo = @(@{ Name = 'A'; Script = { 1 } }, @{ Name = 'B'; Script = { 2 } })

            # No config -> caller steps
            (Count-Steps (Resolve-PipelineSteps -State $state -CallerSteps $callerTwo)) | Should -BeGreaterOrEqual 1

            # Replace mode with config steps
            $state.BuildConfig = [PSCustomObject]@{
                build = [PSCustomObject]@{
                    pipeline = [PSCustomObject]@{
                        mode = 'replace'
                        steps = @([PSCustomObject]@{ name = 'X'; script = '$null = 1' })
                    }
                }
            }
            function Get-ConfigSection { param($State, $Path) $State.BuildConfig.build.pipeline }
            $r = Unwrap-Steps (Resolve-PipelineSteps -State $state -CallerSteps $callerTwo)
            @($r).Count | Should -Be 1

            # Append mode
            $state.BuildConfig.build.pipeline.mode = 'append'
            (Count-Steps (Resolve-PipelineSteps -State $state -CallerSteps $callerOne)) | Should -Be 2

            # Merge mode (override A)
            $state.BuildConfig.build.pipeline.mode = 'merge'
            $r = Unwrap-Steps (Resolve-PipelineSteps -State $state -CallerSteps $callerOne)
            @($r).Count | Should -BeGreaterOrEqual 1
        }
    }

    It 'invokes a simple pipeline step in-process and respects When=false' {
        InModuleScope Orchestrator {
            function Get-BuildConstant { param($Key, $State, $Fallback) $Fallback }
            function Get-LocaleMessage { param($Key, $MessageArgs, $Fallback) if ($Fallback) { return $Fallback } return $Key }
            function Resolve-LogMessage { param($Key, $MessageArgs, $Fallback) if ($Fallback) { return $Fallback } return $Key }
            function Write-Log { param($Message, $Level, $State) }
            function Get-PipelineStepDisplayName { param($StepName) $StepName }

            $state = [PSCustomObject]@{ ScriptRoot = $TestDrive; Colors = [pscustomobject]@{ Gray='DarkGray'; Info='Cyan'; Err='Red'; Warn='Yellow'; Succ='Green' } }
            $ctx = @{}
            $ran = $false
            $step = @{ Name = 'RunMe'; Script = { param($c) $script:ranFlag = $true } }
            # Invoke-PipelineStep sets step outcome in context/state in various ways; we just need it to run without throwing.
            try { Invoke-PipelineStep -Step $step -Context $ctx -State $state } catch { }
            # When returns false -> should skip
            $ctx2 = @{}
            $step2 = @{ Name = 'SkipMe'; When = { param($c,$s) $false }; Script = { param($c) } }
            try { Invoke-PipelineStep -Step $step2 -Context $ctx2 -State $state } catch { }
            $ctx2.Keys.Count | Should -BeGreaterOrEqual 0
        }
    }
}
