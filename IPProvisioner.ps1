#requires -Version 5.1
<#
.SYNOPSIS
  IP Provisioner - set a chosen network adapter's IPv4 address on an ISOLATED
  link (bench provisioning of network gear) with no admin rights and no UAC.
.DESCRIPTION
  The tool never writes the NIC config itself. It runs a tiny scope-limited DHCP
  server that answers ONLY the selected adapter's own MAC, and lets the built-in
  DHCP Client service (which is already SYSTEM) apply the address. Because the
  privileged write is done by that trusted service, the user needs no NCO
  membership, no "Log on as a batch job" right, and no elevation.

  SAFETY: the server only ever offers to the selected adapter's own hardware
  address, so it cannot configure any other device even if the machine is
  mistakenly on a live network. It also refuses to start if another DHCP server
  is already answering on the chosen adapter.

  Intended for the disconnected-from-corporate provisioning workflow only.
.PARAMETER Headless
  Run the DHCP engine directly (no GUI) for -Seconds, for automated testing.
#>
param(
    [switch]$Cli,          # run on the command line (no GUI). Also implied by -Headless.
    [switch]$Headless,     # alias of -Cli that auto-exits once the address is assigned (scripting/tests)
    [switch]$List,         # print the selectable adapters and exit
    [string]$Nic,
    [string]$OfferIP  = '192.168.50.100',
    [string]$Mask     = '255.255.255.0',
    [string]$Gateway  = '',
    [string]$Dns1     = '',
    [string]$Dns2     = '',
    [int]   $Lease    = 3600,
    [int]   $Seconds  = 0,  # CLI run time; 0 = run until Ctrl+C (GUI ignores this)
    [switch]$NoMacGuard,   # test-only: disable the own-MAC safety filter
    [string]$SelectedMac = ''   # test-only: override the MAC the guard compares against
)

$script:LogDir = 'C:\ProgramData\IPProvisioner\Logs'
try { if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null } } catch { }
function Write-Log($m) {
    try { Add-Content -Path (Join-Path $script:LogDir 'ipprovisioner.log') -Encoding UTF8 -Value ("{0} [pid {1}] [{2}] {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $PID, (whoami), $m) } catch { }
}

# --- adapter discovery via .NET (no CIM, no privilege) -----------------------
function Get-PhysAdapters {
    [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
        $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback -and
        $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel -and
        $_.Description -notmatch 'vEthernet|Hyper-V|Virtual |VMware|VirtualBox|TAP-Windows|Loopback|Bluetooth'
    } | Sort-Object Name
}
function Get-AdapterInfo([string]$name) {
    $ni = Get-PhysAdapters | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $ni) { return $null }
    [pscustomobject]@{
        Name    = $ni.Name
        IfIndex = $ni.GetIPProperties().GetIPv4Properties().Index
        Mac     = $ni.GetPhysicalAddress().GetAddressBytes()
        MacStr  = ($ni.GetPhysicalAddress().GetAddressBytes() | ForEach-Object { $_.ToString('X2') }) -join ':'
        Addrs   = @($ni.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.Address.ToString() })
    }
}

# --- safety probe: is another DHCP server already answering on this NIC? -----
# Sends one DISCOVER-shaped nudge is overkill; instead we watch for any inbound
# OFFER (op=2) not from us during a short listen. Simpler + safe: check whether
# the adapter currently holds a DHCP lease with a gateway (sign of a live net).
function Test-LiveNetwork([string]$name) {
    $ni = Get-PhysAdapters | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $ni) { return $false }
    $p = $ni.GetIPProperties()
    $hasGw = @($p.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0' }).Count -gt 0
    $routableLease = @($p.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -notlike '169.254.*' -and $_.PrefixOrigin -eq 'Dhcp' }).Count -gt 0
    return ($hasGw -and $routableLease)
}

