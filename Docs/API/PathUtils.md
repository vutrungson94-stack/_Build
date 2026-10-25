# PathUtils

15 function(s). Source: `Modules/PathUtils.psm1`

### ConvertTo-ForwardSlash

Parameters: Path :String

### Format-Path

Parameters: Path :String, Base :String

### Get-SafeJoinPath

Parameters: Base :String, Child :String

### Test-BuildProjectMarker

Parameters: Path :String

### Resolve-BuildProjectRoot

Parameters: StartDir :String, ExplicitProject :String, MaxDepth :Int32, State :Object

### Test-BuildVolumeRoot

Parameters: Path :String

### Test-SafePath

Parameters: Path :String, Base :String, AllowRelative :SwitchParameter

### Get-BuildRootDirectory

Parameters: State :Object

### Resolve-BuildRootedPath

Parameters: RelativePath :String, State :Object

### Test-PathUnderRoots

Parameters: Path :String, AllowedRoots :String[]

### Test-NoReparsePointInPath

Parameters: Path :String

### Get-ExcludeDirPattern

Parameters: Dirs :String[], Extra :String[], FromConstant :String, FallbackDirs :String[], State :Object

### Invoke-EnsureDirectory

Parameters: Path :String

### Resolve-NativePath

Parameters: Path :String

### Find-ProjectManifest

Parameters: Root :String, Filters :String[], Recurse :SwitchParameter, MaxDepth :Int32, State :Object


