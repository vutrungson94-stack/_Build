# CacheProvider

50 function(s). Source: `Modules/CacheProvider.psm1`

### Get-ProcessEnvironmentSnapshot

Parameters: Names :String[]

### Restore-ProcessEnvironmentSnapshot

Parameters: Snapshot :Hashtable

### Invoke-WithAwsCredentials

Parameters: Credentials :PSObject, ScriptBlock :ScriptBlock, Region :String

### Get-CacheHADefault

Parameters: Key :String, Fallback :Object

### Get-CacheTenantPrefix

Parameters: State :PSObject

### ConvertTo-CacheKeyPath

Parameters: Key :String

### Resolve-CacheKey

Parameters: State :PSObject, Key :String

### Get-CacheLogicalKey

Parameters: State :PSObject, RemoteKey :String

### Get-CacheStateRoot

Parameters: State :PSObject

### Test-CachePathUnderRoot

Parameters: Path :String, Root :String

### Resolve-CacheLocalRoot

Parameters: State :PSObject

### Get-LocalCacheDir

Parameters: State :PSObject

### Get-LocalCacheConfig

Parameters: State :PSObject

### Resolve-CacheLocalPath

Parameters: State :PSObject, RelativePath :String, LocalRoot :String

### Test-CacheDestinationPath

Parameters: State :PSObject, Path :String

### Get-CacheRemoteLimit

Parameters: State :PSObject

### Get-ExpectedCacheChecksum

Parameters: State :PSObject, ExpectedSha256 :String

### Get-CacheResponseChecksum

Parameters: Response :Object

### Get-CacheFileSha256

Parameters: Path :String

### Test-CacheFileSize

Parameters: Path :String, MaxBytes :Int64

### Move-CacheFileAtomic

Parameters: SourcePath :String, DestinationPath :String

### Compress-CacheFile

Parameters: SourcePath :String, DestinationPath :String

### Expand-CacheFile

Parameters: SourcePath :String, DestinationPath :String, MaxBytes :Int64

### Invoke-CacheEviction

Parameters: State :PSObject, CacheDir :String

### Invoke-UnifiedCacheEviction

Parameters: State :PSObject, CacheDir :String

### Resolve-CacheAddressValue

Parameters: Value :String

### Get-RemoteCacheConfig

Parameters: State :PSObject, Region :Hashtable

### New-AzureBlobUrl

Parameters: Endpoint :String, Container :String, BlobName :String, SasToken :String

### New-S3SignedUrl

Parameters: Bucket :String, Key :String, Region :String, Expires :Int32, State :PSObject

### Invoke-BoundedCacheDownload

Parameters: Url :String, Path :String, MaxBytes :Int64, TimeoutSec :Int32

### Send-CachePut

Parameters: Url :String, Headers :Hashtable, WorkFile :String, TmpCompressed :String, LogMessage :String, State :PSObject, MaxBytes :Int64

### Send-CacheEntry

Parameters: State :PSObject, Key :String, FilePath :String, Type :String, Compress :SwitchParameter, ExpectedSha256 :String, MaxBytes :Int64, Region :Hashtable, NoReplicate :SwitchParameter

### Complete-CacheReceive

Parameters: Compressed :Boolean, TempFile :String, DestinationPath :String, State :PSObject, ExpectedSha256 :String, MaxBytes :Int64

### Receive-CacheEntry

Parameters: State :PSObject, Key :String, DestinationPath :String, Type :String, Compress :SwitchParameter, ExpectedSha256 :String, MaxBytes :Int64, UseRemoteKey :SwitchParameter, Region :Hashtable, NoReplicaFallback :SwitchParameter

### Receive-CacheEntryFromReplica

Parameters: State :PSObject, Key :String, DestinationPath :String, Type :String, Compress :SwitchParameter, ExpectedSha256 :String, MaxBytes :Int64, UseRemoteKey :SwitchParameter

### Test-CacheHAFailoverPosture

Parameters: State :PSObject

### Test-CacheEntryExists

Parameters: State :PSObject, Key :String, Type :String

### Update-CacheToLocal

Parameters: State :PSObject

### Update-CacheToRemote

Parameters: State :PSObject

### Get-HAEnabled

Parameters: State :PSObject

### Get-PrimaryCacheConfig

Parameters: State :PSObject

### Get-HAReplicaConfigs

Parameters: State :PSObject

### Test-RegionHealth

Parameters: RegionConfig :Hashtable, State :PSObject, TimeoutSec :Int32

### Get-HealthyRegions

Parameters: State :PSObject

### Select-WriteRegion

Parameters: State :PSObject

### Select-ReadRegion

Parameters: State :PSObject

### Copy-ToRegion

Parameters: SourceRegion :Hashtable, TargetRegion :Hashtable, Key :String, LocalFilePath :String, State :PSObject

### Invoke-HAReplication

Parameters: State :PSObject, Key :String, LocalFilePath :String

### Invoke-HAFailoverCheck

Parameters: State :PSObject

### Invoke-HAFailbackCheck

Parameters: State :PSObject