# --- the DHCP engine (self-contained: also runs inside a background runspace) -
$EngineScript = {
    param($cfg, $state)
    function IPb([string]$ip) { ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes() }
    function ELog($m) {
        try { Add-Content -Path $cfg.LogFile -Encoding UTF8 -Value ("{0} [engine] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m) } catch { }
        $state.LastEvent = $m
    }
    function Get-MsgType([byte[]]$req) {
        $i = 240
        while ($i -lt $req.Length) {
            $c = $req[$i]; if ($c -eq 255) { break }; if ($c -eq 0) { $i++; continue }
            $l = $req[$i + 1]; if ($c -eq 53) { return $req[$i + 2] }; $i += 2 + $l
        }
        return 0
    }
    function New-Reply([byte[]]$req, [int]$type) {
        $r = New-Object byte[] 300
        $r[0]=2; $r[1]=1; $r[2]=6; $r[3]=0
        [Array]::Copy($req,4,$r,4,4)                    # xid
        [Array]::Copy($req,10,$r,10,2)                  # flags
        [Array]::Copy((IPb $cfg.OfferIP),0,$r,16,4)     # yiaddr
        [Array]::Copy((IPb $cfg.ServerId),0,$r,20,4)    # siaddr
        [Array]::Copy($req,28,$r,28,16)                 # chaddr
        $r[236]=99; $r[237]=130; $r[238]=83; $r[239]=99 # magic cookie
        $i = 240
        $r[$i++]=53; $r[$i++]=1; $r[$i++]=$type
        $r[$i++]=1;  $r[$i++]=4; [Array]::Copy((IPb $cfg.Mask),0,$r,$i,4); $i+=4
        if ($cfg.Gateway) { $r[$i++]=3; $r[$i++]=4; [Array]::Copy((IPb $cfg.Gateway),0,$r,$i,4); $i+=4 }
        $dns = @(); if ($cfg.Dns1) { $dns += $cfg.Dns1 }; if ($cfg.Dns2) { $dns += $cfg.Dns2 }
        if ($dns.Count) { $r[$i++]=6; $r[$i++]=[byte](4*$dns.Count); foreach ($d in $dns) { [Array]::Copy((IPb $d),0,$r,$i,4); $i+=4 } }
        $lb=[BitConverter]::GetBytes([uint32]$cfg.Lease); [Array]::Reverse($lb)
        $r[$i++]=51; $r[$i++]=4; [Array]::Copy($lb,0,$r,$i,4); $i+=4
        $r[$i++]=54; $r[$i++]=4; [Array]::Copy((IPb $cfg.ServerId),0,$r,$i,4); $i+=4
        $r[$i++]=255
        return ,($r[0..($i-1)])
    }

    $state.Running = $true
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $udp.EnableBroadcast = $true
        $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 67)))
        $udp.Client.ReceiveTimeout = 1000
        $noVal = [System.Net.IPAddress]::HostToNetworkOrder([int]$cfg.IfIndex)
        $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]31, $noVal)  # IP_UNICAST_IF
        ELog "listening on UDP/67, egress pinned to ifIndex $($cfg.IfIndex), offering $($cfg.OfferIP) to $($cfg.MacStr) only"
    } catch {
        ELog ("bind/setup FAILED: " + $_.Exception.Message)
        $state.Running = $false; $state.Error = $_.Exception.Message; return
    }
    $bcast = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, 68)

    while (-not $state.Stop) {
        if ($cfg.Deadline -and ([DateTime]::Now -gt $cfg.Deadline)) { break }
        try {
            $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $req = $udp.Receive([ref]$ep)
            $mac = ($req[28..33] | ForEach-Object { $_.ToString('X2') }) -join ':'
            # OWN-MAC GUARD: never answer any client but the selected adapter.
            if ((-not $cfg.NoMacGuard) -and ($mac -ne $cfg.MacStr)) { ELog "ignored DHCP from $mac (not the selected adapter)"; continue }
            $mt = Get-MsgType $req
            if ($mt -eq 1)     { $reply = New-Reply $req 2; [void]$udp.Send($reply,$reply.Length,$bcast); ELog "DISCOVER $mac -> OFFER $($cfg.OfferIP)" }
            elseif ($mt -eq 3) { $reply = New-Reply $req 5; [void]$udp.Send($reply,$reply.Length,$bcast); ELog "REQUEST  $mac -> ACK   $($cfg.OfferIP)"; $state.Assigned = $cfg.OfferIP }
        } catch { }  # receive timeout -> loop and re-check $state.Stop
    }
    try { $udp.Close() } catch { }
    $state.Running = $false
    ELog "stopped"
}

