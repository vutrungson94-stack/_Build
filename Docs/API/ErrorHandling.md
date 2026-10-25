# ErrorHandling

23 function(s). Source: `Modules/ErrorHandling.psm1`

### Get-ErrorCategoryInfo

Parameters: Category :String

### Get-ErrorCategory

Parameters: ErrorRecord :Object

### New-BuildError

Parameters: Message :String, Category :String, Code :String, Suggestion :String, DocsLink :String, Context :Hashtable, RelatedFiles :String[], OriginalError :Object, State :PSObject

### Invoke-WithRetry

Parameters: Action :ScriptBlock, OperationName :String, MaxRetries :Int32, BaseDelayMs :Int32, MaxDelayMs :Int32, TotalTimeoutSec :Int32, State :PSObject

### Initialize-CircuitBreaker

Parameters: State :PSObject

### Get-CircuitBreakerState

Parameters: State :PSObject

### Invoke-WithCircuitBreaker

Parameters: Action :ScriptBlock, OperationName :String, State :PSObject

### Reset-CircuitBreaker

### Get-CircuitBreakerStateFilePath

Parameters: State :PSObject

### Save-CircuitBreakerState

Parameters: State :PSObject, Path :String

### Restore-CircuitBreakerState

Parameters: State :PSObject, Path :String

### Save-CircuitBreakerStateIfEnabled

Parameters: State :PSObject

### Register-RollbackAction

Parameters: Name :String, Action :ScriptBlock, Context :Hashtable

### Invoke-Rollback

Parameters: Reason :String, State :PSObject

### Clear-RollbackStack

### Get-StateFilePath

Parameters: State :PSObject

### Save-BuildState

Parameters: State :PSObject, Path :String

### Restore-BuildState

Parameters: Path :String, State :PSObject

### Get-ErrorSummary

### Show-ErrorReport

Parameters: State :PSObject, AsJson :SwitchParameter

### Write-ErrorStructured

Parameters: Message :String, Category :String, Suggestion :String, Code :String, State :PSObject

### Reset-ErrorLog

### Get-ErrorHandlingService


