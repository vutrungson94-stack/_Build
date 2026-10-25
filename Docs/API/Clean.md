# Clean

9 function(s). Source: `Modules/Clean.psm1`

### Get-CleanTargetDirNames

### Get-CleanTargetsConfig

Parameters: State :PSObject, ProjectType :String

### Invoke-Retry

Parameters: Action :ScriptBlock, MaxRetries :Int32, DelayBaseSec :Int32

### Assert-SafePath

Parameters: Target :String, AllowedRoots :String[]

### Remove-SafeItem

Parameters: Path :String, AllowedRoots :String[], State :PSObject, Quiet :SwitchParameter

### Remove-SafeFolder

Parameters: FolderPath :String, AllowedRoots :String[], State :PSObject

### Add-CleanTarget

Parameters: Path :String, AllowedRoots :String[], Targets :List`1

### Invoke-SmartClean

Parameters: State :PSObject, ProjectDir :String, OutputSubDir :String, CsprojPath :String, ProjectType :String, CleanOutputDir :SwitchParameter

### Remove-SafeFolderStandalone

Parameters: FolderPath :String


