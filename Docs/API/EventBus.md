# EventBus

23 function(s). Source: `Modules/EventBus.psm1`

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

### UnsubscribeAll

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

### Get-BuildEventErrors

Parameters: TenantId :String

### Get-BuildEventSubscribers

Parameters: EventName :String, Handler :ScriptBlock, TenantId :String

### Get-BuildEventHandlers

Parameters: EventName :String, TenantId :String

### Clear-BuildEvents

Parameters: TenantId :String

### Get-BuildEventBus

### Get-EventPayloadField

Parameters: Data :Object, Field :String, EventName :String, Default :Object

### Test-BuildEventPayloadContract

Parameters: ModulesRoot :String, ExtraFiles :String[]


