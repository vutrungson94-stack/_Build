# Security

27 function(s). Source: `Modules/Security.psm1`

### Get-SecretPatterns

Parameters: State :PSObject

### Get-SecurityConfigValue

Parameters: State :PSObject, Path :String, Default :Object

### Invoke-BuildSecretProtect

Parameters: Text :String, State :PSObject, Patterns :Array, RedactUrls :SwitchParameter, UrlRedactor :ScriptBlock

### Protect-SecurityText

Parameters: Text :String, State :PSObject

### New-SecurityScannerError

Parameters: Tool :String, Operation :String, ExitCode :Int32

### Get-SecurityToolPolicy

Parameters: State :PSObject

### ConvertTo-CanonicalLicenseKey

Parameters: Value :String

### Test-SecurityInventoryFile

Parameters: FileName :String, Extension :String

### Write-AuditLog

Parameters: Action :String, Outcome :String, State :PSObject, Detail :String

### Find-SecretsInFile

Parameters: FilePath :String, ContextLines :Int32, State :PSObject

### Get-TestDirectories

Parameters: SearchRoot :String

### Get-SecurityExcludeDirPattern

### Invoke-SecretScan

Parameters: State :PSObject, SearchRoot :String, ExcludeDirs :String[]

### Invoke-SecurityToolCapture

Parameters: Tool :String, Arguments :String[], WorkingDirectory :String, State :PSObject

### Get-SecurityManifestFiles

Parameters: Root :String, Names :String[]

### ConvertTo-SecurityJson

Parameters: Text :String

### Get-SecurityToolFailure

Parameters: Tool :String, Operation :String, ExitCode :Int32, State :PSObject

### Get-SecurityScanDepth

Parameters: State :PSObject

### Get-SecurityScanFiles

Parameters: Root :String, Depth :Int32

### Test-VulnerablePackages

Parameters: State :PSObject

### Test-NpmVulnerabilities

Parameters: State :PSObject

### Test-GoVulnerabilities

Parameters: State :PSObject

### Test-PythonVulnerabilities

Parameters: State :PSObject

### Test-RustVulnerabilities

Parameters: State :PSObject

### Test-LicenseCompliance

Parameters: State :PSObject

### Invoke-LicenseCompliance

Parameters: State :PSObject

### Invoke-SecurityScan

Parameters: State :PSObject, SkipSecrets :SwitchParameter, SkipVulnerable :SwitchParameter


