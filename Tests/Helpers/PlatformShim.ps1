#Requires -Version 5.1
<#
.SYNOPSIS
    PS 5.1 compatibility shim for $IsWindows/$IsLinux/$IsMacOS.
.DESCRIPTION
    PowerShell 7+ defines these as automatic variables. Windows PowerShell 5.1
    does not. This shim detects the platform via [System.Environment]::OSVersion
    and defines them so test files and modules can use a single pattern.
#>

if ($PSVersionTable.PSVersion.Major -lt 6) {
    # Windows PowerShell 5.1: always overwrite the global scope to avoid scope clashes
    # between test files (Pester does not carry discovery variables across files into the run phase).
    $global:IsWindows = ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
    $global:IsLinux   = $false
    $global:IsMacOS   = $false
}
