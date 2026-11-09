# SDK

38 function(s). Source: `Modules/SDK.psm1`

### Get-SdkConfigDefaults

### Get-SdkConfigValue

Parameters: PropertyName :String, State :PSObject

### Update-AndroidSdkConfig

Parameters: State :PSObject

### GetAndroidPriorityPaths

Parameters: State :PSObject

### Get-CommonSdkPaths

Parameters: State :PSObject

### Test-ExeWithTimeout

Parameters: ExePath :String, Arguments :String, TimeoutMilliseconds :Int32, State :PSObject

### Get-SdkExePath

Parameters: SdkRoot :String, ToolType :String

### Test-IsGhostSdk

Parameters: ExePath :String, State :PSObject

### Test-SdkExe

Parameters: ExePath :String, ToolType :String, State :PSObject

### Invoke-SmartScan

Parameters: RootPath :String, Filter :String, ValidateScript :ScriptBlock, MaxDepth :Int32, Label :String, State :PSObject

### Find-SdkByDirectory

Parameters: RootPath :String, MaxDepth :Int32, DirectoryPatterns :String[], Exe :String, Label :String, ValidateScript :ScriptBlock, State :PSObject

### Get-SdkCacheFile

Parameters: State :PSObject

### Get-CachedSdk

Parameters: State :PSObject, SdkName :String

### Set-CachedSdk

Parameters: State :PSObject, SdkName :String, Path :String

### Register-SdkCandidate

Parameters: ExePath :String, ToolType :String, State :PSObject, LogLabel :String

### Find-SdkFromEnvHome

Parameters: State :PSObject, ToolType :String

### Find-SdkFromSystemPath

Parameters: State :PSObject, ToolType :String

### Find-SdkFromCache

Parameters: State :PSObject, ToolType :String

### Find-SdkInPriorityPaths

Parameters: State :PSObject, ToolType :String

### Find-SdkInProjectTree

Parameters: State :PSObject, ToolType :String

### Find-SdkOnWindowsDrives

Parameters: State :PSObject, ToolType :String

### Find-SdkFromCustomPaths

Parameters: State :PSObject, ToolType :String

### Get-ModuleState

Parameters: State :PSObject

### Test-IsAdmin

### Get-LatestSdkTfm

Parameters: DotnetExe :String

### ConvertTo-DotnetVersionTriple

Parameters: Version :String

### Get-GlobalJsonSdkPin

Parameters: State :PSObject

### Get-InstalledDotnetSdks

Parameters: DotnetExe :String

### Test-DotnetPinSatisfied

Parameters: RequiredVersion :String, InstalledSdks :String[], RollForward :String

### Compare-DotnetVersion

Parameters: A :String, B :String

### Get-ReleaseMetadataCachePath

Parameters: State :PSObject

### Get-LatestReleasedSdkVersion

Parameters: State :PSObject, Channel :String

### Install-SdkFromRemote

Parameters: State :PSObject, ToolType :String, RequiredVersion :String

### Get-SdkMemoKey

Parameters: ToolType :String, State :PSObject

### Reset-SdkMemo

### Get-SmartSdk

Parameters: State :PSObject, ToolType :String

### Resolve-PinnedDotnetSdk

Parameters: State :PSObject, CandidateExe :String

### Resolve-DotnetSdkCommand

Parameters: State :PSObject, PreferredPath :String


