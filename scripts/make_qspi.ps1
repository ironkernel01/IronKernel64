<#
-------------------------------------------------------------------------------
File: make_qspi.ps1
Purpose: build the single QSPI flash image of IronKernel 64: the bitstream with core 0's firmware and the
  core 1 bootloader merged into the LMBs, plus the core 1 DDR3 firmware image and the device 9 tune bank
  at flash offset 0x1000000.
Overview:
  1. Merge: updatemem (Vivado) merges the core 0 ELF into u_cpu/microblaze_0 and the bootloader ELF into
     u_cpu/microblaze_1 of c64_hw.bit through c64.mmi -> <Out>/c64_qspi.bit (also programmable over JTAG:
     the bootloader then boots whatever the flash holds).
  2. Blob: tools/mkqspi.py packs fw_1541.elf (PT_LOAD segments flattened) and the bank (build/bank/public.bin,
     built by `python -I tools/mkpublicbank.py`) behind a 64-byte header with CRCs (fw_1541/boot/qspi_format.h).
  3. Image files: scripts/ik64_cfgmem.tcl (write_cfgmem through scripts/ik64_vivado.ps1) writes
     <Out>/ik64_qspi.mcs and .bin for the S25FL256S: bitstream at 0, blob at 0x1000000.
  No board access, no lock. Prints one MAKE_QSPI: line per step and a final PASS/FAIL line.
  Defaults: -Bit build/fpga/c64_hw.bit, -Mmi build/fpga/c64.mmi, -Core0Elf build/fw_c64/c64.elf,
  -BootElf build/fw_1541_boot/boot.elf, -Core1Elf build/fw_1541/fw_1541.elf, -Bank build/bank/public.bin,
  -Out build/qspi. There is one bank (public): no private option.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/make_qspi.ps1 [-Bit ..] [-Mmi ..] [-Core0Elf ..]
         [-BootElf ..] [-Core1Elf ..] [-Bank ..] [-Out ..]
Exit codes: 0 PASS, 1 failure (names the step), 2 setup error (missing input).
Revision: 11-10-2026
  * 11-10-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [string]$Bit = '',
    [string]$Mmi = '',
    [string]$Core0Elf = '',
    [string]$BootElf = '',
    [string]$Core1Elf = '',
    [string]$Bank = '',
    [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ik64_tools.ps1')
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Fin([string]$v, [string]$m) { Write-Output "MAKE_QSPI: $v $m" }
if (-not $Bit)      { $Bit = Join-Path $Repo 'build/fpga/c64_hw.bit' }
if (-not $Mmi)      { $Mmi = Join-Path $Repo 'build/fpga/c64.mmi' }
if (-not $Core0Elf) { $Core0Elf = Join-Path $Repo 'build/fw_c64/c64.elf' }
if (-not $BootElf)  { $BootElf = Join-Path $Repo 'build/fw_1541_boot/boot.elf' }
if (-not $Core1Elf) { $Core1Elf = Join-Path $Repo 'build/fw_1541/fw_1541.elf' }
if (-not $Bank)     { $Bank = Join-Path $Repo 'build/bank/public.bin' }
if (-not $Out)      { $Out = Join-Path $Repo 'build/qspi' }
foreach ($p in @($Bit, $Mmi, $Core0Elf, $BootElf, $Core1Elf, $Bank)) {
    if (-not (Test-Path -LiteralPath $p)) { Fin 'FAIL' "missing input $p"; exit 2 }
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path -LiteralPath $Out).Path
$xil = Resolve-Ik64Xilinx
$um = $xil.Vivado + '/bin/updatemem.bat'
if (-not (Test-Path -LiteralPath $um)) { Fin 'FAIL' "updatemem not found at $um"; exit 2 }

# --- 1. merge both LMBs ---
[xml]$x = Get-Content -LiteralPath $Mmi -Raw
$paths = @($x.MemInfo.Processor | ForEach-Object { $_.InstPath })
foreach ($p in @('u_cpu/microblaze_0', 'u_cpu/microblaze_1')) {
    if ($paths -notcontains $p) { Fin 'FAIL' "MMI has no processor $p (has: $($paths -join ', '))"; exit 1 }
}
$merged = Join-Path $Out 'c64_qspi.bit'
if (Test-Path -LiteralPath $merged) { Remove-Item -LiteralPath $merged -Force }
$log = Join-Path $Out 'merge_elf.log'
Push-Location $Out
try {
    $ErrorActionPreference = 'Continue'
    & $um -force -meminfo $Mmi -data $Core0Elf -proc u_cpu/microblaze_0 -data $BootElf -proc u_cpu/microblaze_1 -bit $Bit -out $merged *> $log
    $rc = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
} finally { Pop-Location }
Get-Content -LiteralPath $log | Where-Object { $_ -match 'ERROR|WARNING|Loading|Writing' } | ForEach-Object { Write-Output "  | $_" }
if ($rc -ne 0 -or -not (Test-Path -LiteralPath $merged)) { Fin 'FAIL' "updatemem exit $rc (log $log)"; exit 1 }
Fin 'STEP' ("merged {0} ({1} bytes)" -f $merged, (Get-Item -LiteralPath $merged).Length)

# --- 2. data blob ---
$buildId = '0'
$info = Join-Path $Repo 'build/fpga/build_info.txt'
if (Test-Path -LiteralPath $info) {
    $m = Select-String -LiteralPath $info -Pattern '^git_hash\s+([0-9a-fA-F]{1,8})' | Select-Object -First 1
    if ($m) { $buildId = $m.Matches[0].Groups[1].Value }
}
$blob = Join-Path $Out 'qspi_data.bin'
$py = Resolve-Ik64Python
& $py -I (Join-Path $Repo 'tools/mkqspi.py') --elf $Core1Elf --bank $Bank --out $blob --build-id $buildId
if ($LASTEXITCODE -ne 0) { Fin 'FAIL' 'mkqspi.py'; exit 1 }

# --- 3. image files ---
$prefix = (Join-Path $Out 'ik64_qspi') -replace '\\', '/'
$vlog = Join-Path $Out 'cfgmem.log'
& (Join-Path $PSScriptRoot 'ik64_vivado.ps1') -Tcl (Join-Path $PSScriptRoot 'ik64_cfgmem.tcl') -Log $vlog `
    -TclArgs @(($merged -replace '\\', '/'), ($blob -replace '\\', '/'), $prefix) | Out-Null
$rc = $LASTEXITCODE
Get-Content -LiteralPath $vlog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^ik64_cfgmem:' } | ForEach-Object { Write-Output $_ }
if ($rc -ne 0) { Fin 'FAIL' "write_cfgmem exit $rc (log $vlog)"; exit 1 }
Fin 'PASS' "$prefix.mcs / .bin (bitstream + core 0 + bootloader + core 1 image + bank)"
exit 0
