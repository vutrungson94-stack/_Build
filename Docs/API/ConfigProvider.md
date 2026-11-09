# ConfigProvider

27 function(s). Source: `Modules/ConfigProvider.psm1`

### Test-ConfigProperty

Parameters: Object :Object, Name :String

### Get-ConfigProperty

Parameters: Object :Object, Name :String

### Set-ConfigProperty

Parameters: Object :Object, Name :String, Value :Object

### Remove-ConfigProperty

Parameters: Object :Object, Name :String

### Normalize-BuildAliases

Parameters: BuildSection :Object, RemoveLegacy :SwitchParameter

### Update-ConfigAliases

Parameters: Config :Object, RemoveLegacy :SwitchParameter

### Resolve-ConfigAliasPath

Parameters: Path :String

### Get-ConfigProjectMarkers

Parameters: State :PSObject

### Resolve-ConfigEnvironmentValue

Parameters: Value :Object, State :PSObject

### Enter-BuildConfigEnvironment

Parameters: State :PSObject

### Exit-BuildConfigEnvironment

Parameters: Scope :Object

### Find-ConfigNode

Parameters: Root :Object, Path :String

### Get-ConfigValue

Parameters: Path :String, State :PSObject, Default :Object, Type :String, ResolveEnv :SwitchParameter

### Merge-ConfigSources

Parameters: BasePath :String, OverridePaths :String[], State :PSObject

### Get-ConfigEnvironmentFile

Parameters: BasePath :String, OverridePaths :String[], ProjectRoot :String, ScriptRoot :String, State :PSObject

### Read-ConfigEnvironmentFile

Parameters: Path :String

### Set-ConfigEnvironmentOverlay

Parameters: State :PSObject, Path :String

### Initialize-BuildConfigState

Parameters: State :PSObject

### Merge-ConfigObject

Parameters: Base :Object, Override :Object

### ConvertTo-ConfigObject

Parameters: InputObject :Object

### Merge-ConfigTenantOverride

Parameters: Config :Object, State :PSObject

### New-ConfigStub

### Get-SectionValue

Parameters: Section :Object, Key :String, Default :Object

### ConvertTo-TargetType

Parameters: Value :Object, Type :String

### Test-BuildConfigSchemaObject

Parameters: Instance :Object, Schema :Object, Path :String, MaxErrors :Int32

### Test-BuildConfigSchema

Parameters: Instance :Object, Schema :Object, Strict :SwitchParameter

### Test-ConfigSchema

Parameters: State :PSObject, Strict :SwitchParameter


