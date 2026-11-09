<#
-------------------------------------------------------------------------------
File: jtag_load.ps1
Purpose: load an ELF into the LMB of MicroBlaze V core 0 or 1 of the
  programmed Nexys Video over JTAG and run it.
Overview:
  * Requires that session ik64 holds the board lock (scripts/ik64_board.ps1
    take); it never takes the lock itself. Without it: exit 2 before any xsdb
    launch.
  * Defaults: -Core 0, -Elf build/fw_c64/c64.elf. xsdb from the Vitis of the
    install located by third_party/rtlnet/scripts/rtlnet_tools.ps1, running
    scripts/ik64_jtag_load.tcl <elf> <core>. The core index selects the Nth
    "Hart*" target of the hw_server (both cores sit behind the 2-port mdm).
    Core 0 is reset with rst -system -stop, core 1 with rst -processor -stop.
  * RTLNet's jtag_load_elf.ps1/.tcl are not called: they need COM3 and the
    RTLNet "rtlnet>" CLI prompt, read RTLNet's CLK_STATUS register at
    0x44A00020, select only the first hart, and depend on
    scripts/rtlnet_tools.ps1 beside them. Their download-verify method is kept
    in ik64_jtag_load.tcl.
  * Output lines "ik64_jtag:" from xsdb are printed.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/jtag_load.ps1 [-Elf <elf>] [-Core 0|1]
Exit codes: 0 PASS, 1 failure, 2 setup/lock error.
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [string]$Elf = '',
    [ValidateSet(0, 1)][int]$Core = 0
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ik64_board_lib.ps1')
Assert-Ik64ThirdParty
Assert-Ik64LockHeld
$Repo = $script:Ik64Repo
if (-not $Elf) { $Elf = Join-Path $Repo 'build/fw_c64/c64.elf' }
if (-not (Test-Path -LiteralPath $Elf)) { Write-Ik64Final 'FAIL' "missing $Elf"; exit 1 }
$Elf = (Resolve-Path -LiteralPath $Elf).Path
$xil = Get-Ik64Tools
$xsdb = $xil.Vitis + '/bin/xsdb.bat'
if (-not (Test-Path -LiteralPath $xsdb)) { Write-Ik64Final 'FAIL' "no xsdb at $xsdb"; exit 1 }
$tcl = Join-Path $PSScriptRoot 'ik64_jtag_load.tcl'
$ErrorActionPreference = 'Continue'
$out = & $xsdb $tcl ($Elf -replace '\\', '/') $Core 2>&1 | Out-String
$ErrorActionPreference = 'Stop'
$out -split "`r?`n" | Where-Object { $_ -match '^ik64_jtag:' } | ForEach-Object { Write-Output $_ }
if ($out -match '(?m)^ik64_jtag: PASS') { Write-Ik64Final 'PASS' "core $Core loaded $Elf"; exit 0 }
Write-Ik64Final 'FAIL' "core $Core load of $Elf"
exit 1
