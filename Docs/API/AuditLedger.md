# AuditLedger

32 function(s). Source: `Modules/AuditLedger.psm1`

### Get-AuditLedgerDefault

Parameters: Key :String, Fallback :Object

### ConvertTo-LedgerHashtable

Parameters: Value :Object

### Merge-AuditLedgerConfig

Parameters: Override :Object

### Initialize-AuditLedger

Parameters: State :PSObject, Force :SwitchParameter

### Assert-LedgerBackendProvider

Parameters: State :PSObject

### Get-LedgerField

Parameters: Entry :Object, Name :String, Default :Object

### ConvertTo-LedgerScalar

Parameters: Value :Object

### Get-MerkleRoot

Parameters: LeafHashes :String[]

### Export-AuditLedger

Parameters: State :PSObject, Format :String, OutputPath :String, Filter :Hashtable

### Update-AuditRetention

Parameters: State :PSObject

### Start-AuditLedgerVerificationScheduler

Parameters: State :PSObject

### Get-AuditLedgerTenant

Parameters: State :PSObject

### Get-AuditLedgerRoot

Parameters: State :PSObject

### Get-LedgerPath

Parameters: State :PSObject

### Get-LedgerCanonicalEntry

Parameters: Entry :Object, PreviousHash :String, ForSigning :SwitchParameter

### Get-EntryHash

Parameters: Entry :Object, PreviousHash :String

### Get-LedgerSigningData

Parameters: Entry :Object, PreviousHash :String

### Import-LedgerPrivateKeyPem

Parameters: Pem :String, Password :String

### Get-LedgerSignaturePrimitive

Parameters: Algorithm :String

### Get-DataSignature

Parameters: Data :String, KeyPath :String, Algorithm :String

### Test-Signature

Parameters: Data :String, Signature :String, CertPath :String, Algorithm :String

### Get-LedgerWormStatus

Parameters: State :PSObject

### Enter-AuditLedgerLock

Parameters: Path :String

### Sync-AuditLedgerFileState

Parameters: Path :String

### Repair-LedgerTornTail

Parameters: Path :String, State :PSObject

### Save-AuditLedgerCheckpoint

Parameters: State :PSObject, Sequence :Int32

### Get-AuditLedgerAnchor

Parameters: State :PSObject

### Write-AuditLedgerEntry

Parameters: State :PSObject, Entry :Hashtable, Force :SwitchParameter

### Test-AuditLedger

Parameters: State :PSObject, MaxEntries :Int32, FullChain :SwitchParameter

### Test-AuditLedgerRange

Parameters: State :PSObject, FromSequence :Int32, ToSequence :Int32

### Get-AuditLedgerWormStatus

Parameters: State :PSObject

### Set-WormProtection

Parameters: Path :String, Enable :SwitchParameter, Disable :SwitchParameter


