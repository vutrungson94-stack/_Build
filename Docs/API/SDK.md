# SDK

26 function(s). Source: `Modules/SDK.psm1`

### Get-SdkConfigDefaults

### Get-SdkConfigValue

Parameters: PropertyName :String, State :PSObject

### Update-AndroidSdkConfig

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

### Install-SdkFromRemote

Parameters: State :PSObject, ToolType :String

### Get-SmartSdk

Parameters: State :PSObject, ToolType :String


