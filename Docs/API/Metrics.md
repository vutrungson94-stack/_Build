# Metrics

48 function(s). Source: `Modules/Metrics.psm1`

### Update-MetricsText

### MetricRegistry

### GetKey

### Register

### Clear

### GetAggregatedSeries

### FormatLabels

### FormatValue

### ToPrometheus

### Get-MetricConfigValue

Parameters: State :Object, Path :String, Default :Object

### Get-MetricSectionValue

Parameters: Section :Object, Key :String, Default :Object

### Protect-MetricText

Parameters: Text :Object

### Get-TelemetryConfig

Parameters: State :PSObject

### New-MetricCounter

Parameters: Name :String, Help :String, Labels :Hashtable

### New-MetricHistogram

Parameters: Name :String, Help :String, Value :Double, Labels :Hashtable

### Add-Metric

Parameters: Metric :PSObject

### Get-MetricsAsPrometheus

### Get-MetricProperty

Parameters: Object :Object, Names :String[], Default :Object

### ConvertTo-MetricBool

Parameters: Value :Object, Default :Boolean

### ConvertTo-MetricTimestamp

Parameters: Value :Object, Fallback :DateTime

### Get-MetricReportDirectory

Parameters: State :PSObject

### Get-MetricReportFiles

Parameters: Directory :String, Limit :Int32

### Get-MetricStatusSuccess

Parameters: Data :Object

### Test-MetricDeploymentEvent

Parameters: Data :Object

### Get-MetricLeadTimeSeconds

Parameters: Data :Object, Fallback :DateTime

### Get-MetricMedian

Parameters: Values :Object[]

### Get-MetricSummary

Parameters: Values :Object[]

### Get-DoraMetrics

Parameters: State :PSObject, ReportDir :String

### Get-SloSamples

Parameters: State :PSObject

### Get-BurnRateAdvisory

Parameters: Samples :Object[], Target :Double, MaxBurn :Double

### Get-SloStatus

Parameters: State :PSObject

### Get-MetricsBaselinePath

Parameters: State :PSObject, Path :String

### Get-MetricSnapshot

### Compare-MetricsBaseline

Parameters: State :PSObject, Path :String, Persist :SwitchParameter

### Update-MetricsBaseline

Parameters: State :PSObject, Path :String

### Start-MetricsEndpoint

Parameters: Port :Int32, State :PSObject

### Stop-MetricsEndpoint

### ConvertTo-OtlpAttributeArray

Parameters: Labels :Hashtable

### ConvertTo-OtlpTimeNano

Parameters: Utc :DateTime

### New-OtlpMetricsBody

Parameters: State :PSObject

### Send-OtlpPost

Parameters: Url :String, Bytes :Byte[], State :PSObject, TimeoutSec :Int32

### Send-OtelTraces

Parameters: State :PSObject, OtelEndpoint :String, TraceData :Hashtable, TimeoutSec :Int32

### Send-OtelMetrics

Parameters: State :PSObject, OtelEndpoint :String, TimeoutSec :Int32

### Submit-BuildMetric

Parameters: State :PSObject, Step :String, DurationMs :Double, Success :Boolean, ProjectName :String, Configuration :String, TargetFramework :String, OutputType :String, Commit :String, Stage :String, Name :String, Value :Double, Labels :Hashtable

### Submit-CacheMetric

Parameters: Result :String, Project :String, CacheKey :String, TenantId :String

### Clear-Metrics

### Get-MetricRegistry

### Get-MetricRawSamples


