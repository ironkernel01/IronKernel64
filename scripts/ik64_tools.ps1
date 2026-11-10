<#
-------------------------------------------------------------------------------
SPDX-License-Identifier: GPL-3.0-or-later
File: ik64_tools.ps1
Purpose: locate the external tools of the IronKernel 64 scripts (AMD Vivado,
  Vitis and xsdb, Aldec Active-HDL, Python 3) on whatever machine the checkout
  is on, and decide whether the machine-wide coordination of the IronKernel
  workstation applies. No script holds an absolute tool path.
Overview:
  * Dot-source it, then call the resolver the script needs:
      . (Join-Path $PSScriptRoot 'ik64_tools.ps1')
      $x = Resolve-Ik64Xilinx      # Root, Vivado, Vitis, Xsdb, MbBin, RvBin, Version, Source
  * Resolve-Ik64Xilinx search order, first hit wins:
      1. $env:IK64_XILINX (install root, the folder holding Vivado/ and Vitis/)
      2. $env:XILINX_VIVADO (set by the install's settings64 script)
      3. vivado.bat on PATH
      4. <every fixed drive>/AMDDesignTools/<release> and /Xilinx/<release>,
         highest release that holds Vivado/bin/vivado.bat
  * Resolve-Ik64Aldec -> Active-HDL BIN directory: $env:IK64_ALDEC (BIN or
    install root), vsimsa.exe on PATH, <drive>/Aldec/Active-HDL*/BIN.
  * Resolve-Ik64Python -> python.exe: $env:IK64_PYTHON, python on PATH (not the
    Store alias), the py launcher, Python3* folders in the usual places.
  * Get-Ik64Coordination -> object Shared (bool), Src (path of ironkernel/src),
    VivadoSlot (slot launcher script), BoardLock (board lock helper), Reason.
    The shared-machine coordination (board lock, Vivado slots, Active-HDL lock)
    lives in the private ironkernel/src tree. Rules:
      - ironkernel/src present: Shared = true; the scripts use the shared locks.
      - ironkernel/src missing and neither %LOCALAPPDATA%\IronKernel nor
        %LOCALAPPDATA%\RTLNet exists (a machine that never ran the shared
        scripts): Shared = false; scripts run without the shared locks (plain
        Vivado launch, no board lock).
      - ironkernel/src missing but one of those folders exists: the machine takes
        part in the coordination, so a script must not run without it;
        Get-Ik64Coordination throws, Assert-Ik64Coordination prints the reason
        and exits 2.
Revision: 11-10-2026
  * 11-10-2026: initial version (ik64-owned replacement for the RTLNet tool
    resolvers; coordination guard of the release split).
-------------------------------------------------------------------------------
#>

$script:Ik64ToolsRepo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function ConvertTo-Ik64Fwd([string]$p) { return ($p -replace '\\', '/').TrimEnd('/') }

function Get-Ik64DriveRoots {
    return @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
             ForEach-Object { $_.RootDirectory.FullName })
}

# Sort key of a release folder name ("2026.1" -> [version]2026.1); non-releases sort last.
function Get-Ik64ReleaseKey([string]$name) {
    $v = $null
    if ([version]::TryParse(($name -replace '[^0-9.]', ''), [ref]$v)) { return $v }
    return [version]'0.0'
}

function New-Ik64Xilinx([string]$root, [string]$source) {
    $root = ConvertTo-Ik64Fwd $root
    if (-not (Test-Path -LiteralPath "$root/Vivado/bin/vivado.bat")) { return $null }
    return [pscustomobject]@{
        Root    = $root
        Vivado  = "$root/Vivado"
        Vitis   = "$root/Vitis"
        Xsdb    = "$root/Vitis/bin/xsdb.bat"
        MbBin   = "$root/gnu/microblaze/nt/bin"
        RvBin   = "$root/gnu/riscv/nt/bin"
        Version = Split-Path -Leaf $root
        Source  = $source
    }
}

function Resolve-Ik64Xilinx {
    $cands = @()
    if ($env:IK64_XILINX) { $cands += ,@($env:IK64_XILINX, 'IK64_XILINX') }
    if ($env:XILINX_VIVADO) { $cands += ,@((Split-Path -Parent $env:XILINX_VIVADO), 'XILINX_VIVADO') }
    $onPath = Get-Command vivado.bat -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $cands += ,@((Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $onPath.Source))), 'PATH') }
    foreach ($c in $cands) {
        $x = New-Ik64Xilinx $c[0] $c[1]
        if ($x) { return $x }
        if ($c[1] -eq 'IK64_XILINX') { throw "IK64_XILINX=$($c[0]) holds no Vivado/bin/vivado.bat" }
    }
    $found = foreach ($d in Get-Ik64DriveRoots) {
        foreach ($base in 'AMDDesignTools', 'Xilinx') {
            Get-ChildItem -LiteralPath (Join-Path $d $base) -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Vivado\bin\vivado.bat') }
        }
    }
    $best = $found | Sort-Object { Get-Ik64ReleaseKey $_.Name } -Descending | Select-Object -First 1
    if ($best) { return (New-Ik64Xilinx $best.FullName 'search') }
    throw 'no AMD Vivado install found: set IK64_XILINX to the install root (the folder holding Vivado/ and Vitis/)'
}

