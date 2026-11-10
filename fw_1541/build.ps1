<#
-------------------------------------------------------------------------------
File: build.ps1
Purpose: build the IronKernel 64 core 1 ("1541" drive) firmware (MicroBlaze V
  microblaze_1) from the hardware handoff build/fpga/c64.xsa into
  build/fw_1541/fw_1541.elf in one command. No RTOS: lwIP NO_SYS=1 raw API, a
  BSD-socket shim (net/ik64_sock.c) for libsmb2, one superloop (src/main.c).
Overview:
  1. Pre-checks: Vitis/RISC-V toolchain, lwIP in the install, third_party
     (libsmb2) present, the network library fw_1541/lib/libik64_netcore.a and its
     header, fw_1541/net/lwipopts.h equal to the option set the library was built
     with (SHA-256 in fw_1541/lib/ik64_netcore.lwipopts.sha256), fw_1541/netshare_config.h
     present (the build stops, naming the file, when it is missing: it holds the NAS
     credentials and is gitignored).
  2. BSP: Vitis 2026.1 `vitis -s` creates a standalone platform for
     microblaze_1 under build/fw_1541/bsp, cached by the SHA-256 of the XSA
     (marker build/fw_1541/bsp.stamp; -Bsp forces a rebuild). -march/-mabi come
     from the BSP's cflags.yaml.
  3. Linker script build/fw_1541/lscript.ld from fw_1541/lscript_mb_riscv.ld.in:
     text, rodata, data, bss, stack and the smb pool in the core 1 DDR3
     partition (0x8000_0000, 64 MiB, common/c64_platform.h), and the .axi_bram
     section in the network BRAM (0xC000_0000, 128 KiB). The ELF is JTAG-loaded
     into DDR3 and started at its entry (_boot).
  4. Compile, in place (no copies into the repo):
       ours     fw_1541/src, fw_1541/net/ik64_*.c   -std=c11 -Wall -Wextra -Werror -pedantic
       netcore  fw_1541/lib/libik64_netcore.a, prebuilt (drivers, CPU path, DMA netif);
                rebuilt from ironkernel/src by ironkernel/build_fwlib.ps1
       lwip     Vitis lwip220 2.2.0 core (NO_SYS=1)  -Wall -Wextra -Werror
       libsmb2  third_party/libsmb2/lib, unmodified  -w (IK64_DEVIATION 5)
  5. Link with the BSP start-up (Xilinx.spec), --gc-sections, -Map; print the
     section totals and the kept bytes per group (from the link map).
Exit codes (0 = success, prints FW_1541: PASS <elf> text/data/bss):
   2  usage / environment: no Vitis, no XSA, no toolchain, third_party or the network library missing
   4  fw_1541/net/lwipopts.h differs from the one libik64_netcore.a was built with
   3  fw_1541/netshare_config.h missing (not checked with -Public)
  42  -Public: a value of fw_1541/netshare_config.h is in the image
  20  BSP generation failed
  21  BSP compiler flags unexpected
  30  compile error or warning
  40  link error or linker warning
  41  image does not fit its memory region
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File fw_1541/build.ps1 [-Xsa <xsa>] [-Bsp] [-Public]
  -Public: release build into build/fw_1541_public with -DPUBLIC (src/netshare.h takes the
    placeholders of netshare_config.example.h; netshare_config.h is never compiled in), then
    scans the ELF for the values of netshare_config.h and fails (42) when one is found.
Environment: FW_1541_XILINX = install root (default C:\AMDDesignTools\2026.1).
Revision: 11-10-2026
  * 11-09-2026: initial version (replaces spike_build.ps1 for the no-RTOS design).
  * 11-10-2026: -Public (PUBLIC define, separate output folder, credential scan of the ELF).
  * 11-10-2026: tune bank reservation (device 9): the linker's ddr3 region ends below
    C64_PLAT_BANK_BASE (read from common/c64_platform.h); backend_ram built in.
-------------------------------------------------------------------------------
#>
param(
    [string]$Xsa = '',
    [string]$OutDir = '',
    [switch]$Bsp,
    [switch]$Public
)
$ErrorActionPreference = 'Stop'

