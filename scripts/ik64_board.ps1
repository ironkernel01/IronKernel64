<#
-------------------------------------------------------------------------------
File: ik64_board.ps1
Purpose: take, show or release the machine-wide Nexys Video board lock as
  session 'ik64' (the lock is shared with session rtlnet-18; see c64demo.md
  "Board and tool coordination").
Overview:
  * Sets $env:RTLNET_BOARD_SESSION='ik64' and uses the shared lock functions
    (ironkernel/src/rtlnet-board/scripts/rtlnet_board_lock.ps1, wrapped by
    scripts/ik64_board_lib.ps1: Enter-Ik64BoardLock -Purpose -ExpectedMinutes,
    Get-Ik64BoardLock, Exit-Ik64BoardLock). The lock is never taken under
    another session name and a foreign lock is never taken over. On a machine
    without ironkernel/src and without the shared-machine folders there is no
    lock to take (the commands report that and pass); with the folders but
    without ironkernel/src the script refuses (exit 2).
  * take: takes or reuses the lock. Refused (foreign fresh lock): prints the
    RTLNET_BOARD_LOCK: FAIL line, then the IK64_BOARD: FAIL line, exit 3.
  * release: removes the lock when it belongs to ik64.
  * show: prints the lock and its state.
  * $env:RTLNET_BOARD_LOCK overrides the lock path (tests only).
  * Prints one final line IK64_BOARD: PASS|FAIL <what>.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ik64_board.ps1 take [-Purpose <text>] [-ExpectedMinutes <n>]
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ik64_board.ps1 show
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ik64_board.ps1 release
Exit codes: 0 ok, 2 setup error (ironkernel/src missing on a coordinated machine), 3 lock refused.
Revision: 11-09-2026
  * 11-09-2026: initial version.
  * 11-10-2026: lock helpers from ironkernel/src, no RTLNet board tree under third_party.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet('take', 'release', 'show')][string]$Command,
    [string]$Purpose = 'ik64 board session',
    [int]$ExpectedMinutes = 60
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ik64_board_lib.ps1')
Assert-Ik64Setup

switch ($Command) {
    'take' {
        # Refuse up front so the final line is still printed (Enter-Ik64BoardLock exits the script).
        $l = Get-Ik64BoardLock
        if ($null -ne $l -and $l.State -eq 'fresh' -and $l.session -ne 'ik64') {
            Write-Output ("RTLNET_BOARD_LOCK: FAIL board is held by session '{0}' (purpose '{1}', start {2}, pid {3}); not waiting, not taking over" -f
                $l.session, $l.purpose, $l.start, $l.pid)
            Write-Ik64Final 'FAIL' ("board is held by session '{0}'" -f $l.session)
            exit 3
        }
        Enter-Ik64BoardLock -Purpose $Purpose -ExpectedMinutes $ExpectedMinutes
        Write-Ik64Final 'PASS' "lock taken by ik64 ($Purpose, $ExpectedMinutes min)"
    }
    'release' {
        Exit-Ik64BoardLock
        $l = Get-Ik64BoardLock
        if ($null -ne $l -and $l.session -eq 'ik64') { Write-Ik64Final 'FAIL' 'lock of ik64 still present'; exit 1 }
        Write-Ik64Final 'PASS' 'ik64 holds no lock'
    }
    'show' {
        $l = Get-Ik64BoardLock
        if ($null -eq $l) { Write-Output 'RTLNET_BOARD_LOCK: none'; Write-Ik64Final 'PASS' 'no lock' }
        else {
            Write-Output ("RTLNET_BOARD_LOCK: session={0} purpose='{1}' start={2} expected_minutes={3} pid={4} host={5} state={6}{7}" -f
                $l.session, $l.purpose, $l.start, $l.expected_minutes, $l.pid, $l.host, $l.State,
                $(if ($l.Reason) { " ($($l.Reason))" } else { '' }))
            Write-Ik64Final 'PASS' ("lock held by {0} ({1})" -f $l.session, $l.State)
        }
    }
}
exit 0
