# Policy

14 function(s). Source: `Modules/Policy.psm1`

### Test-OpaAvailable

### Get-PolicyConfig

Parameters: State :PSObject

### Get-PolicyInput

Parameters: State :PSObject, ProjectDir :String, ProjectType :String

### Get-PolicyDir

Parameters: State :PSObject

### Get-PolicyRuleProperty

Parameters: Rule :Object, Name :String, Default :Object

### Test-PolicyPatternValue

Parameters: Value :String, Pattern :String

### Test-PolicyPathMatch

Parameters: Value :String, Pattern :String

### Get-PolicyRuleMatches

Parameters: Rule :Object, InputObject :PSObject, ProjectDir :String

### Invoke-OpaPolicy

Parameters: State :PSObject, InputObject :PSObject, ProjectDir :String

### Invoke-OpaServerPolicy

Parameters: State :PSObject, InputObject :PSObject

### Invoke-BuiltinPolicy

Parameters: State :PSObject, InputObject :PSObject

### Invoke-PolicyChecks

Parameters: State :PSObject, ProjectDir :String, ProjectType :String

### Invoke-PolicyEnforcement

Parameters: Scope :String, Violations :Object[], Enforcement :String, State :PSObject

### ConvertTo-PolicyFlatEntry

Parameters: Root :Object


