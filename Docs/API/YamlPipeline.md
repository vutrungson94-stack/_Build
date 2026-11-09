# YamlPipeline

16 function(s). Source: `Modules/YamlPipeline.psm1`

### PipelineYamlError

### ConvertTo-PipelineYamlMessage

Parameters: Code :String, ErrorArgs :Object[]

### New-PipelineYamlError

Parameters: Code :String, ErrorArgs :Object[], Origin :String

### Remove-YamlComment

Parameters: Value :String

### ConvertFrom-YamlScalar

Parameters: Value :String

### ConvertFrom-YamlFlowSequence

Parameters: Value :String, Line :String, LineNumber :Int32

### Split-YamlKeyValue

Parameters: Line :String

### ConvertFrom-GBuildYaml

Parameters: Text :Object, Origin :String

### Test-YamlUnsupportedMarker

Parameters: Text :String

### Convert-YamlInlineValue

Parameters: Value :String, Line :String, LineNumber :Int32, Origin :String

### Resolve-PipelineYamlPath

Parameters: Path :String, State :PSObject

### Get-BuildYamlPipelineDocument

Parameters: State :PSObject, Path :String

### Test-PipelineYamlDocument

Parameters: Document :Object, State :PSObject, PassThru :SwitchParameter

### Set-PipelineYamlEnvironment

Parameters: Document :Object, State :PSObject

### Clear-PipelineYamlEnvironment

Parameters: Applied :Hashtable

### ConvertFrom-PipelineYamlStep

Parameters: Document :Object, State :PSObject


