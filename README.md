# IP Provisioner

A tool for the **disconnected bench-provisioning** workflow: a
field tech sets their laptop's chosen adapter to a specific IP so they can reach a
network device they're programming — **with no local admin, no UAC, no NCO
membership, and no "Log on as a batch job" right.**

## How it works (and why it needs no privilege)

The tool never writes the NIC configuration itself. It runs a tiny, scope-limited
DHCP server that answers **only the selected adapter's own MAC address**, and lets
Windows' built-in **DHCP Client service** (which already runs as SYSTEM) apply the
address. Because the privileged write is performed by that trusted service, the
signed-in user needs no special rights at all — just the ability to run the app and
open a UDP socket, both of which any standard user can do.

Key implementation points:
- Adapter discovery is via `System.Net.NetworkInformation` (no CIM/`Get-NetAdapter`,
  which is denied to non-admins).
- The DHCP replies are pinned to the selected adapter with the `IP_UNICAST_IF`
  socket option, so an OFFER can never egress the wrong interface.
- The lease is held only while the tool runs; closing it lets the address lapse and
  the adapter return to its normal automatic configuration — that is the "off" switch.

## Safety (important for review)

- **Own-MAC guard:** the server only ever offers to the selected adapter's own
  hardware address. It cannot hand an address to any other device even if the
  machine is mistakenly connected to a live network. (Verified: with a foreign MAC
  configured, it refuses and logs "ignored DHCP from … (not the selected adapter)".)
- **Live-network check:** on start it warns if the chosen adapter already has a
  gateway + DHCP lease (a sign it is *not* on an isolated bench link).
- Intended for isolated/disconnected provisioning only. It is not a general DHCP
  server and will not function as one.

## Usage

GUI (default — double-click the shortcut, or run with no arguments):
- pick the adapter, enter the IP / mask / optional gateway / DNS, press **Turn On**;
  press **Turn Off** (or close) to release.

Command line:
```
IPProvisioner.exe -List
IPProvisioner.exe -Cli -Nic "Ethernet 2" -OfferIP 192.168.1.50 -Mask 255.255.255.0 -Gateway 192.168.1.1
IPProvisioner.exe -Cli -Nic "Ethernet 2" -OfferIP 192.168.1.50 -Seconds 0      # run until Ctrl+C
IPProvisioner.exe -Headless -Nic "Ethernet 2" -OfferIP 192.168.1.50 -Seconds 60 # exit once assigned (scripting)
```
CLI status also lands in `C:\ProgramData\IPProvisioner\Logs\ipprovisioner.log`.

## Build & sign

`build.ps1` compiles with ps2exe and (with `-Sign`) Authenticode-signs the exe and
the installer against your code-signing cert (newest in `Cert:\CurrentUser\My`, or
pass `-CertThumbprint`).

```powershell
.\build.ps1 -Sign            # windowed GUI exe (IPProvisioner.exe) for the shortcut
.\build.ps1 -Console -Sign   # console CLI exe (IPProvisioner-cli.exe) for live output
```
Drop an `IPProvisioner.ico` next to `build.ps1` to brand the exe; it builds without one otherwise.
The GUI exe still accepts the CLI switches, but being windowed it has no console to
print to — its status goes to the log. Build the `-Console` variant when you want
live command-line output.

## Install

Run once at deployment (elevated / via SCCM). This is the **only** privileged step —
it creates the install folder, the user-writable data/log folder, and the shortcuts.
No user-right or group changes are made.
```
powershell -ExecutionPolicy Bypass -File .\IPProvisioner-Install.ps1 -Action Install
powershell -ExecutionPolicy Bypass -File .\IPProvisioner-Install.ps1 -Action Uninstall
```
The installer ships the compiled `IPProvisioner.exe` if it is next to the installer,
otherwise the `.ps1` (the shortcut then launches it via `powershell -WindowStyle Hidden -File`).

## Validation performed (W104, Win11 25H2, isolated bridge)

- Happy path: address assigned to the selected adapter. ✓
- Own-MAC guard: foreign MAC refused, no assignment. ✓
- **Non-admin (`winston`)**: assigned with no admin / NCO / batch-logon. ✓
- Live-network guard: corp NIC flagged live, isolated NIC flagged safe. ✓
- Installer install/verify/uninstall; shortcut target + args correct. ✓
- CLI `-List` / `-Cli` (live output) / `-Headless`. ✓
- Still to do on a real desktop: click-test the GUI window itself, and compile/sign.
