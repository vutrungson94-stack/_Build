# Siem

16 function(s). Source: `Modules/Siem.psm1`

### Get-SiemValue

Parameters: Object :Object, Name :String, Default :Object

### Get-SiemConfig

Parameters: State :PSObject

### Get-SiemReportDir

Parameters: State :PSObject

### Get-SiemHash

Parameters: Entry :Hashtable

### Escape-SiemHeader

Parameters: Value :Object

### Escape-SiemExtension

Parameters: Value :Object

### Escape-SiemStructuredValue

Parameters: Value :Object

### ConvertTo-CefEvent

Parameters: Entry :Hashtable, Vendor :String, Product :String, Sequence :Int32, EventId :String

### ConvertTo-SyslogEvent

Parameters: Entry :Hashtable, HostName :String, Sequence :Int32, EventId :String

### Get-AuditEntries

Parameters: AuditLogPath :String

### Write-SiemFile

Parameters: OutputPath :String, Lines :String[]

### Send-SiemUdp

Parameters: Endpoint :String, Port :Int32, Lines :String[]

### Send-SiemHttp

Parameters: Endpoint :String, Lines :String[], TimeoutSec :Int32

### Get-SiemSafeOutputPath

Parameters: Directory :String, FileName :String

### Get-SiemRedactedEndpoint

Parameters: Endpoint :String

### Export-SiemEvents

Parameters: State :PSObject, AuditLogPath :String


