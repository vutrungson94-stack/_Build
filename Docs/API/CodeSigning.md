# CodeSigning

15 function(s). Source: `Modules/CodeSigning.psm1`

### Get-CodeSigningProfilePath

### Get-CodeSigningProfile

### Find-CodeSigningSignTool

### Find-ArtifactSigningDlib

### Find-ArtifactSigningMetadata

Parameters: ExplicitPath :String, Endpoint :String, Account :String, ProfileName :String

### Resolve-ArtifactSigningCommand

Parameters: SignToolPath :String, DlibPath :String, MetadataPath :String, Endpoint :String, Account :String, ProfileName :String

### Ensure-SelfSignedCodeSigningCertificate

Parameters: Subject :String, Thumbprint :String, Years :Int32

### Get-CodeSigningConfig

Parameters: State :Object

### Get-CodeSigningArtifact

Parameters: Path :String, Pattern :String[], Recursive :Boolean

### Test-CodeSigningToolAvailable

Parameters: Tool :String, ExternalCommand :String

### Invoke-SignToolCodeSigning

Parameters: Path :String, CertificatePath :String, Password :String, TimestampUrl :String

### Invoke-ExternalCodeSigning

Parameters: Path :String, Command :String, Arguments :String

### Invoke-PowerShellCodeSigning

Parameters: Path :String, CertificatePath :String, Password :String, CertificateThumbprint :String, TimestampUrl :String

### Test-CodeSignatureStatus

Parameters: Path :String

### Invoke-CodeSigning

Parameters: State :Object, InputPath :String


