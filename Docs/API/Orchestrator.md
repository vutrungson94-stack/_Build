# Orchestrator

39 function(s). Source: `Modules/Orchestrator.psm1`

### Import-ModuleOnDemand

Parameters: ModuleNames :String[]

### Test-BuildConfig

Parameters: State :PSObject, Strict :SwitchParameter

### Test-PreFlight

Parameters: State :PSObject

### Merge-Profile

Parameters: Base :PSObject, Override :PSObject

### Get-ActiveProfile

Parameters: State :PSObject, ProfileName :String

### Get-BuildTestConfig

Parameters: State :PSObject

### Invoke-SdkDetection

Parameters: State :PSObject, ProjectType :String, Tfms :String[]

### Resolve-TargetFrameworks

Parameters: Tfms :String[], ProjectType :String, DefaultTfm :String

### Test-ActionAllowed

Parameters: State :PSObject, Action :String

### Send-AnomalyAlertIfNeeded

Parameters: Report :PSObject, State :PSObject

### Get-ModuleMapFromConfig

Parameters: State :PSObject

### Get-DefaultActionsFromConfig

Parameters: State :PSObject

### Invoke-RegisteredDeploy

Parameters: Choice :String, State :PSObject, ProjectDir :String, ProjectType :String

### Get-DeployChoiceArgs

Parameters: Kind :String, State :PSObject

### Get-DeployDefaultRid

Parameters: State :PSObject

### Get-TargetCatalog

Parameters: State :PSObject

### Show-TargetList

Parameters: State :PSObject

### Resolve-AutoBuildChoice

Parameters: MenuConfig :Hashtable, State :PSObject, ProjectType :String, BuildContext :PSObject

### Invoke-GuildChoice

Parameters: Choice :String, MenuConfig :Hashtable, State :PSObject, ProjPath :String, ProjectDir :String, ProjectType :String, Tfms :String[], DefaultTfm :String, WinTfm :String, AndroidTfm :String, IosTfm :String, MacTfm :String, ParallelProjects :String[], Incremental :SwitchParameter, PipelineContext :Hashtable

### Resolve-PipelineSteps

Parameters: State :PSObject, CallerSteps :Array

### Get-PipelineStepDisplayName

Parameters: StepName :String

### Invoke-PipelineStep

Parameters: Step :Hashtable, Context :Hashtable, State :PSObject, LeftBracket :String, RightBracket :String

### Invoke-GBuildPipeline

Parameters: State :PSObject, Context :Hashtable, Steps :Array

### Initialize-BuildIdentity

Parameters: State :PSObject

### Get-FlowLogLevel

Parameters: State :PSObject, ScopedLevel :String, VerboseLevel :String

### Register-BuildEventSubscribers

Parameters: State :PSObject

### Unregister-BuildEventSubscribers

### Register-BuildServices

Parameters: State :PSObject

### Resolve-BuildEnvironmentAndStrategy

Parameters: State :PSObject, Incremental :SwitchParameter, Clean :SwitchParameter, LogLevel :String

### Show-TargetUsageTip

Parameters: MenuConfig :Hashtable, State :PSObject

### Initialize-BuildLogging

Parameters: State :PSObject, LogLevel :String

### Invoke-StandaloneOperation

Parameters: State :PSObject, CacheClear :SwitchParameter, CacheOptimize :SwitchParameter, CacheStats :SwitchParameter, VersionBump :SwitchParameter

### Initialize-BuildConfigAndProfile

Parameters: State :PSObject

### Assert-CoreCommands

Parameters: State :PSObject, Repair :SwitchParameter

### Resolve-BuildSdk

Parameters: State :PSObject

### Start-GBuild

Parameters: GitHub :SwitchParameter, NonInteractive :SwitchParameter, Incremental :SwitchParameter, Clean :SwitchParameter, CacheClear :SwitchParameter, CacheOptimize :SwitchParameter, CacheStats :SwitchParameter, VersionBump :SwitchParameter, Force :SwitchParameter, Security :SwitchParameter, Distributed :SwitchParameter, VerifyInfra :SwitchParameter, Target :String, LogLevel :String

### Write-SkippedStep

Parameters: Step :String, Reason :String, Context :Object

### Show-GBuildBanner

Parameters: State :PSObject

### Invoke-GBuildHook

Parameters: HookName :String, State :PSObject, Success :Boolean


