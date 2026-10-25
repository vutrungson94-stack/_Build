# DeployTargets

32 function(s). Source: `Modules/DeployTargets.psm1`

### Resolve-DeployContainedPath

Parameters: State :PSObject, Path :String, RequireDirectory :SwitchParameter

### Test-DeployToken

Parameters: Value :String, MaxLength :Int32

### Invoke-DeployTool

Parameters: Name :String, Arguments :String[]

### Register-DeployTarget

Parameters: Name :String, Function :String, ConfigKey :String, RequiredFields :String[]

### Get-DeployTarget

Parameters: Name :String

### Enter-DeployLock

Parameters: LockName :String, TimeoutMs :Int32, TimeoutSec :Int32

### Exit-DeployLock

Parameters: LockName :String

### Invoke-DeployTarget

Parameters: Name :String, State :PSObject, DryRun :SwitchParameter, ProjectDir :String, ProjectType :String, Detailed :SwitchParameter

### Get-DeployConfig

Parameters: State :PSObject, Target :String

### Assert-DeployPrerequisite

Parameters: State :PSObject, Tool :String, ToolLabel :String, Target :String, Config :Object, RequiredKeys :String[], WorkDir :String, WorkDirMissingMessage :String

### Assert-WebPublishOutput

Parameters: State :PSObject

### Invoke-DeployAzure

Parameters: State :PSObject, ProjectDir :String, ProjectType :String

### Invoke-DeployAws

Parameters: State :PSObject, ProjectDir :String, ProjectType :String

### Invoke-GpgSign

Parameters: State :PSObject, Path :String

### Invoke-DeployVercel

Parameters: State :PSObject, ProjectDir :String, ProjectType :String

### Invoke-DockerCiDeploy

Parameters: State :PSObject, ProjectDir :String

### Invoke-DeployGcp

Parameters: State :PSObject, ProjectDir :String, ProjectType :String

### Resolve-K8sDeploymentName

Parameters: ManifestPath :String

### Invoke-DeployK8s

Parameters: State :PSObject, ProjectDir :String, ProjectType :String

### Invoke-DeployAzureFunctions

Parameters: State :PSObject, ProjectDir :String, ProjectType :String

### Invoke-DeployAwsLambda

Parameters: State :PSObject, ProjectDir :String, ProjectType :String

### Invoke-AzurePipelineTrigger

Parameters: State :PSObject, ProjectDir :String, ProjectType :String

### Test-DeployTargets

Parameters: State :PSObject

### Get-DeployEnvironments

Parameters: State :PSObject

### Resolve-EnvironmentForBranch

Parameters: State :PSObject, Branch :String

### Add-DeployEnvironment

Parameters: State :PSObject, Name :String, Branch :String, RequiresApproval :SwitchParameter, Targets :String[], AutoDeploy :SwitchParameter

### Test-ApprovalRequired

Parameters: State :PSObject, EnvironmentName :String

### Publish-Environment

Parameters: State :PSObject, From :String, To :String

### Invoke-DeployWithRollback

Parameters: State :PSObject, TargetName :String, RollbackAction :ScriptBlock, RollbackContext :Hashtable

### Test-DeployHealth

Parameters: State :PSObject, Url :String, ExpectedStatus :Int32, Retries :Int32, DelayMs :Int32

### Invoke-DeployGroup

Parameters: State :PSObject

### Get-DeployPublishOutputDir

Parameters: State :PSObject


