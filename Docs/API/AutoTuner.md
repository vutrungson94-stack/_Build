# AutoTuner

26 function(s). Source: `Modules/AutoTuner.psm1`

### Get-AutoTuneValue

Parameters: Object :Object, Name :String, Default :Object

### Get-AutoTuneRoot

Parameters: State :PSObject

### Resolve-AutoTuneHistoryPath

Parameters: State :PSObject, Path :String

### Get-AutoTuneConfig

Parameters: State :PSObject

### New-AutoTuneEWMA

Parameters: Alpha :Double, InitialValue :Double

### AutoTuneEWMAUpdate

Parameters: Tracker :Hashtable, Value :Double

### New-AutoTuneRegressor

### AutoTuneRegressorUpdate

Parameters: Reg :Hashtable, x :Double, y :Double

### AutoTuneRegressorResult

Parameters: Reg :Hashtable

### AutoTuneStatsAddSample

Parameters: Stats :Hashtable, DurationSec :Double, Success :Boolean, ParallelJobs :Int32, CacheHit :Boolean, CpuCount :Int32, MemoryGB :Double

### AutoTuneStatsFinalize

Parameters: Stats :Hashtable

### Enter-AutoTuneHistoryLock

Parameters: Path :String

### Read-AutoTuneHistoryLines

Parameters: Path :String

### Write-AutoTuneHistoryLines

Parameters: Path :String, Lines :String[]

### ConvertTo-AutoTuneRecord

Parameters: Sample :Hashtable

### Write-AutoTuneSample

Parameters: Sample :Hashtable, State :PSObject

### Get-AutoTuneSamples

Parameters: State :PSObject, Path :String, Limit :Int32

### Get-AutoTuneHostCapacity

Parameters: State :PSObject

### Get-AutoTuneMLRecommendations

Parameters: State :PSObject

### Get-AutoTunePathState

Parameters: Root :Object, Path :String

### Set-AutoTunePathValue

Parameters: Root :Object, Path :String, Value :Object

### Remove-AutoTunePathValue

Parameters: Root :Object, Path :String

### Test-AutoTuneValue

Parameters: Key :String, Value :Object, State :PSObject

### Invoke-AutoTuneApply

Parameters: State :PSObject

### Undo-AutoTuneApply

Parameters: State :PSObject

### Get-AutoTuneRecommendations

Parameters: State :PSObject


