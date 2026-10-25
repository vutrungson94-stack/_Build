# ClusterOrchestrator

26 function(s). Source: `Modules/ClusterOrchestrator.psm1`

### Get-ClusterDefault

Parameters: Key :String, Fallback :Object

### Test-ClusterNamespace

Parameters: Namespace :String

### Test-ClusterContext

Parameters: Context :String

### Resolve-ClusterKubeconfig

Parameters: Path :String, State :PSObject

### Test-ClusterEndpoint

Parameters: Endpoint :String

### Invoke-ClusterKubectl

Parameters: Cluster :Hashtable, Arguments :String[], TimeoutSec :Int32, State :PSObject

### Test-ClusterManifestValue

Parameters: Value :String, MaxLength :Int32

### Merge-ClusterConfig

Parameters: Override :Object

### Initialize-ClusterOrchestrator

Parameters: State :PSObject

### Register-Cluster

Parameters: Name :String, Endpoint :String, Kubeconfig :String, Context :String, Region :String, Zone :String, Capacity :Hashtable, Labels :String[], Taints :String[], MaxConcurrent :Int32, State :PSObject

### Get-Cluster

Parameters: Name :String, State :PSObject

### Get-AllClusters

Parameters: State :PSObject

### Get-HealthyClusters

Parameters: State :PSObject

### Update-ClusterHeartbeat

Parameters: ClusterName :String, Status :String, ActiveBuilds :Int32, State :PSObject

### Test-ClusterHealth

Parameters: Cluster :Hashtable, State :PSObject, TimeoutSec :Int32

### Start-ClusterHealthMonitor

Parameters: State :PSObject

### Select-ClusterForBuild

Parameters: State :PSObject, BuildRequirements :Hashtable, Strategy :String

### Submit-ClusterBuild

Parameters: State :PSObject, BuildSpec :Hashtable, Requirements :Hashtable

### Get-ClusterBuildStatus

Parameters: BuildId :String, ClusterName :String, Namespace :String, State :PSObject

### Stop-ClusterBuild

Parameters: BuildId :String, ClusterName :String, Namespace :String, State :PSObject

### Cancel-ClusterBuild

Parameters: BuildId :String, ClusterName :String, Namespace :String, State :PSObject

### Wait-ClusterBuild

Parameters: BuildId :String, ClusterName :String, Namespace :String, TimeoutSec :Int32, State :PSObject, CancellationToken :CancellationToken

### Start-CoordinatorLeaderElection

Parameters: State :PSObject

### Stop-CoordinatorLeaderElection

Parameters: State :PSObject

### Get-GBuildCRDs

### Install-GBuildOperator

Parameters: Namespace :String, Version :String, State :PSObject


