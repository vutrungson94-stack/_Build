# Build

15 function(s). Source: `Modules/Build.psm1`

### Get-ProjectTypeActions

Parameters: State :PSObject, ProjectType :String

### Get-CacheArtifactPatterns

Parameters: State :PSObject, OutputSubDir :String, ExeBaseName :String

### New-BuildResult

Parameters: Status :String, Operation :String, ReasonCode :String, Message :String, ExitCode :Int32, Details :Object, OutputPath :String

### Get-BuildPluginCacheKey

Parameters: State :PSObject, ProjectPath :String, Tfm :String, Configuration :String, InputHash :String

### Invoke-AndroidArtifactDeploy

Parameters: State :PSObject, OutputDir :String, CsprojContent :String, OutputSubDir :String, ExeBaseName :String

### Invoke-BuildOutputReveal

Parameters: State :PSObject, OutputDir :String, ProjectType :String

### Start-BuildAndShow

Parameters: State :PSObject, Project :String, Tfm :String, OutputSubDir :String, BuildArgs :String[], ProjectType :String, Configuration :String, Incremental :SwitchParameter, Detailed :SwitchParameter

### Invoke-DeviceDebug

Parameters: State :PSObject, Project :String, Tfm :String

### Invoke-AutoDeploy

Parameters: State :PSObject, ApkPath :String, AppId :String, AndroidSdkPath :String

### Stop-ProcessByPort

Parameters: State :PSObject, ProjectDir :String, ProjectType :String, ExeName :String, OutputDir :String

### Publish-AndroidAab

Parameters: State :PSObject, ProjectPath :String, Tfm :String, Keystore :Object, ProjectType :String, Incremental :SwitchParameter

### New-AndroidAab

Parameters: State :PSObject, ProjectPath :String, Tfm :String, Keystore :Object, ProjectType :String, Incremental :SwitchParameter

### Invoke-GitHubBuild

Parameters: State :PSObject, PackageFormat :String

### Invoke-GuildParallelBuild

Parameters: State :PSObject, Projects :String[], Tfm :String, MaxJobs :Int32

### Invoke-GuildDistributedBuild

Parameters: State :PSObject, Projects :String[]


