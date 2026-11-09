<#
-------------------------------------------------------------------------------
File: build.ps1
Purpose: build the IronKernel 64 core 0 firmware (MicroBlaze V microblaze_0) from the
  hardware handoff build/fpga/c64.xsa into build/fw_c64/c64.elf in one command.
Overview:
  1. Pre-checks: tools/setup_third_party.py --check, tools/regs_check.py (c64_regs.h
     against fpga/hdl/c64_pkg.sv), then build/fw_c64/gen/cpu_selftest_images.c from
     third_party/dormann with tools/dormann_bin2c.py.
  2. BSP: Vitis 2026.1 `vitis -s build/fw_c64/bsp_gen.py <xsa> <ws>` creates a standalone
     platform for microblaze_0 (stdin/stdout = axi_uartlite_0) under build/fw_c64/bsp.
     Cached: build/fw_c64/bsp.stamp holds the SHA-256 of the XSA; the BSP is regenerated
     when it differs (or with -Bsp). Vivado/bin goes on PATH first (sdtgen, lopper).
  3. Linker script build/fw_c64/lscript.ld from fw_c64/lscript_mb_riscv.ld.in (template
     in the repo): everything in core 0's 256 KiB LMB at 0x0 (BD address map
     /microblaze_0/Data/SEG_dlmb_bram_if_cntlr_0_Mem 0x0 + 0x40000, build/bd_check/
     c64_cpu_addr.txt), boot code first, then code, data, heap, stack.
  4. Compile every fw_c64/src/*.c except the superseded software SID (sid.c,
     sid_tables.c) and the recording stub (sidbus_log.c), plus the generated
     cpu_selftest_images.c, with the RISC-V GNU toolchain of the install.
     Flags: the BSP's own (-march/-mabi from <bsp>/cflags.yaml, which come from the
     processor configuration of the XSA: RV32IMC + Zicsr/Zba/Zbb/Zbs), -DSDT, and
     -std=c11 -Wall -Wextra -Werror -pedantic -O2 -g -ffunction-sections
     -fdata-sections.
  5. Link with the BSP start-up (Xilinx.spec), --gc-sections, -Map; print the size
     table (8 largest objects, total) and fail when text+data+bss exceeds the LMB.
Exit codes (one per failure class; 0 = success, prints FW_C64: PASS <elf>):
   2  usage / environment: no Vitis install, no XSA, no RISC-V toolchain
  10  third_party check failed
  11  register header check (regs_check.py) failed
  12  generated test images (dormann_bin2c.py) failed
  20  BSP generation failed
  21  BSP compiler flags unexpected (not rv32 with M, C, Zicsr, ilp32)
  30  compile error or warning
  40  link error or linker warning
  41  image does not fit the LMB (text + data + bss > 0x40000)
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File fw_c64/build.ps1 [-Xsa <xsa>] [-Bsp]
Environment: FW_C64_XILINX = install root (default C:\AMDDesignTools\2026.1).
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [string]$Xsa = '',
    [switch]$Bsp
)
$ErrorActionPreference = 'Stop'

$Fw      = $PSScriptRoot
$Repo    = (Resolve-Path (Join-Path $Fw '..')).Path
$Out     = Join-Path $Repo 'build\fw_c64'
$Gen     = Join-Path $Out 'gen'
$Ws      = Join-Path $Out 'bsp'
$BspDir  = Join-Path $Ws 'plt\microblaze_0\dom\bsp'
$Obj     = Join-Path $Out 'obj'
$LmbBase = 0x0
$LmbSize = 0x40000
$ExcludedSources = @('sid.c', 'sid_tables.c', 'sidbus_log.c')

function Fwd([string]$p) { return ($p -replace '\\', '/') }
function Stop-Build([int]$code, [string]$msg) {
    Write-Output "FW_C64: FAIL ($code) $msg"
    exit $code
}

# Native command with stderr captured to a file: the exit code decides, and any stderr text is
# a warning, which the build treats as a failure of the same class.
function Invoke-Native([string]$exe, [string[]]$argv, [int]$code, [string]$what, [switch]$Continue) {
    $errFile = Join-Path $Out 'stderr.txt'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $exe @argv 2> $errFile
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $err = @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue)
    if ($rc -ne 0) {
        $err | Out-Host
        if ($Continue) { Write-Host "FW_C64: $what failed (exit $rc)"; return $false }
        Stop-Build $code "$what (exit $rc)"
    }
    if ($err.Count -gt 0) {
        $err | Out-Host
        if ($Continue) { Write-Host "FW_C64: $what produced warnings"; return $false }
        Stop-Build $code "$what produced warnings"
    }
    return $true
}

New-Item -ItemType Directory -Force -Path $Out, $Gen | Out-Null

# --- environment ---
$XilinxRoot = if ($env:FW_C64_XILINX) { $env:FW_C64_XILINX } else { 'C:\AMDDesignTools\2026.1' }
$Vitis   = Join-Path $XilinxRoot 'Vitis\bin\vitis.bat'
$RvBin   = Join-Path $XilinxRoot 'gnu\riscv\nt\bin'
$Gcc     = Join-Path $RvBin 'riscv64-unknown-elf-gcc.exe'
$SizeExe = Join-Path $RvBin 'riscv64-unknown-elf-size.exe'
$LdTmpl  = Join-Path $Fw 'lscript_mb_riscv.ld.in'
foreach ($p in @($Vitis, $Gcc, $SizeExe, $LdTmpl)) {
    if (-not (Test-Path -LiteralPath $p)) { Stop-Build 2 "missing $p" }
}
if (-not $Xsa) { $Xsa = Join-Path $Repo 'build\fpga\c64.xsa' }
if (-not (Test-Path -LiteralPath $Xsa)) { Stop-Build 2 "no hardware handoff at $Xsa (build the bitstream first)" }
$Xsa = (Resolve-Path -LiteralPath $Xsa).Path
$py = (Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $py) { Stop-Build 2 'python not found' }

# --- 1. pre-checks ---
Push-Location $Repo
try {
    & python -I tools/setup_third_party.py --check
    if ($LASTEXITCODE -ne 0) { Stop-Build 10 'third_party check failed' }
    & python -I tools/regs_check.py .
    if ($LASTEXITCODE -ne 0) { Stop-Build 11 'regs_check failed' }
    & python -I tools/dormann_bin2c.py third_party/dormann/6502_functional_test.bin `
        third_party/dormann/6502_decimal_test.bin (Join-Path $Gen 'cpu_selftest_images.c')
    if ($LASTEXITCODE -ne 0) { Stop-Build 12 'dormann_bin2c failed' }
} finally {
    Pop-Location
}

# --- 2. BSP (cached on the XSA hash) ---
$xsaHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Xsa).Hash
$marker  = Join-Path $Out 'bsp.stamp'
$fresh = (Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath (Join-Path $BspDir 'lib\libxil.a')) -and
         ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $xsaHash)
if ($Bsp -or -not $fresh) {
    # Windows tools of the BSP build fail on object paths above about 250 characters.
    $deepest = (Fwd $BspDir) + '/libsrc/build_configs/gen_bsp/libsrc/standalone/src/CMakeFiles/xilstandalone.dir/riscv/riscv_invalidate_icache_range.S.obj.d'
    if ($deepest.Length -gt 250) { Stop-Build 20 "BSP path too long ($($deepest.Length) characters)" }
    if (Test-Path -LiteralPath $Ws) { Remove-Item -Recurse -Force -LiteralPath $Ws }
    if (Test-Path -LiteralPath $marker) { Remove-Item -Force -LiteralPath $marker }
    $bspPy = Join-Path $Out 'bsp_gen.py'
    @'
import os
import sys

import vitis

PLATFORM = "plt"
DOMAIN = "dom"
CPU = "microblaze_0"
CONSOLE = "axi_uartlite_0"


def main(argv):
    xsa = os.path.abspath(argv[0]).replace("\\", "/")
    ws = os.path.abspath(argv[1]).replace("\\", "/")
    client = vitis.create_client()
    try:
        client.set_workspace(ws)
        plat = client.create_platform_component(name=PLATFORM, hw_design=xsa, os="standalone", cpu=CPU,
                                                domain_name=DOMAIN)
        dom = plat.get_domain(DOMAIN)
        dom.set_config("os", "standalone_stdin", CONSOLE)
        dom.set_config("os", "standalone_stdout", CONSOLE)
        dom.get_drivers()
        plat.build()
    except Exception as e:
        print(f"FW_C64_BSP: FAIL {e}")
        return 1
    finally:
        vitis.dispose()
    bsp = os.path.join(ws, PLATFORM, CPU, DOMAIN, "bsp").replace("\\", "/")
    for lib in ("libxil.a", "libxilstandalone.a"):
        if not os.path.isfile(os.path.join(bsp, "lib", lib)):
            print(f"FW_C64_BSP: FAIL {lib} not built under {bsp}/lib")
            return 1
    print(f"FW_C64_BSP: PASS {bsp}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
'@ | Set-Content -LiteralPath $bspPy -Encoding ascii
    $env:PATH = "$XilinxRoot\Vivado\bin;$env:PATH"
    $bspLog = Join-Path $Out 'bsp.log'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location $Out
    try {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $Vitis -s (Fwd $bspPy) (Fwd $Xsa) (Fwd $Ws) *> $bspLog
        $ErrorActionPreference = $prev
    } finally {
        Pop-Location
    }
    $verdict = Get-Content -LiteralPath $bspLog | Where-Object { $_ -match '^FW_C64_BSP: ' } | Select-Object -Last 1
    Write-Output "  $verdict ($([int]$sw.Elapsed.TotalSeconds) s)"
    if ($verdict -notmatch '^FW_C64_BSP: PASS') { Stop-Build 20 "BSP generation failed (log $bspLog)" }
    Set-Content -LiteralPath $marker -Value $xsaHash
} else {
    Write-Output "  FW_C64_BSP: up to date $BspDir"
}
$bspInc  = Join-Path $BspDir 'include'
$bspLib  = Join-Path $BspDir 'lib'
$bspSpec = Join-Path $BspDir 'Xilinx.spec'

# BSP compiler flags (processor configuration of the XSA).
$cf = Get-Content -LiteralPath (Join-Path $BspDir 'cflags.yaml') -Raw
$hw = ([regex]::Match($cf, 'cflags:\s*([^\r\n]*(?:\r?\n\s+[^\r\n:]+)*)')).Groups[1].Value -split '\s+' | Where-Object { $_ -ne '' }
$march = ($hw | Where-Object { $_ -like '-march=*' } | Select-Object -First 1)
$mabi  = ($hw | Where-Object { $_ -like '-mabi=*' } | Select-Object -First 1)
if (-not $march -or $march -notmatch '^-march=rv32i[a-z]*m[a-z]*c' -or $march -notmatch 'zicsr' -or $mabi -ne '-mabi=ilp32') {
    Stop-Build 21 "unexpected BSP cflags (expected rv32 with M, C, Zicsr and ilp32): $hw"
}
$arch = @($march, $mabi)
Write-Output "  arch flags (BSP cflags.yaml): $march $mabi"
$mbflags = $arch + @('-DSDT')

# --- 3. linker script from the repo template ---
$ld = Get-Content -LiteralPath $LdTmpl -Raw
$memory = "MEMORY`n{`n   lmb_bram : ORIGIN = 0x{0}, LENGTH = 0x{1}`n}`n" -replace '\{0\}', $LmbBase.ToString('X') -replace '\{1\}', $LmbSize.ToString('X')
$ld = $ld.Replace('@STACK_SIZE@', '0x2000').Replace('@HEAP_SIZE@', '0x400').Replace('@MEMORY_SECTION@', $memory)
$ld = $ld.Replace('@CODE@', 'lmb_bram').Replace('@DATA@', 'lmb_bram')
$ldFile = Join-Path $Out 'lscript.ld'
Set-Content -LiteralPath $ldFile -Value $ld -Encoding ascii

# --- 4. compile ---
if (Test-Path -LiteralPath $Obj) { Remove-Item -Recurse -Force -LiteralPath $Obj }
New-Item -ItemType Directory -Force -Path $Obj | Out-Null
$cflags = @('-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O2', '-g',
            '-ffunction-sections', '-fdata-sections')
$inc = @("-I$(Fwd (Join-Path $Fw 'src'))", "-I$(Fwd (Join-Path $Repo 'common'))", "-I$(Fwd $Gen)",
         '-isystem', (Fwd $bspInc))
$srcs = @(Get-ChildItem -LiteralPath (Join-Path $Fw 'src') -Filter '*.c' |
          Where-Object { $ExcludedSources -notcontains $_.Name } | ForEach-Object { $_.FullName })
$srcs += (Join-Path $Gen 'cpu_selftest_images.c')
$objs = @()
$compileFailed = 0
foreach ($s in $srcs) {
    $o = Join-Path $Obj (([System.IO.Path]::GetFileNameWithoutExtension($s)) + '.o')
    # Every file is compiled so one run reports all errors; the first failure class decides the exit.
    # Workaround (drive_client.c is not owned here): the SDT BSP names the mailbox
    # XPAR_MBOX_0_*, drive_client.c uses XPAR_MAILBOX_0_*; remove when drive_client.c follows the BSP.
    $shim = $(if ([System.IO.Path]::GetFileName($s) -eq 'drive_client.c') { @('-DXPAR_MAILBOX_0_BASEADDR=XPAR_MBOX_0_BASEADDR') } else { @() })
    $ok = Invoke-Native $Gcc ($mbflags + $shim + $cflags + $inc + @("-specs=$(Fwd $bspSpec)", '-c', (Fwd $s), '-o', (Fwd $o))) 30 "compile $([System.IO.Path]::GetFileName($s))" -Continue
    if ($ok) { $objs += $o } else { $compileFailed++ }
}
if ($compileFailed -gt 0) { Stop-Build 30 "$compileFailed source file(s) failed to compile" }

# --- 5. link ---
$elf = Join-Path $Out 'c64.elf'
$map = Join-Path $Out 'c64.map'
$null = Invoke-Native $Gcc ($mbflags + @("-specs=$(Fwd $bspSpec)", "-T$(Fwd $ldFile)", '-Wl,--gc-sections',
    '-Wl,--no-warn-rwx-segments', "-Wl,-Map=$(Fwd $map)", "-L$(Fwd $bspLib)", '-o', (Fwd $elf)) +
    ($objs | ForEach-Object { Fwd $_ }) +
    @('-Wl,--start-group', '-lxil', '-lxilstandalone', '-lxiltimer', '-lgcc', '-lc', '-Wl,--end-group')) 40 'link'

# --- size table ---
Write-Output ''
Write-Output 'Largest objects (bytes):'
$rows = foreach ($o in $objs) {
    $line = (& $SizeExe $o | Select-Object -Last 1) -split '\s+' | Where-Object { $_ -ne '' }
    [pscustomobject]@{ Object = [System.IO.Path]::GetFileName($o); Text = [int]$line[0]; Data = [int]$line[1]; Bss = [int]$line[2]
                       Total = [int]$line[3] }
}
$rows | Sort-Object Total -Descending | Select-Object -First 8 | Format-Table -AutoSize | Out-String | Write-Output
$tot = (& $SizeExe $elf | Select-Object -Last 1) -split '\s+' | Where-Object { $_ -ne '' }
$used = [int]$tot[0] + [int]$tot[1] + [int]$tot[2]
Write-Output ("ELF: text {0} data {1} bss {2} total {3} of LMB {4} ({5:N1} %)" -f $tot[0], $tot[1], $tot[2], $used, $LmbSize,
              (100.0 * $used / $LmbSize))
if ($used -gt $LmbSize) { Stop-Build 41 "image $used bytes exceeds the LMB ($LmbSize)" }
Write-Output "FW_C64: PASS $elf"
exit 0
