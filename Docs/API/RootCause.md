# RootCause

16 function(s). Source: `Modules/RootCause.psm1`

### Get-DiagnosticRoot

Parameters: State :PSObject

### Resolve-DiagnosticPath

Parameters: State :PSObject, Path :String

### Resolve-RootCausePath

Parameters: State :PSObject, Path :String

### Get-RootCauseConfig

Parameters: State :PSObject

### Get-RootCauseClassifiers

Parameters: State :PSObject

### Protect-RootCauseText

Parameters: Text :Object, State :PSObject

### Get-RootCauseAnalysis

Parameters: ErrorRecord :ErrorRecord, State :PSObject

### Write-RootCauseHistory

Parameters: Analysis :Hashtable, State :PSObject

### New-CARRecord

Parameters: Category :String, Confidence :Double, Severity :String, Suggestion :String, State :PSObject

### Resolve-CARPath

Parameters: State :PSObject

### Write-CARRecord

Parameters: Record :PSObject, State :PSObject

### Confirm-CARClosure

Parameters: Id :String, Evidence :String, State :PSObject

### Get-RootCauseSummary

Parameters: State :PSObject

### Get-TenantUsageSummary

Parameters: State :PSObject

### Export-CARAuditPack

Parameters: State :PSObject, OutputPath :String

### Test-CARAuditPack

Parameters: PackPath :String


