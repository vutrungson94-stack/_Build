# ProcessMetrics

19 function(s). Source: `Modules/ProcessMetrics.psm1`

### Get-ProcessCodeFile

Parameters: ToolRoot :String

### Get-ProcessCodeText

Parameters: Files :Object[]

### New-ProcessAdoptionClass

Parameters: Class :String, Description :String, Adopted :Int32, Total :Int32, Metric :String, Offenders :String[]

### Get-BuildProcessMetrics

Parameters: ToolRoot :String

### Get-BuildProcessTrendPath

Parameters: ToolRoot :String

### Write-BuildProcessTrend

Parameters: Metrics :PSObject, ToolRoot :String, RunId :String, Channel :String, ProjectType :String

### Get-BuildProcessTrend

Parameters: ToolRoot :String, Last :Int32

### Compare-BuildProcessTrend

Parameters: Metrics :PSObject, ToolRoot :String

### Get-BuildProcessSparkline

Parameters: Metrics :PSObject, ToolRoot :String, Width :Int32, Ascii :SwitchParameter

### Get-ProcessControlLimits

Parameters: Values :Double[], Sigma :Double

### Test-ProcessInControl

Parameters: Value :Double, Limits :Object

### Get-FleetSLOSummary

Parameters: Records :Object[], Sigma :Double

### Publish-FleetSLOSummary

Parameters: Records :Object[], State :PSObject, FileName :String

### Invoke-FleetRollup

Parameters: FleetDir :String, OutputPath :String

### Get-FleetBillingSummary

Parameters: Tenants :Object[], Rates :Hashtable

### Find-RatchetCandidates

Parameters: Floor :Object, CurrentMetrics :PSObject, History :Object[], MinSustained :Int32

### Compare-BuildProcessControl

Parameters: Metrics :PSObject, ToolRoot :String, Window :Int32, MinSamples :Int32, Sigma :Double

### Test-BuildQpmLedger

Parameters: ToolRoot :String, Path :String

### Get-BuildQpmMeasures

Parameters: ToolRoot :String, WindowSamples :Int32, MinSamples :Int32


