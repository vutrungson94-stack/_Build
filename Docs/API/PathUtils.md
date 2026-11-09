# PathUtils

22 function(s). Source: `Modules/PathUtils.psm1`

### ConvertTo-ForwardSlash

Parameters: Path :String

### Format-Path

Parameters: Path :String, Base :String

### Get-SafeJoinPath

Parameters: Base :String, Child :String

### Get-PathComparison

### Test-IsWindowsHost

### Get-CanonicalOSName

Parameters: OS :String

### Test-BuildProjectMarker

Parameters: Path :String

### Resolve-BuildProjectRoot

Parameters: StartDir :String, ExplicitProject :String, MaxDepth :Int32, State :Object

### Test-BuildPathEqual

Parameters: PathA :String, PathB :String

### Get-BuildProjectCandidateDirectories

Parameters: Path :String, MaxDepth :Int32, MaxResults :Int32

### Test-BuildVolumeRoot

Parameters: Path :String

### Test-SafePath

Parameters: Path :String, Base :String

### Get-BuildRootDirectory

Parameters: State :Object

### Resolve-BuildRootedPath

Parameters: RelativePath :String, State :Object

### Test-PathUnderRoots

Parameters: Path :String, AllowedRoots :String[]

### Test-ReparsePointItem

Parameters: Path :String

### Test-NoReparsePointInPath

Parameters: Path :String

### Get-ExcludeDirPattern

Parameters: Dirs :String[], Extra :String[], FromConstant :String, FallbackDirs :String[], State :Object

### Invoke-EnsureDirectory

Parameters: Path :String

### Resolve-NativePath

Parameters: Path :String

### Resolve-BuildContainedPath

Parameters: Path :String, Base :String, State :PSObject, RequireDirectory :SwitchParameter, MustExist :SwitchParameter

### Find-ProjectManifest

Parameters: Root :String, Filters :String[], Recurse :SwitchParameter, MaxDepth :Int32, State :Object


