<#
    setup-signing-profile.ps1
    -------------------------
    CAI DAT MOT LAN cho may build: ghi "signing profile" o muc may, de moi
    project duoc ky + phat hanh tu dong, khong can cau hinh tung project.

    File profile: <_Build>\profiles\signing.json  (nam TRONG thu muc _Build)
      - "peSign"  : thong tin chung ky (Azure / signtool / chung chi tu ky)
      - "release" : thu muc phat hanh (rong = ban phat hanh nam trong project)

    Vi du:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\Steps\setup-signing-profile.ps1

        # them Azure Artifact Signing (sau khi da tao account + certificate profile)
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\Steps\setup-signing-profile.ps1 `
             -AzureMetadata "C:\signing\metadata.json" `
             -SignToolPath "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe" `
             -DlibPath "C:\Program Files (x86)\Microsoft Artifact Signing Client\x64\Azure.CodeSigning.Dlib.dll"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Publisher = 'TRUNG SON',
    [string]$ProfilePath = '',
    [string]$ReleaseDir = '',
    [string]$AzureMetadata = '',
    [string]$SignToolPath = '',
    [string]$DlibPath = '',
    [switch]$DisableSigning
)

$ErrorActionPreference = 'Stop'

# The script also runs STANDALONE (not only through the orchestrator), so the
# message resolver may not be loaded yet.
if (-not (Get-Command Resolve-LogMessage -ErrorAction SilentlyContinue)) {
    $loggingModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules') 'Logging.psm1'
    if (Test-Path -LiteralPath $loggingModule -PathType Leaf) {
        $null = Import-Module $loggingModule -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
}

function Write-SetupMessage {
    param([string]$Key, [string]$Fallback, [string]$Color = '')
    $text = Resolve-LogMessage -Key $Key -Fallback $Fallback
    if ($Color) { Write-Host $text -ForegroundColor $Color } else { Write-Host $text }
}

# --- 1. Profile nam trong thu muc _Build -----------------------------------------
if (-not $ProfilePath) {
    # This file lives in <tool>\Steps, so the tool root is its parent.
    $toolRoot = Split-Path -Parent $PSScriptRoot
    $ProfilePath = Join-Path (Join-Path $toolRoot 'profiles') 'signing.json'
}
$profileDir = Split-Path -Parent $ProfilePath
if (-not (Test-Path -LiteralPath $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}

$profile = [ordered]@{
    peSign  = [ordered]@{}
    release = [ordered]@{}
}

# --- 2. Chung chi ky --------------------------------------------------------------
if ($DisableSigning) {
    $profile.peSign = [ordered]@{ enabled = $false }
    Write-SetupMessage -Key 'log.setupSigning.disabled' -Fallback '[1/3] Code signing: DISABLED'
}
elseif ($AzureMetadata -and $SignToolPath -and $DlibPath) {
    $profile.peSign = [ordered]@{
        enabled           = $true
        tool              = 'external'
        externalCommand   = $SignToolPath
        externalArguments = ('sign /v /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib "{0}" /dmdf "{1}" {file}' -f $DlibPath, $AzureMetadata)
        artifacts         = @('*.exe')
        recursive         = $true
        verify            = 'valid'
        failOnError       = $true
    }
    Write-SetupMessage -Key 'log.setupSigning.azure' -Fallback '[1/3] Code signing: Azure Artifact Signing (signtool + dlib)'
}
else {
    # Chung chi tu ky cua may: moi project van duoc KY (khong co CA thi SmartScreen
    # van hoi, nhung file van co chu ky va van mang di ban duoc).
    $subject = "CN=$Publisher (self-signed code signing)"
    $cert = Get-ChildItem -Path 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date).AddMonths(6) } |
        Select-Object -First 1
    if (-not $cert) {
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
            -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy Exportable `
            -NotAfter (Get-Date).AddYears(5) -KeyUsage DigitalSignature
        Write-SetupMessage -Key 'log.setupSigning.signerCreated' -Fallback ("[1/3] Created a new self-signed certificate: " + $cert.Thumbprint)
    }
    else {
        Write-SetupMessage -Key 'log.setupSigning.signerFound' -Fallback ("[1/3] Reusing the existing certificate: " + $cert.Thumbprint)
    }
    $profile.peSign = [ordered]@{
        enabled                = $true
        tool                   = 'powershell'
        certificateThumbprint  = [string]$cert.Thumbprint
        artifacts              = @('*.exe')
        recursive              = $true
        timestampUrl           = 'http://timestamp.digicert.com'
        verify                 = 'signature'
        failOnError            = $false
        autoProvisionSelfSigned = $true
    }
}

# --- 3. Thu muc phat hanh --------------------------------------------------------
# The release package stays INSIDE the built project (<project>\release). Copying
# it somewhere else is opt-in and must be named explicitly.
if ($ReleaseDir) {
    if (-not (Test-Path -LiteralPath $ReleaseDir)) {
        try { New-Item -ItemType Directory -Path $ReleaseDir -Force -ErrorAction Stop | Out-Null }
        catch {
            Write-SetupMessage -Key 'log.setupSigning.releaseDirFailed' -Fallback ("[2/3] Cannot create the release folder: " + $_.Exception.Message) -Color 'Yellow'
            $ReleaseDir = ''
        }
    }
}
if ($ReleaseDir) {
    $profile.release = [ordered]@{ enabled = $true; outputDir = $ReleaseDir }
    Write-SetupMessage -Key 'log.setupSigning.releaseDir' -Fallback ("[2/3] Release folder: " + $ReleaseDir)
}
else {
    $profile.release = [ordered]@{ enabled = $true; outputDir = '' }
    Write-SetupMessage -Key 'log.setupSigning.releaseDirInside' -Fallback '[2/3] Release folder: inside the built project (<project>\release)'
}

# --- 4. Ghi profile --------------------------------------------------------------
$profile | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ProfilePath -Encoding UTF8
Write-SetupMessage -Key 'log.setupSigning.profilePath' -Fallback ("[3/3] Profile: " + $ProfilePath)
Write-Host ""
Get-Content -LiteralPath $ProfilePath -Raw

Write-Host ""
Write-SetupMessage -Key 'log.setupSigning.done' -Fallback 'Done. Every project that builds will now:' -Color 'Green'
Write-SetupMessage -Key 'log.setupSigning.step1' -Fallback '  1. be SIGNED (when the machine has a certificate) - SignArtifacts step'
Write-SetupMessage -Key 'log.setupSigning.step2' -Fallback '  2. be PACKAGED into zip + .sha256 + .json - ReleaseArtifact step'
Write-SetupMessage -Key 'log.setupSigning.hint' -Fallback 'Optional: set the GBUILD_SIGNING_PROFILE environment variable to point at another profile (e.g. per agent).'
