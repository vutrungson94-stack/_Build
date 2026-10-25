# Environment

22 function(s). Source: `Modules/Environment.psm1`

### Get-OSPlatform

### Register-TempFile

Parameters: State :PSObject, Path :String

### Get-RelativeDepth

Parameters: Root :String, Child :String

### Invoke-CompatibleChildItem

Parameters: Path :String, Filter :String, File :SwitchParameter, Directory :SwitchParameter, Recurse :SwitchParameter, Depth :Int32, State :PSObject

### Get-SafePath

Parameters: Path :String

### Read-JsonSafe

Parameters: FilePath :String

### Save-JsonSafe

Parameters: Data :Object, FilePath :String

### Open-Target

Parameters: Target :String, State :PSObject

### Get-AvailableDrives

### Get-RuntimeIdentifier

### Test-PortListening

Parameters: Port :Int32

### Test-PortBindable

Parameters: Port :Int32, IP :String

### Wait-PortRelease

Parameters: Port :Int32, State :PSObject, Mode :String, Attempts :Int32, DelayMs :Int32

### Get-PortOwnerProcess

Parameters: Port :Int32

### Get-PsBinary

### Get-UnixProcessCommandLine

Parameters: ProcessId :Int32

### Get-UnixProcessTreeMap

### Get-UnixProcessDescendants

Parameters: Tree :Object, RootId :Int32

### Get-ProcessCommandLine

Parameters: ProcessId :Int32

### Initialize-EnvironmentModel

Parameters: State :PSObject

### Get-EnvironmentModel

Parameters: State :PSObject

### Test-HttpEndpoint

Parameters: Url :String, TimeoutMs :Int32, State :PSObject


