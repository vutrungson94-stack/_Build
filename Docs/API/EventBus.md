# EventBus

22 function(s). Source: `Modules/EventBus.psm1`

### Get-EventValue

Parameters: Object :Object, Name :String, Default :Object

### Get-EventTenant

Parameters: Source :Object, TenantId :String

### Test-EventName

Parameters: EventName :String

### ConvertTo-EventData

Parameters: Data :Object

### BuildEventBus

### NormalizeTenant

### Subscribe

### Unsubscribe

### Publish

### GetErrors

### GetSubscriberCounts

### GetHandlers

### Clear

### Add-BuildEvent

Parameters: EventName :String, Handler :ScriptBlock, Label :String, TenantId :String

### Remove-BuildEvent

Parameters: EventName :String, Handler :ScriptBlock, TenantId :String

### Send-BuildEvent

Parameters: EventName :String, Source :Object, Data :Object, TenantId :String

### Get-BuildEventContract

### Get-BuildEventErrors

Parameters: TenantId :String

### Get-BuildEventSubscribers

### Get-BuildEventHandlers

Parameters: EventName :String, TenantId :String

### Clear-BuildEvents

Parameters: TenantId :String

### Get-BuildEventBus


