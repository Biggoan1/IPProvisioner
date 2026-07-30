#requires -Version 5.1
<#
.SYNOPSIS
    Installer / uninstaller for IP Provisioner.
.DESCRIPTION
    Install   : copies the single app exe into C:\Program Files\IPProvisioner (plus a
                copy of this installer for the ARP uninstall entry), pre-creates the
                per-machine data/log folder (user-writable, since the app runs
                unprivileged), writes an Add/Remove Programs entry with DisplayVersion
                (so upgrades detect correctly), and creates Desktop + Start Menu shortcuts.
    Uninstall : removes the ARP entry, shortcuts, and the install folder.

    The one exe is dual-mode: double-click = GUI; run with -Cli/-List = command line.

    Run at deployment (SCCM/MECM) elevated:
        powershell.exe -ExecutionPolicy Bypass -File .\IPProvisioner-Install.ps1 -Action Install
        powershell.exe -ExecutionPolicy Bypass -File .\IPProvisioner-Install.ps1 -Action Uninstall

    NOTE: the app needs NO NCO membership and NO "Log on as a batch job" right - the only
    privileged step is this one-time install (folders, ARP entry, shortcuts).
#>
param(
    [Parameter(Mandatory)][ValidateSet('Install','Uninstall')]
    [string]$Action
)
$ErrorActionPreference = 'Stop'

$AppName      = 'IPProvisioner'
$DisplayName  = 'IP Provisioner'
$Publisher    = 'FAFO Lab'
$ScriptName   = 'IPProvisioner.ps1'
$ExeName      = 'IPProvisioner.exe'
$InstallerName= 'IPProvisioner-Install.ps1'
$ShortcutName = 'IP Provisioner.lnk'
$InstallDir   = Join-Path $env:ProgramFiles $AppName
$DataDir      = Join-Path $env:ProgramData  $AppName          # app runtime logs (user-writable)
$ArpKey       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\IPProvisioner'

$DesktopShortcut   = Join-Path $env:PUBLIC "Desktop\$ShortcutName"
$StartMenuShortcut = Join-Path (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs') $ShortcutName

# Installer transcript follows the house convention: C:\Distrib\Logs.
$HouseLogDir = Join-Path $env:SystemDrive 'Distrib\Logs'
if (-not (Test-Path $HouseLogDir)) { New-Item -Path $HouseLogDir -ItemType Directory -Force | Out-Null }
Start-Transcript -Path (Join-Path $HouseLogDir 'IPProvisioner-Install.log') -Append

function New-AppShortcut {
    param([string]$Path,[string]$Target,[string]$Arguments,[string]$WorkingDir,[string]$Icon)
    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut($Path)
    $sc.TargetPath = $Target
    if ($Arguments)  { $sc.Arguments        = $Arguments }
    if ($WorkingDir) { $sc.WorkingDirectory = $WorkingDir }
    if ($Icon)       { $sc.IconLocation     = $Icon }
    $sc.Save()
}

try {
    switch ($Action) {
        'Install' {
            Write-Host "Action=Install -> $InstallDir"
            New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null

            # One dual-mode exe (GUI + CLI). Ship it if present, else the .ps1 fallback.
            $srcExe = Join-Path $PSScriptRoot $ExeName
            $srcPs1 = Join-Path $PSScriptRoot $ScriptName
            if (Test-Path $srcExe) {
                Copy-Item $srcExe $InstallDir -Force
                $target = Join-Path $InstallDir $ExeName; $appArgs = ''
                $icon   = "$target,0"
            }
            elseif (Test-Path $srcPs1) {
                Copy-Item $srcPs1 $InstallDir -Force
                $target  = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
                $appArgs = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $InstallDir $ScriptName))
                $icon   = "$target,0"
            }
            else { throw "Neither $ExeName nor $ScriptName found next to installer." }

            # Keep a copy of the installer so the ARP UninstallString can call it.
            $srcInstaller = Join-Path $PSScriptRoot $InstallerName
            if (Test-Path $srcInstaller) { Copy-Item $srcInstaller $InstallDir -Force }

            # App runtime data/log dir - user-writable (the app runs unprivileged).
            New-Item -Path (Join-Path $DataDir 'Logs') -ItemType Directory -Force | Out-Null
            & icacls $DataDir /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null   # BUILTIN\Users : Modify

            New-AppShortcut -Path $DesktopShortcut   -Target $target -Arguments $appArgs -WorkingDir $InstallDir -Icon $icon
            New-AppShortcut -Path $StartMenuShortcut -Target $target -Arguments $appArgs -WorkingDir $InstallDir -Icon $icon

            # Add/Remove Programs entry with DisplayVersion (from the exe's FileVersion) so
            # SCCM/house detection can do a proper version comparison instead of file-exists.
            $ver = '1.0.0.0'
            if (Test-Path (Join-Path $InstallDir $ExeName)) {
                try { $ver = (Get-Item (Join-Path $InstallDir $ExeName)).VersionInfo.FileVersion.Trim() } catch { }
            }
            New-Item -Path $ArpKey -Force | Out-Null
            $installerCopy = Join-Path $InstallDir $InstallerName
            $uninstallCmd  = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Uninstall' -f $installerCopy)
            Set-ItemProperty $ArpKey DisplayName     $DisplayName
            Set-ItemProperty $ArpKey DisplayVersion  $ver
            Set-ItemProperty $ArpKey Publisher       $Publisher
            Set-ItemProperty $ArpKey InstallLocation $InstallDir
            Set-ItemProperty $ArpKey DisplayIcon     "$target,0"
            Set-ItemProperty $ArpKey UninstallString $uninstallCmd
            Set-ItemProperty $ArpKey NoModify 1 -Type DWord
            Set-ItemProperty $ArpKey NoRepair 1 -Type DWord
            Write-Host "ARP DisplayVersion = $ver"

            if (-not (Test-Path $target)) { throw "Install verification failed: $target not present" }
            Write-Host 'Install Complete'
        }
        'Uninstall' {
            Write-Host 'Action=Uninstall'
            if (Test-Path $ArpKey) { Remove-Item $ArpKey -Recurse -Force }
            foreach ($lnk in @($DesktopShortcut,$StartMenuShortcut)) { if (Test-Path $lnk) { Remove-Item $lnk -Force -Verbose } }
            if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force -Verbose }
            # App data/logs left in place for audit; remove manually if desired: $DataDir
            Write-Host 'Uninstall Complete'
        }
    }
}
catch { Write-Error "FAILED: $($_.Exception.Message)"; throw }
finally { Stop-Transcript }
