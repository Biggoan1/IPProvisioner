#requires -Version 5.1
<#
.SYNOPSIS
    Builds (and optionally signs) IP Provisioner with ps2exe.
.DESCRIPTION
    Compiles IPProvisioner.ps1 to an exe and, with -Sign, Authenticode-signs the
    exe and the installer against a code-signing certificate (timestamped).
    By default builds a windowed (GUI) exe; add -Console for a command-line exe.
.EXAMPLE
    .\build.ps1
    .\build.ps1 -Sign
    .\build.ps1 -Console -Sign                 # CLI (console) exe
    .\build.ps1 -Sign -CertThumbprint AABBCC... -Version 1.0.1.0
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$OutputExe,
    [string]$Installer,
    [string]$IconFile,
    [string]$Version,
    [switch]$Console,           # build a console (CLI) exe instead of a windowed (GUI) exe
    [switch]$Sign,
    [string]$CertThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Source)    { $Source    = Join-Path $root 'IPProvisioner.ps1' }
if (-not $OutputExe) { $OutputExe = Join-Path $root ($(if ($Console) { 'IPProvisioner-cli.exe' } else { 'IPProvisioner.exe' })) }
if (-not $Installer) { $Installer = Join-Path $root 'IPProvisioner-Install.ps1' }
if (-not $IconFile)  { $IconFile  = Join-Path $root 'IPProvisioner.ico' }

if (-not $Version) {
    $verFile = Join-Path $root 'VERSION'
    $Version = if (Test-Path $verFile) { (Get-Content $verFile -Raw).Trim() } else { '1.0.0' }
}
$vparts = @($Version.Split('.')); while ($vparts.Count -lt 4) { $vparts += '0' }
$Version = ($vparts[0..3] -join '.')

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'ps2exe module not found - installing to CurrentUser scope...'
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe

Write-Host "Compiling`n  $Source`n-> $OutputExe  (console=$([bool]$Console))"
$ps2exeArgs = @{
    InputFile   = $Source
    OutputFile  = $OutputExe
    noConsole   = (-not $Console)
    title       = 'IP Provisioner'
    product     = 'IP Provisioner'
    description = 'IP Provisioner'
    version     = $Version
}
if (Test-Path $IconFile) { $ps2exeArgs['iconFile'] = $IconFile; Write-Host "Using icon: $IconFile" }
else { Write-Warning "No icon at $IconFile - building without a custom icon." }
Invoke-ps2exe @ps2exeArgs
if (-not (Test-Path $OutputExe)) { throw "Build failed: $OutputExe was not produced." }
Write-Host "Built $OutputExe"

function Get-SigningCert {
    param([string]$Thumbprint)
    if ($Thumbprint) {
        $c = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
             Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1
        if (-not $c) { throw "No certificate with thumbprint '$Thumbprint'." }
        return $c
    }
    $c = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
         Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $c) { $c = Get-ChildItem Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
                        Sort-Object NotAfter -Descending | Select-Object -First 1 }
    if (-not $c) { throw 'No code-signing certificate found. Pass -CertThumbprint or import your cert.' }
    return $c
}

if ($Sign) {
    $cert = Get-SigningCert -Thumbprint $CertThumbprint
    Write-Host "Signing with: $($cert.Subject)  [$($cert.Thumbprint)]"
    foreach ($file in @($OutputExe, $Installer)) {
        if (-not (Test-Path $file)) { Write-Warning "Skipping signing (not found): $file"; continue }
        $r = Set-AuthenticodeSignature -FilePath $file -Certificate $cert -TimestampServer $TimestampUrl -HashAlgorithm SHA256
        if ($r.Status -ne 'Valid') { throw "Signing failed for $file : $($r.Status) - $($r.StatusMessage)" }
        Write-Host "Signed: $file"
    }
}
else { Write-Host 'Skipping signing (-Sign not specified).' }
Write-Host "`nDone."