$Fw      = (Resolve-Path -LiteralPath $PSScriptRoot).Path -replace '\\', '/'
$Repo    = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path -replace '\\', '/'
$Out     = if ($OutDir) { $OutDir.Replace('\', '/') } elseif ($Public) { "$Repo/build/fw_1541_public" } else { "$Repo/build/fw_1541" }
$Ws      = "$Out/bsp"
$BspDir  = "$Ws/plt/microblaze_1/dom/bsp"
$Obj     = "$Out/obj"
$DdrBase = 0x80000000L
$DdrSize = 0x04000000
# Tune bank (device 9): the top of the core 1 partition, defined once in common/c64_platform.h.
$plat = Get-Content -LiteralPath "$Repo/common/c64_platform.h" -Raw
$BankBase = [Convert]::ToInt64(([regex]::Match($plat, 'C64_PLAT_BANK_BASE\s+\(0x([0-9A-Fa-f]+)u\)')).Groups[1].Value, 16)
$BankSize = [Convert]::ToInt64(([regex]::Match($plat, 'C64_PLAT_BANK_SIZE\s+\(0x([0-9A-Fa-f]+)u\)')).Groups[1].Value, 16)
$BramBase = 0xC0000000
$BramSize = 0x00020000
$StackSize = '0x8000'

function Stop-Build([int]$code, [string]$msg) {
    Write-Output "FW_1541: FAIL ($code) $msg"
    exit $code
}

# Native command: exit code decides; stderr text is a warning and fails the step.
function Invoke-Native([string]$exe, [string[]]$argv, [int]$code, [string]$what, [switch]$Continue) {
    $errFile = "$Out/stderr.txt"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $exe @argv 2> $errFile
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $err = @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue)
    if ($rc -ne 0) {
        $err | Out-Host
        if ($Continue) { Write-Host "FW_1541: $what failed (exit $rc)"; return $false }
        Stop-Build $code "$what (exit $rc)"
    }
    if ($err.Count -gt 0) {
        $err | Out-Host
        if ($Continue) { Write-Host "FW_1541: $what produced warnings"; return $false }
        Stop-Build $code "$what produced warnings"
    }
    return $true
}

New-Item -ItemType Directory -Force -Path $Out | Out-Null

# --- environment ---
$XilinxRoot = if ($env:FW_1541_XILINX) { $env:FW_1541_XILINX -replace '\\', '/' } else { 'C:/AMDDesignTools/2026.1' }
$Vitis   = "$XilinxRoot/Vitis/bin/vitis.bat"
$RvBin   = "$XilinxRoot/gnu/riscv/nt/bin"
$Gcc     = "$RvBin/riscv64-unknown-elf-gcc.exe"
$SizeExe = "$RvBin/riscv64-unknown-elf-size.exe"
$LwipDir = "$XilinxRoot/Vitis/data/embeddedsw/ThirdParty/sw_services/lwip220_v1_4/src/lwip-2.2.0"
$LdTmpl  = "$Fw/lscript_mb_riscv.ld.in"
$Smb2    = "$Repo/third_party/libsmb2"
$NetLib  = "$Fw/lib"
foreach ($p in @($Vitis, $Gcc, $SizeExe, $LdTmpl, $LwipDir, "$Smb2/lib/libsmb2.c")) {
    if (-not (Test-Path -LiteralPath $p)) { Stop-Build 2 "missing $p (third_party: python tools/setup_third_party.py)" }
}
foreach ($p in @("$NetLib/libik64_netcore.a", "$NetLib/ik64_netcore.h", "$NetLib/ik64_netcore.lwipopts.sha256")) {
    if (-not (Test-Path -LiteralPath $p)) {
        Stop-Build 2 "missing $p (the prebuilt network library; rebuild: python -I tools/setup_ironkernel.py, then ironkernel/build_fwlib.ps1)"
    }
}
# The library was compiled against this option set (pbuf and netif layouts, checksum and zero-copy settings).
$wantHash = ((Get-Content -LiteralPath "$NetLib/ik64_netcore.lwipopts.sha256" -TotalCount 1) -split '\s+')[0].ToLower()
$haveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath "$Fw/net/lwipopts.h").Hash.ToLower()
if ($haveHash -ne $wantHash) {
    Stop-Build 4 "fw_1541/net/lwipopts.h (sha256 $haveHash) differs from the option set libik64_netcore.a was built with ($wantHash); restore lwipopts.h, or rebuild the library with ironkernel/build_fwlib.ps1 (needs ironkernel/src)"
}
if (-not $Public -and -not (Test-Path -LiteralPath "$Fw/netshare_config.h")) {
    Stop-Build 3 "fw_1541/netshare_config.h is missing: copy fw_1541/netshare_config.example.h to fw_1541/netshare_config.h and fill in NETSHARE_USER and NETSHARE_PASSWORD (gitignored, never committed)"
}
if (-not $Xsa) { $Xsa = "$Repo/build/fpga/c64.xsa" }
if (-not (Test-Path -LiteralPath $Xsa)) { Stop-Build 2 "no hardware handoff at $Xsa (build the bitstream first)" }
$Xsa = (Resolve-Path -LiteralPath $Xsa).Path -replace '\\', '/'

