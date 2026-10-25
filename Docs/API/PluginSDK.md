# PluginSDK

13 function(s). Source: `Modules/PluginSDK.psm1`

### Get-PluginSdkApiVersion

### Get-GBuildToolVersion

### ConvertTo-PluginVersion

Parameters: Version :String

### Compare-PluginVersion

Parameters: Left :String, Right :String

### Test-PluginVersionConstraint

Parameters: Version :String, Constraint :String

### Read-PluginManifestFile

Parameters: Path :String

### New-PluginManifestTemplate

Parameters: Name :String, SupportedLanguages :String[]

### Get-PluginSdkConfig

Parameters: State :PSObject

### Get-PluginManifestPath

Parameters: PluginPath :String

### Test-PluginManifest

Parameters: Manifest :Object

### Get-PluginManifest

Parameters: PluginPath :String, PluginInfo :Object, State :PSObject

### Test-PluginCompatibility

Parameters: Manifest :Object, State :PSObject, KnownManifests :Object[]

### Resolve-PluginDependencies

Parameters: Manifests :Array


