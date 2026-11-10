<#
-------------------------------------------------------------------------------
SPDX-License-Identifier: GPL-3.0-or-later
File: ik64_vivado.ps1
Purpose: run one Vivado batch job of the IronKernel 64 project (build, synthesis
  check, hardware programming) with the machine-wide concurrency limit when the
  workstation coordination applies, and as a plain Vivado launch otherwise.
Overview:
  * scripts/ik64_tools.ps1 decides (Get-Ik64Coordination):
      - ironkernel/src present: the job goes through the shared slot launcher
        ironkernel/src/rtlnet/scripts/rtlnet_vivado.ps1 (vivado_slot<N>.lock in
        %LOCALAPPDATA%\RTLNet, a job waits for a free slot);
      - no ironkernel/src and no shared-machine folders: Vivado is started
        directly, no lock;
      - no ironkernel/src but a shared-machine folder exists: refuses (exit 2).
  * Runs vivado.bat -mode batch -nojournal -log <Log> -source <Tcl> -tclargs
    <TclArgs...> from <WorkDir> (default: the log's directory).
  * Prints "IK64_VIVADO: exit <rc> log <path>" and exits with Vivado's exit code
    (the Tcl scripts define their gates).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ik64_vivado.ps1 `
    -Tcl fpga/build_bitstream.tcl -Log build/fpga/build.log [-TclArgs tag=x] [-WorkDir <dir>]
Exit codes: Vivado's, 1 no slot within -WaitSeconds, 2 coordination guard.
Revision: 11-10-2026
  * 11-10-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Tcl,
    [Parameter(Mandatory = $true)][string]$Log,
    [string[]]$TclArgs = @(),
    [string]$WorkDir = '',
    [int]$MaxSlots = 2,
    [int]$WaitSeconds = 14400
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ik64_tools.ps1')
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$co = Assert-Ik64Coordination

$tclPath = if ([System.IO.Path]::IsPathRooted($Tcl)) { $Tcl } else { Join-Path $Repo $Tcl }
$logPath = if ([System.IO.Path]::IsPathRooted($Log)) { $Log } else { Join-Path $Repo $Log }

if ($co.Shared) {
    $splat = @{ Tcl = $tclPath; Log = $logPath; MaxSlots = $MaxSlots; WaitSeconds = $WaitSeconds }
    if ($TclArgs.Count -gt 0) { $splat['TclArgs'] = $TclArgs }
    if ($WorkDir) { $splat['WorkDir'] = $WorkDir }
    & $co.VivadoSlot @splat
    $rc = $LASTEXITCODE
    Write-Output ("IK64_VIVADO: exit {0} log {1} (shared slot launcher)" -f $rc, $logPath)
    exit $rc
}

$vivado = (Resolve-Ik64Xilinx).Vivado + '/bin/vivado.bat'
$logDir = Split-Path -Parent $logPath
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
if (-not $WorkDir) { $WorkDir = $logDir }
$argList = @('-mode', 'batch', '-nojournal', '-log', ($logPath -replace '\\', '/'), '-source', ($tclPath -replace '\\', '/'))
if ($TclArgs.Count -gt 0) { $argList += '-tclargs'; $argList += $TclArgs }
Push-Location $WorkDir
try {
    & $vivado @argList | Out-Null
    $rc = $LASTEXITCODE
} finally { Pop-Location }
Write-Output ("IK64_VIVADO: exit {0} log {1}" -f $rc, $logPath)
exit $rc
