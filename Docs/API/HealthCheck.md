# HealthCheck

27 function(s). Source: `Modules/HealthCheck.psm1`

### Get-HealthConfigValue

Parameters: State :PSObject, Key :String, DefaultValue :Object

### Get-HealthRoot

Parameters: State :PSObject

### Get-HealthOsName

Parameters: State :PSObject

### Get-HealthStatusIcon

Parameters: Status :String

### Get-HealthStatusColor

Parameters: Status :String

### New-HealthResult

Parameters: Name :String, Status :String, Message :String, Suggestion :String, Details :String, CheckedPorts :Int32[], InUsePorts :Int32[]

### Test-DotnetSdk

Parameters: State :PSObject

### Test-JavaJdk

Parameters: State :PSObject

### Test-AndroidSdk

Parameters: State :PSObject

### Get-HealthFreeBytes

Parameters: Path :String

### Test-DiskSpace

Parameters: State :PSObject, MinMB :Int32

### Get-HealthEndpointValue

Parameters: Endpoint :Object, Name :String, Default :Object

### Get-HealthRedactedUrl

Parameters: Url :String

### Protect-HealthText

Parameters: Text :Object, State :PSObject

### Test-NetworkConnectivity

Parameters: State :PSObject

### Test-RequiredTools

Parameters: State :PSObject

### Get-HealthConfiguredPorts

Parameters: State :PSObject

### Test-PortAvailability

Parameters: State :PSObject, Ports :Int32[]

### Test-ProjectFiles

Parameters: State :PSObject

### Test-GitStatus

Parameters: State :PSObject

### Get-HealthLogLevel

Parameters: State :Object

### Invoke-HealthCheck

Parameters: State :PSObject, IncludeNetwork :SwitchParameter, Quick :SwitchParameter

### Show-HealthReport

Parameters: State :PSObject, Results :PSObject[]

### Get-HealthBuildRoots

Parameters: State :PSObject

### Test-HealthPathUnderRoot

Parameters: Path :String, Root :String

### Invoke-AutoFix

Parameters: State :PSObject, Results :Array

### Invoke-Doctor

Parameters: State :PSObject, Quick :SwitchParameter, AsJson :SwitchParameter, AutoFix :SwitchParameter


