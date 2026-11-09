# Report

18 function(s). Source: `Modules/Report.psm1`

### Get-ReportConfigValue

Parameters: State :PSObject, Key :String, Default :Object

### Get-TelemetryConfigValue

Parameters: State :PSObject, Key :String, Default :Object

### Write-ReportLog

Parameters: Message :String, Level :String, State :PSObject

### Initialize-ReportDir

Parameters: State :PSObject

### Reset-ReportCache

### Write-BuildMetric

Parameters: State :PSObject, Status :String, Duration :Double, ProjectName :String, Configuration :String, TargetFramework :String, OutputType :String, Stage :String, Extra :Hashtable

### Save-BuildReport

Parameters: State :PSObject, Metric :Hashtable

### Write-TelemetryEntry

Parameters: State :PSObject, Metric :Hashtable

### Get-ReportData

Parameters: State :PSObject, LastN :Int32

### Show-BuildReport

Parameters: State :PSObject, LastN :Int32

### Get-BuildTrend

Parameters: State :PSObject, LastN :Int32

### Get-ReportFieldValue

Parameters: Object :Object, Name :String, Default :Object

### Export-JUnitReport

Parameters: Results :Object[], OutputPath :String, SuiteName :String

### Export-SarifReport

Parameters: Findings :Object[], OutputPath :String, ToolName :String

### Get-BuildTraceContext

Parameters: State :PSObject

### Add-BuildTestResult

Parameters: State :PSObject, Result :Object, Suite :String

### Publish-BuildJUnitArtifact

Parameters: State :PSObject, SuiteName :String, OutputPath :String

### Publish-BuildSarifArtifact

Parameters: State :PSObject, Findings :Object[], ToolName :String, OutputPath :String