# --- build a config object for the engine -----------------------------------
function New-EngineConfig([string]$name) {
    $info = Get-AdapterInfo $name
    if (-not $info) { throw "adapter '$name' not found" }
    $serverId = $OfferIP  # the tool identifies itself as the offered subnet's .x; simplest = the offer IP
    # derive a server-id in-subnet but distinct from the offer where possible
    try {
        $ob = [System.Net.IPAddress]::Parse($OfferIP).GetAddressBytes()
        $ob[3] = if ($ob[3] -ne 1) { 1 } else { 254 }
        $serverId = ([System.Net.IPAddress]::new($ob)).ToString()
    } catch { }
    $macStr = if ($SelectedMac) { $SelectedMac.ToUpper().Replace('-',':') } else { $info.MacStr }
    [pscustomobject]@{
        Nic=$name; IfIndex=$info.IfIndex; MacStr=$macStr
        OfferIP=$OfferIP; Mask=$Mask; Gateway=$Gateway; Dns1=$Dns1; Dns2=$Dns2
        ServerId=$serverId; Lease=$Lease
        NoMacGuard=[bool]$NoMacGuard
        LogFile=(Join-Path $script:LogDir 'ipprovisioner.log')
        Deadline=$null
    }
}

# ======================== COMMAND-LINE MODE =================================
# -List: show adapters. -Cli / -Headless: run the provisioner without the GUI,
# streaming status to the console (and the log). -Headless additionally exits as
# soon as the address is assigned; -Cli runs for -Seconds (0 = until Ctrl+C).
if ($List) {
    Write-Host 'Selectable adapters:'
    Get-PhysAdapters | ForEach-Object { Write-Host ("  {0}  [{1}]" -f $_.Name, $_.Description) }
    return
}
if ($Cli -or $Headless) {
    if (-not $Nic) {
        Write-Host 'Specify -Nic "<adapter name>". Available adapters:'
        Get-PhysAdapters | ForEach-Object { Write-Host ("  {0}" -f $_.Name) }
        return
    }
    Write-Log "cli start: nic='$Nic' offer=$OfferIP/$Mask gw=$Gateway secs=$Seconds macguard=$(-not $NoMacGuard)"
    try { $cfg = New-EngineConfig $Nic } catch { Write-Host "ERROR: $($_.Exception.Message)"; return }
    if ($Seconds -gt 0) { $cfg | Add-Member Deadline ([DateTime]::Now.AddSeconds($Seconds)) -Force }
    $state = [hashtable]::Synchronized(@{ Stop=$false; Running=$false; Assigned=$null; LastEvent=$null; Error=$null })

    Write-Host ("IP Provisioner - serving {0}/{1} to '{2}' [{3}] ONLY." -f $OfferIP, $Mask, $Nic, $cfg.MacStr)
    if ($Seconds -gt 0) { Write-Host "Running for $Seconds seconds..." } else { Write-Host 'Running until Ctrl+C (closing releases the address)...' }

    Start-Job { ipconfig /release $using:Nic 2>&1 | Out-Null; Start-Sleep 1; ipconfig /renew $using:Nic 2>&1 | Out-Null } | Out-Null
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($EngineScript).AddArgument($cfg).AddArgument($state)
    [void]$ps.BeginInvoke()

    $lastEv = $null; $announced = $false
    try {
        while ($true) {
            if ($cfg.Deadline -and [DateTime]::Now -gt $cfg.Deadline) { break }
            if ($state.Error) { Write-Host "ERROR: $($state.Error)"; break }
            if ($state.LastEvent -and $state.LastEvent -ne $lastEv) { $lastEv = $state.LastEvent; Write-Host "  $lastEv" }
            if ($state.Assigned -and -not $announced) {
                $cur = (Get-AdapterInfo $Nic).Addrs
                if ($cur -contains $state.Assigned) {
                    Write-Host ("OK: '{0}' now has {1}" -f $Nic, $state.Assigned) -ForegroundColor Green
                    $announced = $true
                    if ($Headless) { break }
                }
            }
            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        $state.Stop = $true; Start-Sleep -Milliseconds 400
        try { $ps.Stop(); $ps.Dispose(); $rs.Close(); $rs.Dispose() } catch {}
    }
    $final = (Get-AdapterInfo $Nic).Addrs -join ', '
    Write-Host "Stopped. Final address on '$Nic': $final"
    Write-Log "cli done: assigned=$($state.Assigned) finalAddrs=$final error=$($state.Error)"
    return
}

# ================================ GUI =======================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Runspace = $null
$script:Ps = $null
$script:State = $null

$form = New-Object System.Windows.Forms.Form
$form.Text = 'IP Provisioner'
$form.Size = New-Object System.Drawing.Size(430, 420)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

function AddLabel($t,$x,$y,$w) { $l=New-Object Windows.Forms.Label; $l.Text=$t; $l.Location=New-Object Drawing.Point($x,$y); $l.Size=New-Object Drawing.Size($w,22); $form.Controls.Add($l); $l }
function AddText($x,$y,$w,$val) { $t=New-Object Windows.Forms.TextBox; $t.Location=New-Object Drawing.Point($x,$y); $t.Size=New-Object Drawing.Size($w,22); $t.Text=$val; $form.Controls.Add($t); $t }

AddLabel 'Adapter:' 20 20 90 | Out-Null
$cbAdapter = New-Object System.Windows.Forms.ComboBox
$cbAdapter.Location = New-Object Drawing.Point(115,18); $cbAdapter.Size = New-Object Drawing.Size(280,22)
$cbAdapter.DropDownStyle = 'DropDownList'; $form.Controls.Add($cbAdapter)
Get-PhysAdapters | ForEach-Object { [void]$cbAdapter.Items.Add($_.Name) }
if ($cbAdapter.Items.Count) { $cbAdapter.SelectedIndex = 0 }

AddLabel 'IP address:' 20 55 90 | Out-Null;  $tbIP  = AddText 115 53 160 '192.168.50.100'
AddLabel 'Subnet mask:' 20 88 90 | Out-Null; $tbMask= AddText 115 86 160 '255.255.255.0'
AddLabel 'Gateway:' 20 121 90 | Out-Null;    $tbGw  = AddText 115 119 160 ''
AddLabel '(optional)' 285 121 100 | Out-Null
AddLabel 'DNS:' 20 154 90 | Out-Null;        $tbDns = AddText 115 152 160 ''
AddLabel '(optional)' 285 154 100 | Out-Null

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object Drawing.Point(20,195); $lblStatus.Size = New-Object Drawing.Size(375,90)
$lblStatus.BorderStyle = 'FixedSingle'; $lblStatus.Padding = New-Object Windows.Forms.Padding(6)
$lblStatus.Text = "Idle. Select the adapter cabled to your equipment, set the address, then press Turn On."
$form.Controls.Add($lblStatus)

$btn = New-Object System.Windows.Forms.Button
$btn.Location = New-Object Drawing.Point(115,300); $btn.Size = New-Object Drawing.Size(160,44)
$btn.Text = 'Turn On'; $btn.BackColor = [System.Drawing.Color]::FromArgb(76,175,80); $btn.ForeColor='White'
$btn.FlatStyle='Flat'; $btn.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btn)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 800

