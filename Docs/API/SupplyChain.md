# SupplyChain

20 function(s). Source: `Modules/SupplyChain.psm1`

### Get-SupplyChainProjectName

Parameters: State :PSObject, Default :String

### Get-SupplyChainSection

Parameters: State :PSObject, Section :String

### Get-SupplyChainReportDir

Parameters: State :PSObject

### Export-ComplianceReport

Parameters: State :PSObject, Summary :Hashtable, LicenseResult :Object[]

### Get-SupplyChainCommand

Parameters: Name :String

### Write-SupplyChainJson

Parameters: Path :String, Data :Object

### Get-DependencyInventory

Parameters: ProjectDir :String, ProjectFile :String, State :PSObject

### New-BuildSbom

Parameters: State :PSObject, ProjectDir :String, ProjectName :String, ProjectVersion :String, SbomPath :String

### Get-SupplyChainProvenanceValue

Parameters: State :PSObject, Path :String

### New-BuildProvenance

Parameters: State :PSObject, SubjectName :String, SubjectPath :String, ProvenancePath :String

### Invoke-SupplyChainTool

Parameters: Tool :String, Arguments :String[], WorkingDirectory :String, State :PSObject, TimeoutSec :Int32

### Invoke-ArtifactSign

Parameters: State :PSObject, ArtifactDir :String

### Invoke-ContainerScan

Parameters: State :PSObject, LocalDir :String

### Invoke-SbomPolicyGate

Parameters: State :PSObject, Sbom :Object

### Invoke-SupplyChainChecks

Parameters: State :PSObject, ProjectDir :String, PublishOutput :String

### Resolve-TransparencyLogPath

Parameters: State :PSObject

### Write-TransparencyLogEntry

Parameters: Statement :Object, State :PSObject

### Send-TransparencyEntryToRekor

Parameters: Entry :Object, State :PSObject

### Test-TransparencyLog

Parameters: State :PSObject, ExpectedTip :String

### Get-ArtifactDigest

Parameters: Path :String


