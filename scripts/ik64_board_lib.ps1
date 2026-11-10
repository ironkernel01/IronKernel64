<#
-------------------------------------------------------------------------------
File: ik64_board_lib.ps1
Purpose: shared helpers of the IronKernel 64 board scripts (ik64_board.ps1,
  program.ps1, jtag_load.ps1, board_release.ps1). Dot-source it; it is not run
  on its own.
Overview:
  * Dot-sources scripts/ik64_tools.ps1 (tool resolvers and the coordination
    guard). With the private ironkernel/src tree present it sets the board-lock
    session name to 'ik64' ($env:RTLNET_BOARD_SESSION) and dot-sources
    ironkernel/src/rtlnet-board/scripts/rtlnet_board_lock.ps1 (the lock shared
    with session rtlnet-18). No script here takes the lock under another name.
    On a machine without ironkernel/src and without the shared-machine folders
    the lock functions are no-ops (there is nobody to share the board with);
    on a machine with the folders but without ironkernel/src every script
    refuses (exit 2).
  * Functions: Write-Ik64Final (the single IK64_BOARD line), Assert-Ik64Setup
    (coordination guard + setup_ironkernel.py --check when shared),
    Get-Ik64BoardLock / Enter-Ik64BoardLock / Exit-Ik64BoardLock (shared lock
    or no-op), Assert-Ik64LockHeld (fresh lock of session ik64, else exit 2
    with the take instruction; passes without a shared lock), Get-Ik64Tools
    (Vivado/Vitis install).
Revision: 11-10-2026
  * 11-09-2026: initial version.
  * 11-10-2026: release split: no RTLNet trees under third_party; tool resolvers from
    ik64_tools.ps1, lock helpers from ironkernel/src/rtlnet-board when present,
    otherwise no-op locks; refusal when the shared-machine folders exist but
    ironkernel/src is missing.
-------------------------------------------------------------------------------
#>
. (Join-Path $PSScriptRoot 'ik64_tools.ps1')
$script:Ik64Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:Ik64Co = $null
$script:Ik64CoErr = $null
$env:RTLNET_BOARD_SESSION = 'ik64'
try { $script:Ik64Co = Get-Ik64Coordination } catch { $script:Ik64CoErr = $_.Exception.Message }
# The lock helpers are dot-sourced here, at the lib's own scope, so their functions stay visible to the caller.
if ($null -ne $script:Ik64Co -and $script:Ik64Co.Shared) {
    . $script:Ik64Co.BoardLock
    $script:RtlnetSession = 'ik64'
}

function Write-Ik64Final([string]$Verdict, [string]$What) {
    Write-Output ("IK64_BOARD: {0} {1}" -f $Verdict, $What)
}

# Coordination guard; exits 2 with the IK64_BOARD line when the machine takes part in the
# shared coordination but ironkernel/src is missing.
function Assert-Ik64Setup {
    if ($null -ne $script:Ik64CoErr) {
        Write-Output $script:Ik64CoErr
        Write-Ik64Final 'FAIL' 'shared-machine folders exist but ironkernel/src is missing (run: python -I tools/setup_ironkernel.py)'
        exit 2
    }
    if (-not $script:Ik64Co.Shared) { return }
    $py = 'python'
    try { $py = Resolve-Ik64Python } catch { $py = 'python' }
    Push-Location $script:Ik64Repo
    try {
        $out = & $py -I tools/setup_ironkernel.py --check 2>&1 | Out-String
        $rc = $LASTEXITCODE
    } finally { Pop-Location }
    if ($rc -ne 0) {
        Write-Output $out
        Write-Ik64Final 'FAIL' 'ironkernel/src does not match tools/ironkernel.json (run: python -I tools/setup_ironkernel.py)'
        exit 2
    }
}

function Get-Ik64BoardLock {
    if ($null -eq $script:Ik64Co -or -not $script:Ik64Co.Shared) { return $null }
    return (Get-RtlnetBoardLock)
}

function Enter-Ik64BoardLock([string]$Purpose, [int]$ExpectedMinutes) {
    if ($null -eq $script:Ik64Co -or -not $script:Ik64Co.Shared) {
        Write-Output 'IK64_BOARD: no shared-machine coordination on this machine; no board lock taken'
        return
    }
    Enter-RtlnetBoardLock -Purpose $Purpose -ExpectedMinutes $ExpectedMinutes
}

function Exit-Ik64BoardLock {
    if ($null -eq $script:Ik64Co -or -not $script:Ik64Co.Shared) { return }
    Exit-RtlnetBoardLock
}

function Assert-Ik64LockHeld {
    if ($null -eq $script:Ik64Co -or -not $script:Ik64Co.Shared) { return }
    $l = Get-RtlnetBoardLock
    if ($null -ne $l -and $l.session -eq 'ik64' -and $l.State -eq 'fresh') { return }
    $why = 'no board lock is held'
    if ($null -ne $l) { $why = "lock is held by session '$($l.session)' (state $($l.State))" }
    Write-Output "ik64 does not hold the board lock: $why."
    Write-Output 'Run first: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ik64_board.ps1 take -Purpose "<what>" -ExpectedMinutes <n>'
    Write-Ik64Final 'FAIL' 'board lock not held by ik64 (run scripts/ik64_board.ps1 take first)'
    exit 2
}

function Get-Ik64Tools {
    try { return (Resolve-Ik64Xilinx) }
    catch {
        Write-Ik64Final 'FAIL' $_.Exception.Message
        exit 2
    }
}
