# Cache

35 function(s). Source: `Modules/Cache.psm1`

### Get-CanonicalCacheKey

Parameters: Key :String

### Enter-CacheIndexLock

Parameters: IndexPath :String, TimeoutMs :Int32

### Save-CacheIndexAtomic

Parameters: Data :Object, FilePath :String

### Test-CacheOutputPath

Parameters: OutputPath :String, AllowedRoots :String[]

### Get-CacheIndexEntry

Parameters: Index :Object, Key :String

### BuildCache

### ResolveCachePath

### Initialize

### GetOutputRoots

### GetEntry

### SaveEntry

### IsValid

### GetStatistics

### IsDeletionSafe

### ClearCache

### Optimize

### Ensure-BuildCacheForState

Parameters: State :PSObject

### Initialize-BuildCache

Parameters: State :PSObject, CacheDir :String, MaxSizeMB :Int32

### Get-FileHashFast

Parameters: Paths :String[]

### Get-ProjectHash

Parameters: ProjectPath :String, IncludeExtensions :String[]

### Get-DirectoryHash

Parameters: Directory :String, IncludeExtensions :String[]

### Get-CacheEntry

Parameters: Key :String

### Save-CacheEntry

Parameters: Key :String, ProjectHash :String, OutputPath :String, Metadata :Hashtable

### Test-CacheValid

Parameters: Key :String, ProjectHash :String

### Remove-CacheEntry

Parameters: Key :String

### Save-BuildCacheEntry

Parameters: Key :String, ProjectHash :String, OutputPath :String, Metadata :Hashtable, ProjectPath :String

### Test-RemoteCacheSyncEnabled

Parameters: State :PSObject, Flag :String

### Test-CacheBuildResult

Parameters: Result :Object

### Invoke-BuildWithCache

Parameters: ProjectPath :String, CacheKey :String, BuildAction :ScriptBlock, Metadata :Hashtable, State :PSObject, PrecomputedHash :String, BuildMetadata :Hashtable

### Get-CacheStatistics

### Show-CacheStats

Parameters: State :PSObject

### Clear-BuildCache

Parameters: State :PSObject, Force :SwitchParameter

### Optimize-Cache

Parameters: State :PSObject, MaxSizeMB :Int32

### Get-BuildCache

### Get-AffectedProjects

Parameters: ProjectFiles :String[], SinceRef :String, SkipGitDiff :SwitchParameter, State :PSObject


