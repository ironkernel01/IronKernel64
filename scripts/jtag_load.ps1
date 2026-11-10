<#
-------------------------------------------------------------------------------
File: jtag_load.ps1
Purpose: load an ELF into MicroBlaze V core 0 (LMB) or core 1 (DDR3) of the
  programmed Nexys Video over JTAG and run it.
Overview:
  * Requires that session ik64 holds the board lock (scripts/ik64_board.ps1
    take); it never takes the lock itself. Without it: exit 2 before any xsdb
    launch.
  * Defaults: -Core 0 with build/fw_c64/c64.elf, -Core 1 with
    build/fw_1541/fw_1541.elf. xsdb from the Vitis of the install located by
    scripts/ik64_tools.ps1 (Resolve-Ik64Xilinx), running
    scripts/ik64_jtag_load.tcl <elf> <core>. The script prefers a hw_server
    target named for microblaze_<core> and falls back to the Nth "Hart*" target
    (both cores sit behind the 2-port mdm); the selection is unverified on
    hardware. Core 0 is reset with rst -system -stop, core 1 with
    rst -processor -stop (that core only: core 0 keeps running). A DDR3 image
    (core 1) waits for the DDR3 calibrated bit of that core's own c64 sysregs
    (core 1 window 0x44A00000) before the download.
  * -DryRun: prints the xsdb command sequence the load would run, using plain
    tclsh: no hw_server, no xsdb, no connect, no board lock needed. Exits 0.
  * The download-verify method of the earlier RTLNet loader is kept in
    ik64_jtag_load.tcl; this loader needs no COM port and no CLI prompt.
  * Without ironkernel/src and without the shared-machine folders no board lock
    is checked (nobody to share with); with the folders but without
    ironkernel/src the script refuses (exit 2).
  * -Bank <bank.bin> (core 1 only): also writes the device 9 tune bank (tools/mkbank.py output) to DDR3 at
    C64_PLAT_BANK_BASE after the ELF download and its verification and before the core resumes, and verifies
    words read back (scripts/ik64_bank_lib.tcl). The core is reset and reloaded as always. To change the
    bank without touching the running core use scripts/load_bank.ps1.
  * Output lines "ik64_jtag:" from xsdb are printed.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/jtag_load.ps1 [-Elf <elf>] [-Core 0|1] [-Bank <bank.bin>] [-DryRun]
Exit codes: 0 PASS, 1 failure, 2 setup/lock error.
Revision: 11-10-2026
  * 11-09-2026: initial version.
  * 11-10-2026: tool paths from ik64_tools.ps1; coordination guard.
  * 11-09-2026: core 1 DDR3 image support (default ELF, calibration wait in the
    Tcl), -DryRun.
  * 11-10-2026: -Bank (device 9 tune bank loaded between ELF download and resume).
-------------------------------------------------------------------------------
#>
param(
    [string]$Elf = '',
    [ValidateSet(0, 1)][int]$Core = 0,
    [string]$Bank = '',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$tcl = Join-Path $PSScriptRoot 'ik64_jtag_load.tcl'
$defaultElf = if ($Core -eq 1) { 'build/fw_1541/fw_1541.elf' } else { 'build/fw_c64/c64.elf' }
$bankArg = @()
if ($Bank) {
    if ($Core -ne 1) { Write-Output 'IK64_BOARD: FAIL -Bank needs -Core 1 (the drive core serves the bank)'; exit 2 }
    if (-not (Test-Path -LiteralPath $Bank)) { Write-Output "IK64_BOARD: FAIL missing bank image $Bank"; exit 1 }
    $bankArg = @('bank', ((Resolve-Path -LiteralPath $Bank).Path -replace '\\', '/'))
}

if ($DryRun) {
    # Offline: no board lock, no hw_server, no xsdb. The Tcl script runs under plain tclsh in "dry" mode.
    $repoDry = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    if (-not $Elf) { $Elf = Join-Path $repoDry $defaultElf }
    if (-not (Test-Path -LiteralPath $Elf)) { Write-Output "IK64_BOARD: FAIL missing $Elf"; exit 1 }
    $Elf = (Resolve-Path -LiteralPath $Elf).Path
    $tclsh = (Get-Command tclsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $tclsh -and (Test-Path 'C:\msys64\ucrt64\bin\tclsh.exe')) { $tclsh = 'C:\msys64\ucrt64\bin\tclsh.exe' }
    if (-not $tclsh) { Write-Output 'IK64_BOARD: FAIL no tclsh for -DryRun'; exit 2 }
    $dryOut = & $tclsh $tcl ($Elf -replace '\\', '/') $Core 'dry' @bankArg 2>&1 | Out-String
    $dryOut -split "`r?`n" | Where-Object { $_ -match '^ik64_jtag:' } | ForEach-Object { Write-Output $_ }
    if ($dryOut -match '(?m)^ik64_jtag: PASS') {
        Write-Output "IK64_BOARD: PASS dry run, core $Core, $Elf (no hardware touched)"
        exit 0
    }
    Write-Output $dryOut
    Write-Output "IK64_BOARD: FAIL dry run, core $Core"
    exit 1
}

. (Join-Path $PSScriptRoot 'ik64_board_lib.ps1')
Assert-Ik64Setup
Assert-Ik64LockHeld
$Repo = $script:Ik64Repo
if (-not $Elf) { $Elf = Join-Path $Repo $defaultElf }
if (-not (Test-Path -LiteralPath $Elf)) { Write-Ik64Final 'FAIL' "missing $Elf"; exit 1 }
$Elf = (Resolve-Path -LiteralPath $Elf).Path
$xil = Get-Ik64Tools
$xsdb = $xil.Xsdb
if (-not (Test-Path -LiteralPath $xsdb)) { Write-Ik64Final 'FAIL' "no xsdb at $xsdb"; exit 1 }
$ErrorActionPreference = 'Continue'
$out = & $xsdb $tcl ($Elf -replace '\\', '/') $Core @bankArg 2>&1 | Out-String
$ErrorActionPreference = 'Stop'
$out -split "`r?`n" | Where-Object { $_ -match '^ik64_jtag:' } | ForEach-Object { Write-Output $_ }
if ($out -match '(?m)^ik64_jtag: PASS') { Write-Ik64Final 'PASS' "core $Core loaded $Elf"; exit 0 }
Write-Ik64Final 'FAIL' "core $Core load of $Elf"
exit 1
