# SharedUtils

42 function(s). Source: `Modules/SharedUtils.psm1`

### Resolve-EnvPlaceholder

Parameters: Text :String

### Test-UnresolvedEnvPlaceholder

Parameters: Text :String

### Test-EnvToggle

Parameters: Name :String

### Get-InvokeCommandHint

Parameters: Arguments :String, ScriptRoot :String, FromDirectory :String

### Get-EnvMode

Parameters: Name :String

### Read-DotEnvLines

Parameters: Path :String

### Read-DotEnvFile

Parameters: Path :String

### Import-DotEnvFile

Parameters: Path :String, Override :SwitchParameter

### Remove-DotEnvFile

Parameters: Path :String

### Invoke-SafeRemove

Parameters: Path :String, AllowedRoots :String[], Force :SwitchParameter, Recurse :SwitchParameter

### Get-BuildTenantId

Parameters: State :PSObject

### Get-BuildCorrelationId

Parameters: State :PSObject

### Get-BuildIdentity

Parameters: State :PSObject

### Get-AuditLogPath

Parameters: State :PSObject, DefaultFileName :String

### Get-SecretDetectionPatterns

Parameters: State :PSObject

### Get-SecretRedactPatterns

Parameters: State :PSObject

### Get-SecretPatternField

Parameters: Object :Object, Name :String[]

### Get-BuildSecretRedactPatterns

Parameters: State :PSObject, Patterns :Array

### Protect-BuildSecretText

Parameters: Text :Object, State :PSObject, Patterns :Array, RedactUrls :SwitchParameter, Marker :String, UrlRedactor :ScriptBlock

### Write-BuildAuditLog

Parameters: LogPath :String, Entry :Hashtable, MaxSizeMB :Int32

### Get-BuildListConstant

Parameters: Key :String, Fallback :String[]

### Get-SyntaxCheckExcludeDirs

### Get-SyntaxCheckExcludeFiles

### Get-BoundedProjectFiles

Parameters: Root :String, Filters :String[], Depth :Int32, ExcludeDirs :String[], ExcludeFiles :String[], File :SwitchParameter

### Invoke-SyntaxCheck

Parameters: Root :String, IncludeExtensions :String[], ExcludeDirs :String[], ExcludeFiles :String[], Recurse :SwitchParameter

### Invoke-UniversalSyntaxCheck

Parameters: Root :String, Recurse :SwitchParameter

### Write-BuildJsonFile

Parameters: Path :String, Data :Object, Depth :Int32, Atomic :SwitchParameter

### Resolve-PublishOutputDir

Parameters: State :PSObject

### Get-ReportDirectory

Parameters: State :PSObject

### Get-ProjectShortName

Parameters: State :PSObject, Default :String

### Get-BuildConstant

Parameters: Key :String, Fallback :Object, State :PSObject

### Get-ConfigSection

Parameters: State :PSObject, Path :String

### Test-ToolAvailable

Parameters: ToolName :String, Aliases :String[]

### Resolve-PowerShellHost

### Remove-JsonComments

Parameters: JsonWithComments :String

### New-OperationResult

Parameters: Status :String, Operation :String, ReasonCode :String, Message :String, ExitCode :Int32, DurationMs :Double, Details :Object

### ConvertTo-OperationResult

Parameters: Value :Object, Operation :String, ReasonCode :String, Message :String, ExitCode :Int32, DurationMs :Double, Details :Object

### Test-RequiredResult

Parameters: Result :Object, Operation :String, Throw :SwitchParameter

### Test-BuildGateResult

Parameters: Result :Object, Operation :String, StageLabel :String

### Assert-RequiredResult

Parameters: Result :Object, Operation :String

### Get-ExecutableExtension

Parameters: State :PSObject, Fallback :String

### Get-FileHashSHA256

Parameters: Path :String, Recursive :SwitchParameter, Aggregate :SwitchParameter