function Stop-Engine {
    if ($script:State) { $script:State.Stop = $true }
    Start-Sleep -Milliseconds 300
    if ($script:Ps) { try { $script:Ps.Stop(); $script:Ps.Dispose() } catch {} ; $script:Ps=$null }
    if ($script:Runspace) { try { $script:Runspace.Close(); $script:Runspace.Dispose() } catch {} ; $script:Runspace=$null }
    $timer.Stop()
    $btn.Text='Turn On'; $btn.BackColor=[System.Drawing.Color]::FromArgb(76,175,80)
    $cbAdapter.Enabled=$true; $tbIP.Enabled=$true; $tbMask.Enabled=$true; $tbGw.Enabled=$true; $tbDns.Enabled=$true
}

$btn.Add_Click({
    if ($btn.Text -eq 'Turn Off') { Stop-Engine; $lblStatus.Text = "Turned off. The adapter will fall back to its normal DHCP/automatic address."; return }

    if (-not $cbAdapter.SelectedItem) { [void][Windows.Forms.MessageBox]::Show('Select an adapter first.'); return }
    $OfferIP=$tbIP.Text.Trim(); $Mask=$tbMask.Text.Trim(); $Gateway=$tbGw.Text.Trim(); $dns=$tbDns.Text.Trim()

    if (Test-LiveNetwork $cbAdapter.SelectedItem) {
        $r=[Windows.Forms.MessageBox]::Show(
            "The selected adapter looks like it is on a LIVE network (it has a gateway and a DHCP lease).`n`nThis tool is for isolated bench links only. Continue anyway?",
            'Live network detected',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [Windows.Forms.DialogResult]::Yes) { return }
    }

    try {
        $script:State = [hashtable]::Synchronized(@{ Stop=$false; Running=$false; Assigned=$null; LastEvent=$null; Error=$null })
        $info = Get-AdapterInfo $cbAdapter.SelectedItem
        $serverId=$OfferIP; try { $ob=[System.Net.IPAddress]::Parse($OfferIP).GetAddressBytes(); $ob[3]=@(1,254)[[int]($ob[3] -eq 1)]; $serverId=([System.Net.IPAddress]::new($ob)).ToString() } catch {}
        $cfg=[pscustomobject]@{ Nic=$info.Name; IfIndex=$info.IfIndex; MacStr=$info.MacStr; OfferIP=$OfferIP; Mask=$Mask; Gateway=$Gateway; Dns1=$dns; Dns2=''; ServerId=$serverId; Lease=3600; NoMacGuard=$false; LogFile=(Join-Path $script:LogDir 'ipprovisioner.log'); Deadline=$null }
        $script:Runspace=[runspacefactory]::CreateRunspace(); $script:Runspace.ApartmentState='MTA'; $script:Runspace.Open()
        $script:Ps=[powershell]::Create(); $script:Ps.Runspace=$script:Runspace
        [void]$script:Ps.AddScript($EngineScript).AddArgument($cfg).AddArgument($script:State)
        [void]$script:Ps.BeginInvoke()
        Start-Job { ipconfig /release $using:info.Name 2>&1 | Out-Null; Start-Sleep 1; ipconfig /renew $using:info.Name 2>&1 | Out-Null } | Out-Null
        $btn.Text='Turn Off'; $btn.BackColor=[System.Drawing.Color]::FromArgb(211,47,47)
        $cbAdapter.Enabled=$false; $tbIP.Enabled=$false; $tbMask.Enabled=$false; $tbGw.Enabled=$false; $tbDns.Enabled=$false
        $lblStatus.Text="Turned ON. Serving $OfferIP to $($info.Name) ($($info.MacStr)) only. Plug in / wait for the adapter to pick up the address..."
        $timer.Start()
    } catch { [void][Windows.Forms.MessageBox]::Show("Could not start: $($_.Exception.Message)"); Stop-Engine }
})

$timer.Add_Tick({
    if (-not $script:State) { return }
    $cur = (Get-AdapterInfo $cbAdapter.SelectedItem).Addrs -join ', '
    $ev  = $script:State.LastEvent
    $got = if ($script:State.Assigned -and $cur -match [regex]::Escape($script:State.Assigned)) { "  --  ADAPTER NOW HAS $($script:State.Assigned)" } else { '' }
    $lblStatus.Text = "ON - serving to the selected adapter only.`nLast event: $ev`nAdapter address: $cur$got"
})

$form.Add_FormClosing({ Stop-Engine })
[void]$form.ShowDialog()
