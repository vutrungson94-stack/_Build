# Standalone

23 function(s). Source: `Modules/Standalone.psm1`

### Get-StandaloneConfig

Parameters: State :PSObject

### Get-StandaloneBundleVersion

Parameters: State :PSObject

### Sign-StandaloneBundle

Parameters: BundlePath :String, State :PSObject, Detailed :SwitchParameter

### Generate-StandaloneBundleSupplyChain

Parameters: BundlePath :String, State :PSObject, Detailed :SwitchParameter

### Get-StandaloneOutputPath

Parameters: State :PSObject

### Expand-StandaloneFileList

Parameters: FileList :Object[]

### ConvertTo-StandaloneRelPath

Parameters: Path :String

### Test-StandaloneExcludedPath

Parameters: RelPath :String

### Get-StandaloneSecretPatterns

### Assert-StandaloneConfigSafe

Parameters: Path :String

### Get-StandaloneSha256

Parameters: Bytes :Byte[]

### Get-StandaloneObjectProperty

Parameters: Object :Object, Name :String

### Assert-StandaloneResourceSet

Parameters: FileList :Object[]

### Get-EmbeddedFiles

Parameters: State :PSObject

### New-StandaloneManifest

Parameters: FileList :Object[], Version :String

### Assert-StandaloneManifest

Parameters: Manifest :Object, RequireRuntimeResources :SwitchParameter

### ConvertTo-StandaloneJsonString

Parameters: Text :String

### ConvertTo-StandaloneManifestJson

Parameters: Manifest :Object

### ConvertFrom-StandalonePayload

Parameters: PayloadLines :String[]

### Assert-StandalonePayloadMatchesManifest

Parameters: PayloadLines :String[], Manifest :Object

### ConvertTo-Base64Payload

Parameters: FileList :Object[], Strict :SwitchParameter, Manifest :Object, Version :String

### New-StandaloneBundleScript

Parameters: State :PSObject, OutputPath :String, PayloadLines :String[], Version :String, Manifest :Object

### New-StandaloneBundle

Parameters: State :PSObject, OutputPath :String


