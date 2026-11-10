<#
-------------------------------------------------------------------------------
File: load_bank.ps1
Purpose: write the device 9 tune bank (tools/mkbank.py output) into DDR3 of the
  programmed Nexys Video over JTAG, without reloading core 1's firmware.
Overview:
  * Requires that session ik64 holds the board lock (scripts/ik64_board.ps1
    take); it never takes the lock itself. Without it: exit 2 before any xsdb
    launch. Same lock rules, tool paths (scripts/ik64_tools.ps1) and coordination
    guard as scripts/jtag_load.ps1.
  * xsdb runs scripts/ik64_load_bank.tcl <bank.bin>: select core 1's target, write
    the image at C64_PLAT_BANK_BASE (common/c64_platform.h) with "dow -data" and verify
    words read back. It first tries the write with core 1 running (no stop, no reset). If the
    debug module refuses that access, it stops core 1 only, writes, and resumes it with
    "con" (a short pause; core 0 untouched, no reset, no ELF download). The output states
    which path ran. The firmware validates the bank again at the next OPEN or PING of
    device 9, so no restart of core 1 is needed.
  * To load the bank together with a fresh core 1 image (the bank before the core runs), use
    scripts/jtag_load.ps1 -Core 1 -Bank <bank.bin> instead.
  * -DryRun: prints the xsdb command sequence using plain tclsh: no hw_server, no xsdb, no
    connect, no board lock needed. Exits 0.
  * The bank image holds only the public tunes (ik64 arrangements of public-domain compositions, scores in
    bank/public). Build it with one command; the image stays in build/:
    python -I tools/mkpublicbank.py        (writes build/bank/public.bin; packer: tools/mkbank.py)
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/load_bank.ps1 -Bank <bank.bin> [-DryRun]
Exit codes: 0 PASS, 1 failure, 2 setup/lock error.
Revision: 11-10-2026
  * 11-10-2026: initial version (not run on hardware).
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Bank,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$tcl = Join-Path $PSScriptRoot 'ik64_load_bank.tcl'
if (-not (Test-Path -LiteralPath $Bank)) { Write-Output "IK64_BOARD: FAIL missing bank image $Bank"; exit 1 }
$Bank = (Resolve-Path -LiteralPath $Bank).Path

if ($DryRun) {
    # Offline: no board lock, no hw_server, no xsdb. The Tcl script runs under plain tclsh in "dry" mode.
    $tclsh = (Get-Command tclsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $tclsh -and (Test-Path 'C:\msys64\ucrt64\bin\tclsh.exe')) { $tclsh = 'C:\msys64\ucrt64\bin\tclsh.exe' }
    if (-not $tclsh) { Write-Output 'IK64_BOARD: FAIL no tclsh for -DryRun'; exit 2 }
    $dryOut = & $tclsh $tcl ($Bank -replace '\\', '/') 'dry' 2>&1 | Out-String
    $dryOut -split "`r?`n" | Where-Object { $_ -match '^ik64_jtag:' } | ForEach-Object { Write-Output $_ }
    if ($dryOut -match '(?m)^ik64_jtag: PASS') {
        Write-Output "IK64_BOARD: PASS dry run, bank $Bank (no hardware touched)"
        exit 0
    }
    Write-Output $dryOut
    Write-Output 'IK64_BOARD: FAIL dry run'
    exit 1
}

. (Join-Path $PSScriptRoot 'ik64_board_lib.ps1')
Assert-Ik64Setup
Assert-Ik64LockHeld
$xil = Get-Ik64Tools
$xsdb = $xil.Xsdb
if (-not (Test-Path -LiteralPath $xsdb)) { Write-Ik64Final 'FAIL' "no xsdb at $xsdb"; exit 1 }
$ErrorActionPreference = 'Continue'
$out = & $xsdb $tcl ($Bank -replace '\\', '/') 2>&1 | Out-String
$ErrorActionPreference = 'Stop'
$out -split "`r?`n" | Where-Object { $_ -match '^ik64_jtag:' } | ForEach-Object { Write-Output $_ }
if ($out -match '(?m)^ik64_jtag: PASS') { Write-Ik64Final 'PASS' "bank loaded from $Bank"; exit 0 }
Write-Ik64Final 'FAIL' "bank load of $Bank"
exit 1
