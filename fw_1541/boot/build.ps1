<#
-------------------------------------------------------------------------------
File: build.ps1
Purpose: build the core 1 QSPI bootloader (fw_1541/boot) into build/fw_1541_boot/boot.elf: a freestanding
  RV32 image linked at 0x0 for core 1's 64 KiB LMB, merged into the bitstream by updatemem
  (scripts/make_qspi.ps1).
Overview:
  * No BSP, no libc: fw_1541/boot/start.S, boot.c, boot.ld. Compiled -Os -Wall -Wextra -Werror -pedantic.
  * Checks: the image has no .data/.bss (the LMB is merged as text and rodata only) and fits the 64 KiB LMB.
Exit codes (0 = success, prints FW_BOOT: PASS <elf> text bytes):
   2  usage / environment: toolchain missing
  30  compile error or warning
  40  link error
  41  image has data/bss sections or does not fit
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File fw_1541/boot/build.ps1 [-OutDir <dir>]
Environment: FW_1541_XILINX = install root (default C:\AMDDesignTools\2026.1).
Revision: 11-10-2026
  * 11-10-2026: initial version.
-------------------------------------------------------------------------------
#>
param([string]$OutDir = '')
$ErrorActionPreference = 'Stop'
$Here = (Resolve-Path -LiteralPath $PSScriptRoot).Path -replace '\\', '/'
$Repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path -replace '\\', '/'
$Out  = if ($OutDir) { $OutDir.Replace('\', '/') } else { "$Repo/build/fw_1541_boot" }
$Xil  = if ($env:FW_1541_XILINX) { $env:FW_1541_XILINX -replace '\\', '/' } else { 'C:/AMDDesignTools/2026.1' }
$Rv   = "$Xil/gnu/riscv/nt/bin"
$Gcc  = "$Rv/riscv64-unknown-elf-gcc.exe"
$Size = "$Rv/riscv64-unknown-elf-size.exe"
foreach ($p in @($Gcc, $Size)) { if (-not (Test-Path -LiteralPath $p)) { Write-Output "FW_BOOT: FAIL (2) missing $p"; exit 2 } }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$elf = "$Out/boot.elf"
$err = "$Out/stderr.txt"
# The core's ISA is RV32IMC plus Zicsr, Zifencei and the bit-manipulation sets; the bootloader uses only the base.
$cpu = @('-march=rv32imc_zicsr_zifencei', '-mabi=ilp32')
$src = @("$Here/start.S", "$Here/boot.c")
$argv = $cpu + @('-Os', '-g', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic', '-ffreestanding', '-nostdlib',
    '-nostartfiles', '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections', '-Wl,--build-id=none', '-Wl,--no-warn-rwx-segments',
    "-I$Here", "-I$Repo/common", "-T$Here/boot.ld", "-Wl,-Map=$Out/boot.map", '-o', $elf) + $src
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $Gcc @argv 2> $err
$rc = $LASTEXITCODE
$ErrorActionPreference = $prev
$msgs = @(Get-Content -LiteralPath $err -ErrorAction SilentlyContinue)
if ($rc -ne 0 -or $msgs.Count -gt 0) {
    $msgs | Out-Host
    Write-Output "FW_BOOT: FAIL (30) compile/link (exit $rc)"
    exit 30
}
$sz = (& $Size $elf | Select-Object -Last 1) -split '\s+' | Where-Object { $_ -ne '' }
$text = [int64]$sz[0]; $data = [int64]$sz[1]; $bss = [int64]$sz[2]
if ($data -ne 0 -or $bss -ne 0 -or $text -gt 0x10000) {
    Write-Output "FW_BOOT: FAIL (41) text $text data $data bss $bss (data and bss must be 0, text at most 65536)"
    exit 41
}
Write-Output "FW_BOOT: PASS $elf text $text bytes"
exit 0
