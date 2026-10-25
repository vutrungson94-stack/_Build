# Alerting

19 function(s). Source: `Modules/Alerting.psm1`

### Get-AlertObjectValue

Parameters: Object :Object, Name :String, Default :Object

### Get-AlertTenantId

Parameters: State :Object, Data :Object

### Get-AlertCorrelationId

Parameters: State :Object, Data :Object

### Get-AlertSensitiveKey

Parameters: Name :String

### Get-AlertRedactedUrl

Parameters: Url :String

### Invoke-BuildSecretProtect

Parameters: Text :String, State :PSObject, Patterns :Array, RedactUrls :SwitchParameter, UrlRedactor :ScriptBlock

### Protect-AlertText

Parameters: Text :Object, State :PSObject

### ConvertTo-AlertSafeValue

Parameters: Value :Object, Name :String, State :PSObject

### Get-AlertIdempotencyKey

Parameters: Label :String, Payload :Object, State :PSObject, TenantId :String, CorrelationId :String

### Get-AlertTimeout

Parameters: Config :Object, TimeoutSec :Int32, State :PSObject

### Get-AlertRetryValues

Parameters: Config :Object, MaxAttempts :Int32, RetryDelayMs :Int32, State :PSObject

### Invoke-WebhookPost

Parameters: Url :String, Payload :Object, Label :String, Headers :Hashtable, State :PSObject, TimeoutSec :Int32, MaxAttempts :Int32, RetryDelayMs :Int32, IdempotencyKey :String, Config :Object

### New-WebhookToken

Parameters: ByteLength :Int32

### Test-WebhookTokenExpired

Parameters: CreatedAt :DateTime, IntervalHours :Double

### Update-WebhookToken

Parameters: State :PSObject, IntervalHours :Double

### Send-SlackNotification

Parameters: WebhookUrl :String, Message :String, Channel :String, Username :String, Emoji :String, State :PSObject

### Send-TeamsNotification

Parameters: WebhookUrl :String, Title :String, Message :String, Color :String, State :PSObject

### Send-DiscordNotification

Parameters: WebhookUrl :String, Message :String, Username :String, AvatarUrl :String, State :PSObject

### Send-Alert

Parameters: Message :String, Severity :String, State :PSObject, Data :Hashtable


