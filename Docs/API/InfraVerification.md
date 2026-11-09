# InfraVerification

14 function(s). Source: `Modules/InfraVerification.psm1`

### Get-InfraTimeout

Parameters: Value :Int32, Fallback :Int32

### Protect-InfraText

Parameters: Text :Object, State :PSObject

### Get-InfraRedactedUrl

Parameters: Url :String

### ConvertTo-InfraArgument

Parameters: Value :String

### Invoke-InfraProcess

Parameters: FilePath :String, ArgumentList :String[], TimeoutSec :Int32, WorkingDirectory :String

### Get-VerificationConfig

Parameters: State :PSObject

### New-VerificationCheck

Parameters: Name :String, Status :String, Detail :String, DurationSec :Double, Target :String, State :PSObject

### Invoke-VerifySdk

Parameters: State :PSObject, RequestTimeout :Int32

### Invoke-VerifySshHost

Parameters: HostObj :PSObject, State :PSObject, ConnectTimeout :Int32, RequestTimeout :Int32

### Invoke-VerifyRemoteCache

Parameters: State :PSObject, RequestTimeout :Int32

### Invoke-VerifyOtel

Parameters: State :PSObject, RequestTimeout :Int32, SendTest :Boolean

### Invoke-VerifyWebhook

Parameters: State :PSObject, SendTest :Boolean, RequestTimeout :Int32

### Invoke-InfraRemediate

Parameters: State :PSObject, Checks :Object[], Config :PSObject

### Invoke-InfraVerification

Parameters: State :PSObject, Force :SwitchParameter, Remediate :SwitchParameter, AutoRemediate :SwitchParameter


