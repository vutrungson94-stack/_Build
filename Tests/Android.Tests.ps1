Set-StrictMode -Version 1.0

# PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS
. (Join-Path $PSScriptRoot 'Helpers/PlatformShim.ps1')

$modulePath = Join-Path $PSScriptRoot '../Modules/Android.psm1'
Import-Module $modulePath -Force -DisableNameChecking

Describe 'Android' {
    It 'Find-AdbPath returns null when adb not installed (with mock state)' {
        $state = [PSCustomObject]@{ OS = 'Windows'; Colors = @{ Gray = 'Gray'; Err = 'Red' } }
        $path = Find-AdbPath -State $state
        if ($path) {
            (Test-Path $path) | Should -Be $true
        } else {
            $path | Should -BeNullOrEmpty
        }
    }

    It 'New-DebugKeystore returns null when JavaSdk not configured' {
        $state = [PSCustomObject]@{
            OS = 'Windows'
            JavaSdk = if ($IsWindows) { 'C:\nonexistent\java' } else { '/nonexistent/java' }
            Colors = @{ Gray = 'Gray'; Err = 'Red' }
        }
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) 'testkeystore'
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $result = New-DebugKeystore -State $state -ProjectDir $tmpDir
            $result | Should -BeNullOrEmpty
        } finally {
            Remove-Item $tmpDir -Recurse -Force -EA SilentlyContinue
        }
    }

    It 'Get-LauncherActivity returns fallback when ADB unavailable' {
        $state = [PSCustomObject]@{ OS = 'Windows'; Colors = @{ Gray = 'Gray'; Warn = 'Yellow'; Err = 'Red' } }
        $result = Get-LauncherActivity -State $state -AppId 'com.example.app'
        $result | Should -Be '.MainActivity'
    }

    It 'rejects an invalid application id before invoking adb' {
        $state = [PSCustomObject]@{ OS = 'Windows'; Colors = @{ Gray = 'Gray'; Warn = 'Yellow'; Err = 'Red' } }
        Get-LauncherActivity -State $state -AdbPath 'adb' -AppId 'com.example.app; rm -rf /' | Should -Be '.MainActivity'
    }

    It 'does not accept passwords from signing.properties' {
        $dir = Join-Path $TestDrive 'android-props'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $keystore = Join-Path $dir 'release.jks'
        Set-Content -LiteralPath $keystore -Value 'not-a-real-keystore' -Force
        Set-Content -LiteralPath (Join-Path $dir 'signing.properties') -Value "storeFile=release.jks`nstorePassword=property-secret`nkeyPassword=property-secret`n" -Force
        $state = [PSCustomObject]@{ ProjectRoot = $dir; ScriptRoot = $dir; Colors = @{ Gray = 'Gray'; Succ = 'Green'; Err = 'Red' } }
        $result = Find-AndroidKeystore -State $state -ProjectDir $dir
        if ($result) { $result.StorePass | Should -Not -Be 'property-secret'; $result.KeyPass | Should -Not -Be 'property-secret' }
    }
}
