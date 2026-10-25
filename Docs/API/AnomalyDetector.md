# AnomalyDetector

24 function(s). Source: `Modules/AnomalyDetector.psm1`

### Get-AnomalyValue

Parameters: Object :Object, Name :String, Default :Object

### Get-AnomalyRoot

Parameters: State :PSObject

### Resolve-AnomalyPath

Parameters: State :PSObject, Path :String

### Get-AnomalyConfig

Parameters: State :PSObject

### Enter-AnomalyHistoryLock

Parameters: Path :String

### Read-AnomalyLines

Parameters: Path :String

### Write-AnomalyLines

Parameters: Path :String, Lines :String[]

### ConvertTo-AnomalySampleRecord

Parameters: Sample :Hashtable

### Write-AnomalySample

Parameters: Sample :Hashtable, State :PSObject

### Get-AnomalySamples

Parameters: State :PSObject

### Get-rollingStats

Parameters: Values :Double[], Window :Int32

### Get-DurationAnomaly

Parameters: CurrentDurationSec :Double, HistoryDurations :Double[], ZScoreThreshold :Double, EwmaAlpha :Double, WindowSize :Int32, CriticalZScore :Double, HighZScore :Double, EwmaMultiplier :Double

### Get-FailureRateAnomaly

Parameters: CurrentFailureRate :Double, HistoryFailureRates :Double[], Threshold :Double, WindowSize :Int32, HighZScore :Double, CriticalZScore :Double, HighZScore2 :Double

### Get-AnomalyReport

Parameters: State :PSObject

### Write-AnomalyHistory

Parameters: Report :PSObject, State :PSObject

### Get-AnomalyTenantKey

Parameters: State :PSObject

### Get-AnomalyCircuitBreakerState

Parameters: State :PSObject

### Set-AnomalyCircuitBreakerState

Parameters: State :PSObject, FailureCount :Int32, MaxFailures :Int32, CoolDownSec :Int32

### Clear-AnomalyCircuitBreakerState

Parameters: State :PSObject

### Test-AnomalyCircuitBreaker

Parameters: State :PSObject

### Invoke-AnomalyRollback

Parameters: Report :PSObject, State :PSObject

### Invoke-AnomalyPrevention

Parameters: Report :PSObject, State :PSObject

### Protect-AnomalyText

Parameters: Text :Object

### Send-AnomalyAlert

Parameters: Report :PSObject, State :PSObject


