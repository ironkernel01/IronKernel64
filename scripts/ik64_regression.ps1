<#
-------------------------------------------------------------------------------
File: ik64_regression.ps1
Purpose: run the IronKernel 64 RTL regression: the reset-policy gate first,
  then every bench listed in fpga/**/regression.txt through ik64_run_sim.ps1,
  sequentially (one Active-HDL seat), and fail if any step fails.
Overview:
  * Reset-policy gate (fpga.md section 16): scans every project RTL file under
    fpga/hdl for a clocked always/always_ff whose sensitivity list holds a
    second edge (asynchronous reset or set). Allowed exceptions are listed by
    exact file name in $ResetExceptions, each with its reason. third_party/ is
    vendor/sibling code and is not scanned (fpga.md section 19). The gate
    prints `TEST PASS: reset_policy` or `TEST FAIL: reset_policy` and counts as
    one regression entry.
  * Line format of regression.txt (same as RTLNet):
      <bench> <filelist> [tag] [defines=A,B] [plusargs=X,Y] [expectfail]
  * Prints `IK64_REGRESSION: <n> passed, <m> failed` and exits 0 only when
    every entry passed and at least one bench ran.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ik64_regression.ps1 [-Match <regex>]
Revision: 11-09-2026
  * 11-09-2026: initial version, derived from RTLNet scripts/rtlnet_regression.ps1.
  * 11-09-2026: setup guard (tools/setup_third_party.py --check) before anything runs.
-------------------------------------------------------------------------------
#>
param([string]$Match = '.')
$ErrorActionPreference = 'Stop'
$Repo   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Runner = Join-Path $PSScriptRoot 'ik64_run_sim.ps1'

# Setup guard: pinned third-party trees must match tools/third_party.json.
$guard = & python -I (Join-Path $Repo 'tools/setup_third_party.py') --check 2>&1
if ($LASTEXITCODE -ne 0) {
    $guard | ForEach-Object { Write-Output "$_" }
    Write-Output 'IK64_REGRESSION: third-party setup check failed; run: python -I tools/setup_third_party.py'
    exit 2
}

# Files allowed to hold a two-edge sensitivity list:
#   ik64_reset_sync.sv -- the reset bridge: asynchronous assert, synchronous release
#   (fpga.md section on reset synchronizers), the only async-reset flops in ik64 RTL.
$ResetExceptions = @('ik64_reset_sync.sv')

$pass = 0; $fail = 0; $failed = @()

# -----------------------------------------------------------------------------
# Reset-policy gate.
# -----------------------------------------------------------------------------
$hits = @()
$rtl = @(Get-ChildItem -Path (Join-Path $Repo 'fpga/hdl') -Recurse -Include *.sv, *.v -ErrorAction SilentlyContinue)
$rx = [regex]'always(_ff)?\s*@\s*\([^)]*(posedge|negedge)[^)]*(,|\bor\b)[^)]*(posedge|negedge)'
foreach ($f in $rtl) {
    if ($ResetExceptions -contains $f.Name) { continue }
    $n = 0
    foreach ($l in Get-Content -LiteralPath $f.FullName) {
        $n++
        if ($rx.IsMatch($l)) { $hits += "$($f.FullName):$n  $($l.Trim())" }
    }
}
if ($rtl.Count -eq 0) {
    Write-Output 'TEST FAIL: reset_policy (no RTL files found under fpga/hdl)'
    $fail++; $failed += 'reset_policy'
} elseif ($hits.Count -gt 0) {
    Write-Output 'TEST FAIL: reset_policy'
    $hits | ForEach-Object { Write-Output "  $_" }
    $fail++; $failed += 'reset_policy'
} else {
    Write-Output ("TEST PASS: reset_policy ({0} files scanned)" -f $rtl.Count)
    $pass++
}

# -----------------------------------------------------------------------------
# Benches.
# -----------------------------------------------------------------------------
$list = @()
foreach ($f in (Get-ChildItem -Path (Join-Path $Repo 'fpga') -Recurse -Filter regression.txt -ErrorAction SilentlyContinue | Sort-Object FullName)) {
    $list += Get-Content -LiteralPath $f.FullName
}
$benches = 0
foreach ($raw in $list) {
    $line = ($raw -replace '#.*$', '').Trim()
    if (-not $line) { continue }
    $tok = $line -split '\s+'
    $bench = $tok[0]; $fl = $tok[1]
    if ("$bench $line" -notmatch $Match) { continue }
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Runner, '-Bench', $bench, '-Filelist', $fl)
    foreach ($t in $tok[2..($tok.Count - 1)]) {
        if (-not $t) { continue }
        if ($t -like 'defines=*')      { $runArgs += @('-Defines', ($t.Substring(8))) }
        elseif ($t -like 'plusargs=*') { $runArgs += @('-PlusArgs', ($t.Substring(9))) }
        elseif ($t -eq 'expectfail')   { $runArgs += '-ExpectFail' }
        elseif ($t -ne $fl)            { $runArgs += @('-Tag', $t) }
    }
    $benches++
    $out = & powershell.exe @runArgs
    $out | Select-Object -Last 1 | Write-Output
    if ($LASTEXITCODE -eq 0) { $pass++ } else { $fail++; $failed += "$bench $($tok[2..($tok.Count-1)] -join ' ')" }
}
Write-Output ("IK64_REGRESSION: {0} passed, {1} failed" -f $pass, $fail)
foreach ($f in $failed) { Write-Output "  FAILED: $f" }
if ($fail -ne 0 -or $benches -eq 0) { exit 1 }
exit 0