function Resolve-Ik64Aldec {
    if ($env:IK64_ALDEC) {
        foreach ($b in @($env:IK64_ALDEC, (Join-Path $env:IK64_ALDEC 'BIN'))) {
            if (Test-Path -LiteralPath (Join-Path $b 'vsimsa.exe')) { return (ConvertTo-Ik64Fwd $b) }
        }
        throw "IK64_ALDEC=$($env:IK64_ALDEC) holds no vsimsa.exe"
    }
    $onPath = Get-Command vsimsa.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return (ConvertTo-Ik64Fwd (Split-Path -Parent $onPath.Source)) }
    $found = foreach ($d in Get-Ik64DriveRoots) {
        Get-ChildItem -LiteralPath (Join-Path $d 'Aldec') -Directory -Filter 'Active-HDL*' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'BIN\vsimsa.exe') }
    }
    $best = $found | Sort-Object { Get-Ik64ReleaseKey $_.Name } -Descending | Select-Object -First 1
    if ($best) { return (ConvertTo-Ik64Fwd (Join-Path $best.FullName 'BIN')) }
    throw 'no Aldec Active-HDL install found: set IK64_ALDEC to its BIN folder or put vsimsa.exe on PATH'
}

function Resolve-Ik64Python {
    if ($env:IK64_PYTHON) { return $env:IK64_PYTHON }
    # Skip the Windows Store alias (WindowsApps\python.exe), which only opens the Store.
    $onPath = Get-Command python.exe, python3.exe -ErrorAction SilentlyContinue |
              Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    $py = Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($py) {
        $exe = & $py.Source -3 -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe) { return "$exe".Trim() }
    }
    $roots = @("$env:LOCALAPPDATA\Programs\Python", $env:ProgramFiles) + (Get-Ik64DriveRoots)
    $found = foreach ($r in $roots) {
        Get-ChildItem -LiteralPath $r -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'python.exe') }
    }
    $best = $found | Sort-Object { [int](($_.Name -replace '[^0-9]', '') + '0') } -Descending | Select-Object -First 1
    if ($best) { return (Join-Path $best.FullName 'python.exe') }
    throw 'no Python 3 found: set IK64_PYTHON to python.exe or put it on PATH'
}

# Whether the machine-wide coordination of the IronKernel workstation applies (see the header).
function Get-Ik64Coordination {
    $src = Join-Path $script:Ik64ToolsRepo 'ironkernel/src'
    $slot = Join-Path $src 'rtlnet/scripts/rtlnet_vivado.ps1'
    $lock = Join-Path $src 'rtlnet-board/scripts/rtlnet_board_lock.ps1'
    $present = (Test-Path -LiteralPath $slot) -and (Test-Path -LiteralPath $lock)
    $dirs = @()
    if ($env:LOCALAPPDATA) {
        foreach ($d in 'IronKernel', 'RTLNet') {
            if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA $d)) { $dirs += (Join-Path $env:LOCALAPPDATA $d) }
        }
    }
    if ($present) {
        return [pscustomobject]@{ Shared = $true; Src = $src; VivadoSlot = $slot; BoardLock = $lock
            Reason = 'ironkernel/src present: shared locks apply' }
    }
    if ($dirs.Count -gt 0) {
        $list = $dirs -join ', '
        throw "this machine takes part in the IronKernel workstation coordination ($list exists) but ironkernel/src is missing; the scripts refuse to run without the shared locks. Install it: python -I tools/setup_ironkernel.py"
    }
    return [pscustomobject]@{ Shared = $false; Src = $null; VivadoSlot = $null; BoardLock = $null
        Reason = 'no shared-machine folders and no ironkernel/src: running without the shared locks' }
}

# Script entry guard: prints the refusal and exits 2, otherwise returns the coordination object.
function Assert-Ik64Coordination {
    try { return (Get-Ik64Coordination) }
    catch {
        Write-Output ("IK64_TOOLS: FAIL {0}" -f $_.Exception.Message)
        exit 2
    }
}
