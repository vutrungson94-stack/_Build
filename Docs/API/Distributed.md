# Distributed

17 function(s). Source: `Modules/Distributed.psm1`

### Get-DistributedConfig

Parameters: State :PSObject

### Get-DistributedSshPort

Parameters: State :PSObject

### Invoke-RemoteCommand

Parameters: TargetHost :PSObject, Command :String, RepoRoot :String, ConnectTimeout :Int32, State :PSObject, StrictHostKeyChecking :String, ExecutionTimeout :Int32

### Test-RemoteHost

Parameters: TargetHost :PSObject, ConnectTimeout :Int32, State :PSObject, StrictHostKeyChecking :String

### Get-DistributedField

Parameters: Object :Object, Name :String, Default :Object

### Test-DistributedHostIdentity

Parameters: TargetHost :Object

### Resolve-DistributedIdentityPath

Parameters: Path :String

### ConvertTo-DistributedShellQuote

Parameters: Value :String

### ConvertTo-DistributedProcessArgument

Parameters: Value :String

### Invoke-DistributedSshProcess

Parameters: SshArguments :String[], TimeoutSec :Int32

### Test-RemoteHostCertificate

Parameters: TargetHost :PSObject, State :PSObject

### Test-HostCertGate

Parameters: TargetHost :PSObject, State :PSObject

### Get-AvailableHosts

Parameters: Config :PSObject, State :PSObject

### Resolve-HostAssignment

Parameters: Task :PSObject, Hosts :PSObject[], Strategy :String, RoundRobinIndex :PSReference

### Invoke-DistributedBuild

Parameters: Tasks :PSObject[], State :PSObject, Strategy :String, SkipConnectivityCheck :SwitchParameter, Simulation :SwitchParameter

### Resolve-DistributedReportRoot

Parameters: State :PSObject, Config :PSObject

### New-DistributedReport

Parameters: Results :PSObject[], State :PSObject, Config :PSObject


