# CredentialVault

21 function(s). Source: `Modules/CredentialVault.psm1`

### Get-SafeVaultTenant

Parameters: State :PSObject

### Get-VaultRootDirectory

Parameters: State :PSObject

### Resolve-SafeVaultPath

Parameters: Path :String, State :PSObject

### Get-VaultKeyFile

Parameters: State :PSObject, DefaultPath :String

### Get-VaultPbkdf2Iterations

Parameters: State :PSObject

### Get-VaultSalt

Parameters: Key :String, State :PSObject

### Protect-VaultSecretFile

Parameters: Path :String

### Write-VaultSecretFile

Parameters: Path :String, Content :String, Replace :SwitchParameter

### Get-OrCreateVaultSaltFile

Parameters: Key :String, State :PSObject

### Get-DerivedKey

Parameters: Passphrase :SecureString, Salt :Byte[], Iterations :Int32

### Get-VaultAeadType

### Get-OrCreateVaultKey

Parameters: State :PSObject, KeyFilePath :String, AllowCreate :SwitchParameter

### Get-VaultLegacyCbcAllowed

Parameters: State :PSObject

### Protect-CredentialAes

Parameters: Value :String, State :PSObject, KeyFilePath :String

### Unprotect-CredentialAes

Parameters: ProtectedValue :String, State :PSObject, KeyFilePath :String

### Initialize-DpapiProvider

### Test-CredentialVaultAvailable

### Protect-CredentialValue

Parameters: Value :String, Purpose :String, State :PSObject, KeyFilePath :String

### Unprotect-CredentialValue

Parameters: ProtectedValue :String, Purpose :String, State :PSObject, KeyFilePath :String

### Resolve-ConfigSecrets

Parameters: Node :Object, State :PSObject, KeyFilePath :String

### Write-SecretAuditLog

Parameters: SecretName :String, Action :String, Module :String, LogPath :String, State :PSObject


