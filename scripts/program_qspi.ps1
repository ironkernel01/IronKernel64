<#
-------------------------------------------------------------------------------
File: program_qspi.ps1
Purpose: write the single QSPI flash image (scripts/make_qspi.ps1) into the Nexys Video configuration flash
  (erase, program, verify), optionally back up the old flash content, and reboot the FPGA from the flash
  without a power cycle.
Overview:
  * Requires that session ik64 holds the board lock (scripts/ik64_board.ps1 take); it never takes the lock
    itself (exit 2 without it). The QSPI flash is shared with session rtlnet-18: message them before writing.
  * Modes (exactly one):
      -Backup [file]   read the whole flash back into build/flash_backup_<date>.bin (default) and exit.
      -Program [mcs]   write the image (default build/qspi/ik64_qspi.mcs) with erase and verify on. The flash backup is optional (user decision 11-10-2026: no backup needed).
      -Reboot          configure the FPGA from the flash (JPROGRAM, boot_hw_device); no JTAG ELF load follows.
  * Vivado runs through scripts/ik64_vivado.ps1 (the machine-wide slot launcher); the Tcl is
    scripts/ik64_qspi.tcl, log build/qspi/qspi_<mode>.log; the ik64_qspi: lines are printed.
  * The helper hw_server that Vivado starts is closed by the Tcl; this script also stops any hw_server it
    left running before it returns (the lock holder kills its own hw_server before release).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/program_qspi.ps1 -Backup | -Program | -Reboot
Exit codes: 0 PASS, 1 failure, 2 setup/lock error.
Revision: 11-10-2026
  * 11-10-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [string]$Backup = '',
    [string]$Program = '',
    [switch]$Reboot
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ik64_board_lib.ps1')
Assert-Ik64Setup
Assert-Ik64LockHeld
$Repo = $script:Ik64Repo
$Q = Join-Path $Repo 'build/qspi'
New-Item -ItemType Directory -Force -Path $Q | Out-Null
$bound = $PSBoundParameters
$modes = @(@($bound.ContainsKey('Backup'), $bound.ContainsKey('Program'), $Reboot.IsPresent) | Where-Object { $_ })
if ($modes.Count -ne 1) { Write-Ik64Final 'FAIL' 'give exactly one of -Backup, -Program, -Reboot'; exit 2 }

$tcl = Join-Path $PSScriptRoot 'ik64_qspi.tcl'
$runner = Join-Path $PSScriptRoot 'ik64_vivado.ps1'
if ($bound.ContainsKey('Backup')) {
    $mode = 'backup'
    if (-not $Backup) { $Backup = Join-Path $Repo ("build/flash_backup_{0}.bin" -f (Get-Date -Format 'yyyy-MM-dd')) }
    $tclArgs = @('backup', ($Backup -replace '\\', '/'))
} elseif ($bound.ContainsKey('Program')) {
    $mode = 'program'
    if (-not $Program) { $Program = Join-Path $Q 'ik64_qspi.mcs' }
    if (-not (Test-Path -LiteralPath $Program)) { Write-Ik64Final 'FAIL' "missing image $Program (scripts/make_qspi.ps1)"; exit 1 }
    $tclArgs = @('program', ((Resolve-Path -LiteralPath $Program).Path -replace '\\', '/'))
} else {
    $mode = 'reboot'
    $tclArgs = @('reboot')
}
$log = Join-Path $Q "qspi_$mode.log"
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $runner -Tcl $tcl -Log $log -TclArgs $tclArgs | Out-Null
$rc = $LASTEXITCODE
Get-Content -LiteralPath $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '^ik64_qspi:' } | ForEach-Object { Write-Output $_ }
# Our hw_server must not outlive the job (the other session needs the cable).
Get-Process -Name hw_server -ErrorAction SilentlyContinue | ForEach-Object { Write-Output "stopping hw_server pid $($_.Id)"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
if ($rc -eq 0) { Write-Ik64Final 'PASS' ("qspi {0} ({1} s)" -f $mode, [int]$sw.Elapsed.TotalSeconds); exit 0 }
Write-Ik64Final 'FAIL' "qspi $mode exit $rc (log $log)"
exit 1
