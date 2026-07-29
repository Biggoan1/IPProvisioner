#requires -Version 5.1
<#
.SYNOPSIS
    Installer / uninstaller for IP Provisioner.
.DESCRIPTION
    Install   : copies the app into C:\Program Files\IPProvisioner, pre-creates the
                per-machine data/log folder (writable by users, since the app runs
                unprivileged), and creates public Desktop + Start Menu shortcuts.
    Uninstall : removes the shortcuts and the install folder.

    Run once at deployment (SCCM/MECM) elevated:
        powershell.exe -ExecutionPolicy Bypass -File .\IPProvisioner-Install.ps1 -Action Install
        powershell.exe -ExecutionPolicy Bypass -File .\IPProvisioner-Install.ps1 -Action Uninstall

    NOTE: this app needs NO NCO membership and NO "Log on as a batch job" right - the
    only privileged step is this one-time install (folders + shortcuts).
#>
param(
    [Parameter(Mandatory)][ValidateSet('Install','Uninstall')]
    [string]$Action
)
$ErrorActionPreference = 'Stop'

$AppName      = 'IPProvisioner'
$ScriptName   = 'IPProvisioner.ps1'
$ExeName      = 'IPProvisioner.exe'                       # used if a compiled build is shipped
$ShortcutName = 'IP Provisioner.lnk'
$InstallDir   = Join-Path $env:ProgramFiles $AppName
$DataDir      = Join-Path $env:ProgramData  $AppName
$LogDir       = Join-Path $DataDir 'Logs'

$DesktopShortcut   = Join-Path $env:PUBLIC "Desktop\$ShortcutName"
$StartMenuDir      = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
$StartMenuShortcut = Join-Path $StartMenuDir $ShortcutName

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
Start-Transcript -Path (Join-Path $LogDir 'IPProvisioner-Install.log') -Append

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

            # Ship the compiled exe if present next to the installer, else the .ps1.
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

            # Per-machine data/log dir must be writable by ordinary users, because the
            # app runs unprivileged and logs here.
            New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
            & icacls $DataDir /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null   # BUILTIN\Users : Modify

            New-AppShortcut -Path $DesktopShortcut   -Target $target -Arguments $appArgs -WorkingDir $InstallDir -Icon $icon
            New-AppShortcut -Path $StartMenuShortcut -Target $target -Arguments $appArgs -WorkingDir $InstallDir -Icon $icon

            if (-not (Test-Path (Join-Path $InstallDir $ScriptName)) -and -not (Test-Path (Join-Path $InstallDir $ExeName))) {
                throw "Install verification failed: app not present in $InstallDir"
            }
            Write-Host 'Install Complete'
        }
        'Uninstall' {
            Write-Host 'Action=Uninstall'
            foreach ($lnk in @($DesktopShortcut,$StartMenuShortcut)) { if (Test-Path $lnk) { Remove-Item $lnk -Force -Verbose } }
            if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force -Verbose }
            # Data/logs left in place for audit; remove manually if desired: $DataDir
            Write-Host 'Uninstall Complete'
        }
    }
}
catch { Write-Error "FAILED: $($_.Exception.Message)"; throw }
finally { Stop-Transcript }
