<#
-------------------------------------------------------------------------------
File: program.ps1
Purpose: program the Nexys Video FPGA (volatile) with the IronKernel 64
  bitstream, optionally with the core 0 firmware merged into the LMB first.
Overview:
  * Requires that session ik64 holds the board lock (scripts/ik64_board.ps1
    take); it never takes the lock itself. Without the lock it exits 2 before
    any Vivado launch. -MergeOnly needs no lock (no board access).
  * Default bitstream build/fpga/c64_hw.bit. Prints build/fpga/build_info.txt
    (git_hash, git_dirty, built) first.
  * -WithElf: merges -Elf (default build/fw_c64/c64.elf) into the bitstream
    through build/fpga/c64.mmi with updatemem for processor
    u_cpu/microblaze_0 (core 0), output build/fpga/c64_merged.bit, then programs
    that. -Out overrides the merged file name.
  * -MergeOnly (with -WithElf implied): merge only, no programming.
  * Programming: scripts/ik64_program.tcl run through scripts/ik64_vivado.ps1
    (the machine-wide Vivado slot launcher when ironkernel/src is present, a
    plain Vivado launch otherwise), log build/fpga/program.log; the
    ik64_program: lines are printed.
  * Without ironkernel/src and without the shared-machine folders no board lock
    is checked; with the folders but without ironkernel/src the script refuses
    (exit 2).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/program.ps1 [-Bit <bit>] [-WithElf] [-Elf <elf>] [-MergeOnly]
Exit codes: 0 PASS, 1 failure, 2 setup/lock error.
Revision: 11-09-2026
  * 11-09-2026: initial version.
  * 11-10-2026: own programming Tcl and Vivado launcher, no RTLNet source trees under third_party.
-------------------------------------------------------------------------------
#>
param(
    [string]$Bit = '',
    [switch]$WithElf,
    [string]$Elf = '',
    [string]$Out = '',
    [switch]$MergeOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ik64_board_lib.ps1')
Assert-Ik64Setup
$Repo = $script:Ik64Repo
$FpgaBuild = Join-Path $Repo 'build/fpga'
if ($MergeOnly) { $WithElf = [switch]$true }
if (-not $MergeOnly) { Assert-Ik64LockHeld }

if (-not $Bit) { $Bit = Join-Path $FpgaBuild 'c64_hw.bit' }
if (-not $Elf) { $Elf = Join-Path $Repo 'build/fw_c64/c64.elf' }
if (-not $Out) { $Out = Join-Path $FpgaBuild 'c64_merged.bit' }
$Mmi = Join-Path $FpgaBuild 'c64.mmi'
$Proc = 'u_cpu/microblaze_0'
if (-not (Test-Path -LiteralPath $Bit)) { Write-Ik64Final 'FAIL' "missing bitstream $Bit"; exit 1 }
$Bit = (Resolve-Path -LiteralPath $Bit).Path

$info = Join-Path $FpgaBuild 'build_info.txt'
if (Test-Path -LiteralPath $info) {
    Get-Content -LiteralPath $info | Where-Object { $_ -match '^(design|git_hash|git_dirty|built|tool)\s' } | ForEach-Object { Write-Output "build_info: $_" }
} else { Write-Output "build_info: $info missing" }

$xil = Get-Ik64Tools
$toProgram = $Bit
if ($WithElf) {
    foreach ($p in @($Elf, $Mmi)) { if (-not (Test-Path -LiteralPath $p)) { Write-Ik64Final 'FAIL' "missing $p"; exit 1 } }
    $um = $xil.Vivado + '/bin/updatemem.bat'
    if (-not (Test-Path -LiteralPath $um)) { Write-Ik64Final 'FAIL' "updatemem not found at $um"; exit 1 }
    [xml]$x = Get-Content -LiteralPath $Mmi -Raw
    $paths = @($x.MemInfo.Processor | ForEach-Object { $_.InstPath })
    if ($paths -notcontains $Proc) { Write-Ik64Final 'FAIL' "MMI has no processor $Proc (has: $($paths -join ', '))"; exit 1 }
    foreach ($p in @($Elf, $Mmi, $Bit)) {
        $f = Get-Item -LiteralPath $p
        Write-Output ("merge input {0}  {1} bytes  {2:yyyy-MM-dd HH:mm:ss}" -f $f.FullName, $f.Length, $f.LastWriteTime)
    }
    if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
    $log = Join-Path $FpgaBuild 'merge_elf.log'
    Push-Location $FpgaBuild
    try {
        $ErrorActionPreference = 'Continue'
        & $um -force -meminfo $Mmi -data $Elf -bit $Bit -proc $Proc -out $Out *> $log
        $rc = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
    } finally { Pop-Location }
    Get-Content -LiteralPath $log | Where-Object { $_ -match 'ERROR|WARNING|Loading|Writing' } | ForEach-Object { Write-Output "  | $_" }
    if ($rc -ne 0 -or -not (Test-Path -LiteralPath $Out)) { Write-Ik64Final 'FAIL' "updatemem exit $rc (log $log)"; exit 1 }
    Write-Output ("merged {0}  {1} bytes" -f $Out, (Get-Item -LiteralPath $Out).Length)
    $toProgram = (Resolve-Path -LiteralPath $Out).Path
    if ($MergeOnly) { Write-Ik64Final 'PASS' "merged $Out (not programmed)"; exit 0 }
}

$tcl = Join-Path $PSScriptRoot 'ik64_program.tcl'
$vivadoRunner = Join-Path $PSScriptRoot 'ik64_vivado.ps1'
foreach ($p in @($tcl, $vivadoRunner)) { if (-not (Test-Path -LiteralPath $p)) { Write-Ik64Final 'FAIL' "missing $p"; exit 2 } }
$plog = Join-Path $FpgaBuild 'program.log'
if (Test-Path -LiteralPath $plog) { Remove-Item -LiteralPath $plog -Force }
Write-Output "programming $toProgram"
& $vivadoRunner -Tcl $tcl -Log $plog -TclArgs @(($toProgram -replace '\\', '/')) | Out-Null
$rc = $LASTEXITCODE
if (Test-Path -LiteralPath $plog) {
    Get-Content -LiteralPath $plog | Where-Object { $_ -match '^ik64_program:' } | ForEach-Object { Write-Output $_ }
}
if ($rc -eq 0) { Write-Ik64Final 'PASS' "programmed $toProgram"; exit 0 }
Write-Ik64Final 'FAIL' "program exit $rc (log $plog)"
exit 1
