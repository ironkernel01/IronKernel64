<#
-------------------------------------------------------------------------------
File: ik64_run_sim.ps1
Purpose: run one IronKernel 64 self-checking testbench in Aldec Active-HDL (batch,
  vsimsa) and turn its verdict into an exit code.
Overview:
  * Serializes simulator use: the workstation has one Active-HDL seat. A
    machine-wide delete-on-close lock file (%LOCALAPPDATA%/RTLNet/
    activehdl.lock, shared by every checkout and git worktree) admits one
    runner at a time; the runner also waits while any avhdl / avhdl_core /
    vsimsa process it does not own is running. It never stops another process.
  * Builds the vendor simulation libraries once per Vivado version, in place
    from the Vivado install (nothing copied into the repository), into
    %LOCALAPPDATA%/RTLNet/xlib-<tool version>: library `xpm` (xpm_memory, xpm_cdc)
    and `unisims_ver` (the primitives the RTLNet pin layers and board tops
    use, plus glbl). Stamp: xlib.done.
  * Expands the bench filelist (paths relative to the repository root,
    nested `-f`, `+incdir+`, `+define+`, `#`/`//` comments) into an absolute
    design.f in .sim/<bench>[_<tag>]/. A filelist inside a copied third-party
    tree (an ancestor directory holding SOURCE.txt, e.g. third_party/rtlnet)
    resolves its paths against that tree's root, so upstream filelists nest
    unmodified: `-f third_party/rtlnet/cores/rtlnet_common/hdl/rtlnet_common.f`.
    A line `$VIVADO/<path>` names a source inside the located Vivado install
    (e.g. `$VIVADO/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv`, which the shared
    vendor library does not hold); it compiles into work.
  * PASS requires: a fresh log, simulator exit code 0, exactly the anchored
    line `TEST PASS: <bench>` (optional `KERNEL:` prefix), no `TEST FAIL`,
    and no compile, elaboration or runtime error/fatal lines. With
    -ExpectFail (the +INJECT_FAILURE negative control) the anchored
    `TEST FAIL: <bench>` line is required instead.
  * Prints one summary line `IK64_SIM: PASS|FAIL <bench>[<tag>] ...` and
    exits 0 on PASS, 1 otherwise.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ik64_run_sim.ps1 `
      -Bench tb_c64_sysregs -Filelist fpga/tb/tb_c64_sysregs.f
  Options: -Tag <name> (separate work dir per configuration), -Defines A,B=1,
    -PlusArgs INJECT_FAILURE,SEED=5, -ExpectFail, -TimeoutSeconds 3600,
    -Waves (write .sim/<bench>/waves.asdb with +access +r).
Revision: 11-09-2026
  * 11-09-2026: initial version, copied from RTLNet scripts/rtlnet_run_sim.ps1
    (third_party/rtlnet, commit in SOURCE.txt): repository root = this repo, tool
    resolvers dot-sourced from third_party/rtlnet/scripts/rtlnet_tools.ps1, summary
    token IK64_SIM. The Active-HDL lock (%LOCALAPPDATA%/RTLNet/activehdl.lock) and
    the shared vendor-library cache are deliberately the same as RTLNet's, so
    both repositories serialize on the single seat.
  * 11-09-2026: nested filelists resolve against their own tree's root (third-party
    trees marked by SOURCE.txt); `$VIVADO/` filelist prefix.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Bench,
    [Parameter(Mandatory = $true)][string]$Filelist,
    [string]$Tag = '',
    [string[]]$Defines = @(),
    [string[]]$PlusArgs = @(),
    [switch]$ExpectFail,
    [int]$TimeoutSeconds = 3600,
    [int]$LockWaitSeconds = 7200,
    [switch]$Waves
)

$ErrorActionPreference = 'Stop'

# powershell -File delivers '-Defines A,B' as one string: split every entry on commas.
$Defines  = @($Defines  | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
$PlusArgs = @($PlusArgs | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })

$Repo     = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $Repo 'third_party/rtlnet/scripts/rtlnet_tools.ps1')
$AldecBin = Resolve-RtlnetAldec
$Vsimsa   = Join-Path $AldecBin 'vsimsa.exe'
$Xil      = Resolve-RtlnetXilinx
$Vivado   = $Xil.Vivado
$SimRoot  = Join-Path $Repo '.sim'
$Shared   = Join-Path $env:LOCALAPPDATA 'RTLNet'
$XlibDir  = Join-Path $Shared "xlib-$($Xil.Version)"
$RunName  = if ($Tag) { "${Bench}_$Tag" } else { $Bench }
$WorkDir  = Join-Path $SimRoot $RunName

function Write-Summary([string]$verdict, [string]$detail) {
    Write-Output ("IK64_SIM: {0} {1} {2}" -f $verdict, $RunName, $detail)
}

function To-Fwd([string]$p) { return ($p -replace '\\', '/') }

if (-not (Test-Path -LiteralPath $Vsimsa)) { throw "Active-HDL vsimsa not found at $Vsimsa" }
New-Item -ItemType Directory -Force -Path $SimRoot | Out-Null
New-Item -ItemType Directory -Force -Path $Shared | Out-Null

# -----------------------------------------------------------------------------
# One seat: acquire the delete-on-close lock, then wait for foreign simulators.
# -----------------------------------------------------------------------------
$LockPath = Join-Path $Shared 'activehdl.lock'
$Lock = $null
$deadline = (Get-Date).AddSeconds($LockWaitSeconds)
while ($null -eq $Lock) {
    try {
        $Lock = [System.IO.FileStream]::new($LockPath, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read, 4096,
            [System.IO.FileOptions]::DeleteOnClose)
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("pid=$PID bench=$RunName`r`n")
        $Lock.Write($bytes, 0, $bytes.Length); $Lock.Flush()
    } catch [System.IO.IOException] {
        if ((Get-Date) -gt $deadline) { Write-Summary 'FAIL' 'lock wait timeout'; exit 1 }
        Start-Sleep -Seconds 5
    }
}

try {
    while (@(Get-Process -Name avhdl, avhdl_core, vsimsa -ErrorAction SilentlyContinue).Count -gt 0) {
        if ((Get-Date) -gt $deadline) { Write-Summary 'FAIL' 'another Active-HDL instance stayed open'; exit 1 }
        Start-Sleep -Seconds 5
    }

    # Runs one vsimsa macro in $dir with a timeout; returns the exit code.
    function Invoke-Vsimsa([string]$dir, [string]$macro, [string]$log, [int]$timeout) {
        if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
        $out = Join-Path $dir 'vsimsa_stdout.txt'
        $err = Join-Path $dir 'vsimsa_stderr.txt'
        $p = Start-Process -FilePath $Vsimsa -ArgumentList @('-l', (To-Fwd $log), '-do', (To-Fwd $macro)) `
            -WorkingDirectory $dir -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $p.Handle
        if (-not $p.WaitForExit($timeout * 1000)) {
            try { $p.Kill() } catch { }
            return -999
        }
        return $p.ExitCode
    }

    # -------------------------------------------------------------------------
    # Vendor libraries, compiled in place once.
    # -------------------------------------------------------------------------
    $Stamp = Join-Path $XlibDir 'xlib.done'
    if (-not (Test-Path -LiteralPath $Stamp)) {
        New-Item -ItemType Directory -Force -Path $XlibDir | Out-Null
        $uni = Join-Path $Vivado 'data/verilog/src/unisims'
        $prims = @('IBUF', 'OBUF', 'IOBUF', 'IBUFDS', 'BUFG', 'BUFGCE', 'BUFIO', 'BUFR', 'IDDR', 'ODDR',
                   'IDELAYE2', 'IDELAYCTRL', 'SRLC32E', 'MMCME2_ADV', 'MMCME2_BASE', 'PLLE2_ADV', 'PLLE2_BASE')
        $uniFiles = @()
        foreach ($p in $prims) {
            $f = Join-Path $uni "$p.v"
            if (Test-Path -LiteralPath $f) { $uniFiles += ('"' + (To-Fwd $f) + '"') }
        }
        $glbl = '"' + (To-Fwd (Join-Path $Vivado 'data/verilog/src/glbl.v')) + '"'
        $xpmMem = '"' + (To-Fwd (Join-Path $Vivado 'data/ip/xpm/xpm_memory/hdl/xpm_memory.sv')) + '"'
        $xpmCdc = '"' + (To-Fwd (Join-Path $Vivado 'data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv')) + '"'
        $xdo = @(
            'onerror {quit -code 2}',
            ('alib xpm "' + (To-Fwd (Join-Path $XlibDir 'xpm')) + '"'),
            "alog -sv2k12 -work xpm $xpmMem $xpmCdc",
            ('alib unisims_ver "' + (To-Fwd (Join-Path $XlibDir 'unisims_ver')) + '"'),
            ("alog -v2k5 -work unisims_ver " + ($uniFiles -join ' ') + " $glbl"),
            'quit -code 0'
        )
        $xmacro = Join-Path $XlibDir 'build_xlib.do'
        Set-Content -LiteralPath $xmacro -Value $xdo -Encoding ascii
        $xlog = Join-Path $XlibDir 'build_xlib.log'
        $rc = Invoke-Vsimsa $XlibDir $xmacro $xlog 1800
        $xtext = if (Test-Path -LiteralPath $xlog) { Get-Content -LiteralPath $xlog -Raw } else { '' }
        if ($rc -ne 0 -or $xtext -match '(?m)^\s*(# )?Error:') {
            Write-Summary 'FAIL' "vendor library build failed (rc=$rc), see $xlog"
            exit 1
        }
        Set-Content -LiteralPath $Stamp -Value "built $(Get-Date -Format s)" -Encoding ascii
    }

    # -------------------------------------------------------------------------
    # Expand the filelist into absolute sources, include dirs and defines.
    # -------------------------------------------------------------------------
    $srcs = New-Object System.Collections.Generic.List[string]
    $incs = New-Object System.Collections.Generic.List[string]
    $defs = New-Object System.Collections.Generic.List[string]
    # Root of a filelist: relative paths in a filelist resolve against the tree it belongs to. A filelist
    # inside a copied third-party tree (an ancestor directory holding SOURCE.txt, e.g. third_party/rtlnet)
    # uses that tree's root, because upstream filelists are relative to their own repository root;
    # every other filelist uses this repository's root.
    function Get-FilelistRoot([string]$full) {
        $dir = Split-Path -Parent ((Resolve-Path -LiteralPath $full).Path)
        $repoFull = (Resolve-Path -LiteralPath $Repo).Path.TrimEnd('\')
        while ($dir -and $dir.Length -gt $repoFull.Length) {
            if (Test-Path -LiteralPath (Join-Path $dir 'SOURCE.txt')) { return $dir }
            $dir = Split-Path -Parent $dir
        }
        return $Repo
    }
    function Expand-Filelist([string]$path, [int]$depth, [string]$root) {
        if ($depth -gt 8) { throw "filelist nesting too deep at $path" }
        $full = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $root $path }
        if (-not (Test-Path -LiteralPath $full)) { throw "filelist not found: $path" }
        $root = Get-FilelistRoot $full
        foreach ($raw in Get-Content -LiteralPath $full) {
            $line = ($raw -replace '(#|//).*$', '').Trim()
            if (-not $line) { continue }
            # $VIVADO/<path>: a source inside the located Vivado install (e.g. an XPM macro the shared
            # vendor library does not hold), so filelists never carry an install path.
            if ($line -match '^\$VIVADO/(.+)$') { $line = To-Fwd (Join-Path $Vivado $Matches[1]) }
            if ($line -match '^-f\s+(.+)$') { Expand-Filelist $Matches[1].Trim() ($depth + 1) $root; continue }
            if ($line -match '^\+incdir\+(.+)$') {
                $d = $Matches[1]; $d = if ([System.IO.Path]::IsPathRooted($d)) { $d } else { Join-Path $root $d }
                if (-not $incs.Contains((To-Fwd $d))) { $incs.Add((To-Fwd $d)) }
                continue
            }
            if ($line -match '^\+define\+(.+)$') { $defs.Add($Matches[1]); continue }
            $s = if ([System.IO.Path]::IsPathRooted($line)) { $line } else { Join-Path $root $line }
            if (-not (Test-Path -LiteralPath $s)) { throw "source not found: $line (from $path)" }
            $s = To-Fwd ((Resolve-Path -LiteralPath $s).Path)
            if (-not $srcs.Contains($s)) { $srcs.Add($s) }
        }
    }
    Expand-Filelist $Filelist 0 $Repo
    foreach ($d in $Defines) { $defs.Add($d) }

    if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $designF = Join-Path $WorkDir 'design.f'
    Set-Content -LiteralPath $designF -Value ($srcs | ForEach-Object { '"' + $_ + '"' }) -Encoding ascii

    $incArgs = ($incs | ForEach-Object { '+incdir+"' + $_ + '"' }) -join ' '
    $defArgs = ($defs | ForEach-Object { '+define+' + $_ }) -join ' '
    $plus    = ($PlusArgs | ForEach-Object { '+' + $_ }) -join ' '
    $access  = if ($Waves) { '+access +r -asdb "' + (To-Fwd (Join-Path $WorkDir 'waves.asdb')) + '"' } else { '' }

    $do = @(
        'onerror {quit -code 2}',
        'alib work',
        ('amap xpm "' + (To-Fwd (Join-Path $XlibDir 'xpm/xpm.lib')) + '"'),
        ('amap unisims_ver "' + (To-Fwd (Join-Path $XlibDir 'unisims_ver/unisims_ver.lib')) + '"'),
        "alog -sv2k12 -dbg -timescale 1ns/1ps -work work $incArgs $defArgs -f design.f",
        "asim -t 1ps $access -L xpm -L unisims_ver work.$Bench unisims_ver.glbl $plus",
        'run -all',
        'endsim',
        'quit -code 0'
    )
    $macro = Join-Path $WorkDir 'run.do'
    Set-Content -LiteralPath $macro -Value $do -Encoding ascii

    $log = Join-Path $WorkDir 'simulation.log'
    $start = Get-Date
    $rc = Invoke-Vsimsa $WorkDir $macro $log $TimeoutSeconds
    $secs = [int]((Get-Date) - $start).TotalSeconds

    if (-not (Test-Path -LiteralPath $log) -or (Get-Item -LiteralPath $log).LastWriteTime -lt $start) {
        Write-Summary 'FAIL' "no fresh log (rc=$rc)"; exit 1
    }
    $text = Get-Content -LiteralPath $log -Raw
    $esc = [regex]::Escape($Bench)
    $passLine = [regex]::Match($text, "(?m)^(KERNEL:\s+)?TEST PASS:\s+$esc\b[^\r\n]*")
    $failLine = [regex]::Match($text, "(?m)^(KERNEL:\s+)?TEST FAIL:\s+$esc\b[^\r\n]*")
    $errLine  = [regex]::Match($text, "(?m)^(# )?(KERNEL: |RUNTIME: |ELAB2: |ELBREAD: |ALOG: |VSIM: )?(Fatal [Ee]rror|Error)[: ][^\r\n]*")

    if ($rc -eq -999) { Write-Summary 'FAIL' "timeout after $TimeoutSeconds s"; exit 1 }

    if ($ExpectFail) {
        if ($failLine.Success -and -not $passLine.Success) {
            Write-Summary 'PASS' ("expected failure seen: " + $failLine.Value.Trim() + " ($secs s)"); exit 0
        }
        Write-Summary 'FAIL' "negative control did not report TEST FAIL (rc=$rc)"; exit 1
    }

    if ($rc -ne 0) {
        $why = if ($errLine.Success) { $errLine.Value.Trim() } else { "simulator exit code $rc" }
        Write-Summary 'FAIL' "$why (log $log)"; exit 1
    }
    if ($failLine.Success) { Write-Summary 'FAIL' ($failLine.Value.Trim()); exit 1 }
    if ($errLine.Success)  { Write-Summary 'FAIL' ($errLine.Value.Trim() + " (log $log)"); exit 1 }
    if (-not $passLine.Success) { Write-Summary 'FAIL' "no anchored TEST PASS line (log $log)"; exit 1 }
    Write-Summary 'PASS' ($passLine.Value.Trim() + " ($secs s)")
    exit 0
}
finally {
    if ($null -ne $Lock) { $Lock.Dispose() }
}