# --- 1. BSP (cached on the XSA hash) ---
$xsaHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Xsa).Hash
$marker  = "$Out/bsp.stamp"
$fresh = (Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath "$BspDir/lib/libxil.a") -and
         ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $xsaHash)
if ($Bsp -or -not $fresh) {
    $deepest = "$BspDir/libsrc/build_configs/gen_bsp/libsrc/standalone/src/CMakeFiles/xilstandalone.dir/riscv/riscv_invalidate_icache_range.S.obj.d"
    if ($deepest.Length -gt 250) { Stop-Build 20 "BSP path too long ($($deepest.Length) characters)" }
    if (Test-Path -LiteralPath $Ws) { Remove-Item -Recurse -Force -LiteralPath $Ws }
    if (Test-Path -LiteralPath $marker) { Remove-Item -Force -LiteralPath $marker }
    $bspPy = "$Out/bsp_gen.py"
    @'
import os
import sys

import vitis

PLATFORM = "plt"
DOMAIN = "dom"
CPU = "microblaze_1"


def main(argv):
    xsa = os.path.abspath(argv[0]).replace("\\", "/")
    ws = os.path.abspath(argv[1]).replace("\\", "/")
    client = vitis.create_client()
    try:
        client.set_workspace(ws)
        plat = client.create_platform_component(name=PLATFORM, hw_design=xsa, os="standalone", cpu=CPU,
                                                domain_name=DOMAIN)
        dom = plat.get_domain(DOMAIN)
        dom.get_drivers()
        plat.build()
    except Exception as e:
        print(f"FW_1541_BSP: FAIL {e}")
        return 1
    finally:
        vitis.dispose()
    bsp = os.path.join(ws, PLATFORM, CPU, DOMAIN, "bsp").replace("\\", "/")
    for lib in ("libxil.a", "libxilstandalone.a"):
        if not os.path.isfile(os.path.join(bsp, "lib", lib)):
            print(f"FW_1541_BSP: FAIL {lib} not built under {bsp}/lib")
            return 1
    print(f"FW_1541_BSP: PASS {bsp}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
'@ | Set-Content -LiteralPath $bspPy -Encoding ascii
    $env:PATH = "$XilinxRoot/Vivado/bin;$env:PATH"
    $bspLog = "$Out/bsp.log"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location $Out
    try {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $Vitis -s $bspPy $Xsa $Ws *> $bspLog
        $ErrorActionPreference = $prev
    } finally {
        Pop-Location
    }
    $verdict = Get-Content -LiteralPath $bspLog | Where-Object { $_ -match '^FW_1541_BSP: ' } | Select-Object -Last 1
    Write-Output "  $verdict ($([int]$sw.Elapsed.TotalSeconds) s)"
    if ($verdict -notmatch '^FW_1541_BSP: PASS') { Stop-Build 20 "BSP generation failed (log $bspLog)" }
    Set-Content -LiteralPath $marker -Value $xsaHash
} else {
    Write-Output "  FW_1541_BSP: up to date $BspDir"
}

# BSP compiler flags (processor configuration of the XSA).
$cf = Get-Content -LiteralPath "$BspDir/cflags.yaml" -Raw
$hw = ([regex]::Match($cf, 'cflags:\s*([^\r\n]*(?:\r?\n\s+[^\r\n:]+)*)')).Groups[1].Value -split '\s+' | Where-Object { $_ -ne '' }
$march = ($hw | Where-Object { $_ -like '-march=*' } | Select-Object -First 1)
$mabi  = ($hw | Where-Object { $_ -like '-mabi=*' } | Select-Object -First 1)
if (-not $march -or $march -notmatch '^-march=rv32i[a-z]*m[a-z]*c' -or $march -notmatch 'zicsr' -or $mabi -ne '-mabi=ilp32') {
    Stop-Build 21 "unexpected BSP cflags (expected rv32 with M, C, Zicsr and ilp32): $hw"
}
Write-Output "  arch flags (BSP cflags.yaml): $march $mabi"
$cpu = @($march, $mabi, '-DSDT')

# --- 2. linker script ---
$ld = Get-Content -LiteralPath $LdTmpl -Raw
if ($BankBase -ne ($DdrBase + $DdrSize - $BankSize) -or $BankSize -le 0) {
    Stop-Build 2 "common/c64_platform.h: the bank (0x$($BankBase.ToString('X')) + 0x$($BankSize.ToString('X'))) must end at the top of the core 1 partition"
}
$DdrCode = $DdrSize - $BankSize
# The ddr3 region stops below the bank: no section can be placed there, so the ELF download and the C runtime never touch it.
$memory = "MEMORY`n{`n   ddr3 : ORIGIN = 0x{0}, LENGTH = 0x{1}`n   axi_bram : ORIGIN = 0x{2}, LENGTH = 0x{3}`n}`n" `
    -replace '\{0\}', $DdrBase.ToString('X') -replace '\{1\}', $DdrCode.ToString('X') `
    -replace '\{2\}', $BramBase.ToString('X') -replace '\{3\}', $BramSize.ToString('X')
$memory += "`n/* Tune bank (device 9), reserved by the region above ending short of it: loaded over JTAG, never in the ELF. */`n"
$memory += "__ik64_bank_base = 0x$($BankBase.ToString('X'));`n__ik64_bank_size = 0x$($BankSize.ToString('X'));`n"
$ld = $ld.Replace('@STACK_SIZE@', $StackSize).Replace('@HEAP_SIZE@', '0x0').Replace('@MEMORY_SECTION@', $memory)
$ld = $ld.Replace('@CODE@', 'ddr3').Replace('@DATA@', 'ddr3')
$ldFile = "$Out/lscript.ld"
Set-Content -LiteralPath $ldFile -Value $ld -Encoding ascii

# --- 3. compile ---
if (Test-Path -LiteralPath $Obj) { Remove-Item -Recurse -Force -LiteralPath $Obj }
New-Item -ItemType Directory -Force -Path $Obj | Out-Null
$sysInc  = @('-isystem', "$BspDir/include", "-specs=$BspDir/Xilinx.spec")
$lwipInc = @('-isystem', "$LwipDir/src/include", '-isystem', "$LwipDir/contrib/ports/xilinx/include")
$ourInc  = @("-I$Fw", "-I$Fw/src", "-I$Fw/net", "-I$NetLib", "-I$Repo/common")
$smbInc  = @('-isystem', "$Smb2/include")
$common  = @('-Os', '-g', '-ffunction-sections', '-fdata-sections')

$groups = [ordered]@{}
$compileFailed = 0
function Compile-Group([string]$name, [string[]]$srcs, [string[]]$flags) {
    $objs = @()
    foreach ($s in $srcs) {
        $base = ($name + '_' + ([System.IO.Path]::GetFileNameWithoutExtension($s))) -replace '[^A-Za-z0-9_]', '_'
        $o = "$Obj/$base.o"
        $ok = Invoke-Native $Gcc ($cpu + $common + $flags + @('-c', $s, '-o', $o)) 30 "compile $([System.IO.Path]::GetFileName($s))" -Continue
        if ($ok) { $objs += $o } else { $script:compileFailed++ }
    }
    $script:groups[$name] = $objs
}

$strict = @('-std=c11', '-Wall', '-Wextra', '-Werror')
# ours
$ourSrcs = @(Get-ChildItem -LiteralPath "$Fw/src" -Filter '*.c' | ForEach-Object { $_.FullName -replace '\\', '/' }) +
           @(Get-ChildItem -LiteralPath "$Fw/net" -Filter 'ik64_*.c' | ForEach-Object { $_.FullName -replace '\\', '/' })
$pubDef = if ($Public) { @('-DPUBLIC') } else { @() }   # PUBLIC: src/netshare.h takes the example placeholders
Compile-Group 'ik64' $ourSrcs ($strict + @('-pedantic', '-DIK64_BACKEND_SMB', '-DIK64_BACKEND_RAM') + $pubDef + $ourInc + $lwipInc + $smbInc + $sysInc)
# Network core: the prebuilt library joins the link below; the group keeps its row in the size table.
$groups['netcore'] = @()
# libsmb2, unmodified
$smbSrcs = @('aes.c', 'aes_reference.c', 'aes128ccm.c', 'alloc.c', 'asn1-ber.c', 'compat.c', 'errors.c',
    'hmac.c', 'hmac-md5.c', 'init.c', 'libsmb2.c', 'md4c.c', 'md5.c', 'ntlmssp.c', 'pdu.c', 'quic.c',
    'smbdirect.c', 'sha1.c', 'sha224-256.c', 'sha384-512.c', 'smb2-cmd-cancel.c', 'smb2-cmd-close.c',
    'smb2-cmd-create.c', 'smb2-cmd-echo.c', 'smb2-cmd-error.c', 'smb2-cmd-flush.c', 'smb2-cmd-ioctl.c',
    'smb2-cmd-lock.c', 'smb2-cmd-logoff.c', 'smb2-cmd-negotiate.c', 'smb2-cmd-notify-change.c',
    'smb2-cmd-oplock-break.c', 'smb2-cmd-query-directory.c', 'smb2-cmd-query-info.c', 'smb2-cmd-read.c',
    'smb2-cmd-session-setup.c', 'smb2-cmd-set-info.c', 'smb2-cmd-tree-connect.c',
    'smb2-cmd-tree-disconnect.c', 'smb2-cmd-write.c', 'smb2-data-file-info.c',
    'smb2-data-filesystem-info.c', 'smb2-data-security-descriptor.c', 'smb2-data-reparse-point.c',
    'smb2-share-enum.c', 'smb3-seal.c', 'smb2-signing.c', 'socket.c', 'spnego-wrapper.c', 'sync.c',
    'timestamps.c', 'unicode.c', 'usha.c') | ForEach-Object { "$Smb2/lib/$_" }
# IK64_DEVIATION 7: no PICO_PLATFORM; the BSD socket names come from net/ik64_sock.h, force-included.
Compile-Group 'libsmb2' $smbSrcs (@('-std=gnu11', '-w', '-DHAVE_CONFIG_H', '-D_U_=__attribute__((unused))',
    '-include', "$Fw/net/ik64_sock.h", "-I$Fw/net/smb2cfg_nosys", "-I$Fw/net", "-I$Smb2/include",
    "-I$Smb2/include/smb2", "-I$Smb2/lib") + $lwipInc + $sysInc)
# lwIP 2.2.0 core, NO_SYS=1
$lwSrcs = @('core/init.c', 'core/def.c', 'core/inet_chksum.c', 'core/ip.c', 'core/mem.c', 'core/memp.c',
    'core/netif.c', 'core/pbuf.c', 'core/stats.c', 'core/sys.c', 'core/tcp.c', 'core/tcp_in.c', 'core/tcp_out.c',
    'core/timeouts.c', 'core/raw.c', 'core/ipv4/etharp.c', 'core/ipv4/icmp.c', 'core/ipv4/ip4.c',
    'core/ipv4/ip4_addr.c', 'core/ipv4/ip4_frag.c', 'netif/ethernet.c') | ForEach-Object { "$LwipDir/src/$_" }
Compile-Group 'lwip' $lwSrcs (@('-std=gnu11', '-Wall', '-Wextra', '-Werror', "-I$Fw/net") + $lwipInc + $sysInc)
if ($compileFailed -gt 0) { Stop-Build 30 "$compileFailed source file(s) failed to compile" }

# --- 4. link ---
$elf = "$Out/fw_1541.elf"
$map = "$Out/fw_1541.map"
$allObjs = @(); foreach ($g in $groups.Keys) { $allObjs += $groups[$g] }
$null = Invoke-Native $Gcc ($cpu + @("-specs=$BspDir/Xilinx.spec", "-T$ldFile", '-Wl,--gc-sections',
    '-Wl,--no-warn-rwx-segments', "-Wl,-Map=$map", "-L$NetLib", "-L$BspDir/lib", '-o', $elf) + $allObjs +
    @('-Wl,--start-group', '-lik64_netcore', '-lxil', '-lxilstandalone', '-lgcc', '-lc', '-Wl,--end-group')) 40 'link'

# --- 5. sizes ---
$sizeOut = & $SizeExe $elf
$tot = ($sizeOut | Select-Object -Last 1) -split '\s+' | Where-Object { $_ -ne '' }
$used = [int64]$tot[0] + [int64]$tot[1] + [int64]$tot[2]
$imgText = [int64]$tot[0]
$kept = @{}
foreach ($g in @($groups.Keys) + @('newlib+bsp', 'strings')) { $kept[$g] = @{ text = 0; data = 0; bss = 0 } }
$inMap = $false
$pending = $null
foreach ($line in (Get-Content -LiteralPath $map)) {
    if ($line -match '^Linker script and memory map') { $inMap = $true; continue }
    if (-not $inMap) { continue }
    if ($line -match '^\s(\.[A-Za-z0-9_.$]+)\s*$') { $pending = $Matches[1]; continue }
    $m = [regex]::Match($line, '^\s(\.[A-Za-z0-9_.$]+)?\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(\S+\.(o|a)\S*)\s*$')
    if (-not $m.Success) { $pending = $null; continue }
    $sec = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $pending }
    $pending = $null
    $sz = [Convert]::ToInt64($m.Groups[3].Value, 16)
    if (-not $sec -or $sz -eq 0) { continue }
    $file = $m.Groups[4].Value -replace '\\', '/'
    $grp = 'newlib+bsp'
    foreach ($g in $groups.Keys) { if ($file -match "/obj/${g}_") { $grp = $g; break } }
    if ($file -match 'libik64_netcore') { $grp = 'netcore' }
    if ($sec -match '\.str[0-9]+\.[0-9]+$|^\.rodata\.str') { $grp = 'strings' }
    $kind = if ($sec -match '^\.(s?bss|tbss)') { 'bss' } elseif ($sec -match '^\.(s?data|tdata|init_array|fini_array)') { 'data' } elseif ($sec -match '^\.(text|rodata|srodata|eh_frame|init|fini)') { 'text' } else { $null }
    if ($kind) { $kept[$grp][$kind] += $sz }
}
$attr = 0; foreach ($g in @($groups.Keys) + @('newlib+bsp')) { $attr += $kept[$g].text }
$kept['strings'].text = $imgText - $attr
Write-Output ''
Write-Output ('{0,-12} {1,10} {2,8} {3,10}' -f 'group', 'text+ro', 'data', 'bss')
foreach ($g in @($groups.Keys) + @('newlib+bsp', 'strings')) {
    Write-Output ('{0,-12} {1,10} {2,8} {3,10}' -f $g, $kept[$g].text, $kept[$g].data, $kept[$g].bss)
}
Write-Output "ELF: text $($tot[0]) data $($tot[1]) bss $($tot[2]) total $used of DDR3 code region $DdrCode ($('{0:N1}' -f (100.0 * $used / $DdrCode)) %), bank 0x$($BankBase.ToString('X')) + $BankSize reserved"
if ($used -gt $DdrCode) { Stop-Build 41 "image $used bytes exceeds the core 1 DDR3 code region ($DdrCode, partition $DdrSize minus the $BankSize byte bank)" }
# PUBLIC gate: no value of the owner's netshare_config.h may be in the image (values are never printed).
if ($Public) {
    $cfg = "$Fw/netshare_config.h"
    if (Test-Path -LiteralPath $cfg) {
        $img = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($elf))   # one char per byte
        $exVals = @([regex]::Matches((Get-Content -LiteralPath "$Fw/netshare_config.example.h" -Raw), '#define\s+NETSHARE_\w+\s+"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
        $hits = @()
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $cfg -Raw), '#define\s+(NETSHARE_\w+)\s+"([^"]*)"')) {
            $v = $m.Groups[2].Value
            if ($v.Length -lt 4 -or $exVals -contains $v) { continue }   # too short to identify, or the placeholder itself
            if ($img.Contains($v)) { $hits += $m.Groups[1].Value }
        }
        if ($hits.Count -gt 0) { Stop-Build 42 "PUBLIC image contains values of fw_1541/netshare_config.h: $($hits -join ', ') (values not printed)" }
        Write-Output "FW_1541: PUBLIC scan: no value of fw_1541/netshare_config.h in $elf"
    } else {
        Write-Output "FW_1541: PUBLIC scan: no fw_1541/netshare_config.h on this machine, nothing to compare"
    }
}
Write-Output "FW_1541: PASS $elf text/data/bss $($tot[0])/$($tot[1])/$($tot[2])"
exit 0
