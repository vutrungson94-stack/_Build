# Deploy

9 function(s). Source: `Modules/Deploy.psm1`

### Resolve-DeployStatePath

Parameters: State :PSObject, Path :String

### Test-DeployValueSuccess

Parameters: Value :Object

### Test-UrlServing

Parameters: Url :String, State :PSObject

### Invoke-AndroidAabBuild

Parameters: State :Object, ProjPath :Object, AndroidTfm :Object, ProjectDir :Object, ProjectType :String, Incremental :SwitchParameter

### Invoke-WebPublish

Parameters: State :Object, ProjPath :Object, DefaultTfm :Object, ProjectType :String, ProjectDir :Object, Incremental :SwitchParameter

### Invoke-DesktopPublish

Parameters: State :Object, ProjPath :Object, WinTfm :Object, Tfms :Object, DefaultTfm :Object, ProjectType :String, Incremental :SwitchParameter

### Start-ProjectPublish

Parameters: State :Object, ProjPath :Object, Tfm :Object, OutputSubDir :Object, BuildArgs :String[], ProjectType :String, Incremental :SwitchParameter, Detailed :SwitchParameter

### Test-WebAppReady

Parameters: Proc :Object, Url :String, Port :Int32, State :Object

### Test-ProcessExited

Parameters: Proc :Object, State :Object


