<#
-------------------------------------------------------------------------------
File: ik64_board_lib.ps1
Purpose: shared helpers of the IronKernel 64 board scripts (ik64_board.ps1,
  program.ps1, jtag_load.ps1, board_release.ps1). Dot-source it; it is not run
  on its own.
Overview:
  * Sets the board-lock session name to 'ik64' ($env:RTLNET_BOARD_SESSION) and
    dot-sources third_party/rtlnet-board/scripts/rtlnet_board_lock.ps1 (the
    lock shared with session rtlnet-18). No script here takes the lock under
    another name.
  * Functions: Write-Ik64Final (the single IK64_BOARD line), Assert-Ik64ThirdParty
    (setup_third_party.py --check --only rtlnet-board), Assert-Ik64LockHeld
    (fresh lock of session ik64, else exit 2 with the take instruction),
    Get-Ik64Tools (Vivado/Vitis through third_party/rtlnet/scripts/rtlnet_tools.ps1).
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
$script:Ik64Repo  = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:Ik64Board = Join-Path $script:Ik64Repo 'third_party/rtlnet-board'
$env:RTLNET_BOARD_SESSION = 'ik64'

function Write-Ik64Final([string]$Verdict, [string]$What) {
    Write-Output ("IK64_BOARD: {0} {1}" -f $Verdict, $What)
}

function Assert-Ik64ThirdParty {
    $lockScript = Join-Path $script:Ik64Board 'scripts/rtlnet_board_lock.ps1'
    $py = 'python'
    $tools = Join-Path $script:Ik64Repo 'third_party/rtlnet/scripts/rtlnet_tools.ps1'
    if (Test-Path -LiteralPath $tools) {
        . $tools
        try { $py = Resolve-RtlnetPython } catch { $py = 'python' }
    }
    Push-Location $script:Ik64Repo
    try {
        $out = & $py -I tools/setup_third_party.py --check --only rtlnet-board 2>&1 | Out-String
        $rc = $LASTEXITCODE
    } finally { Pop-Location }
    if ($rc -ne 0 -or -not (Test-Path -LiteralPath $lockScript)) {
        Write-Output $out
        Write-Ik64Final 'FAIL' 'third_party rtlnet-board not installed (run: python -I tools/setup_third_party.py --only rtlnet-board)'
        exit 2
    }
}

function Assert-Ik64LockHeld {
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
    $tools = Join-Path $script:Ik64Repo 'third_party/rtlnet/scripts/rtlnet_tools.ps1'
    if (-not (Test-Path -LiteralPath $tools)) {
        Write-Ik64Final 'FAIL' 'third_party/rtlnet not installed (rtlnet_tools.ps1 missing)'
        exit 2
    }
    . $tools
    return (Resolve-RtlnetXilinx)
}

$script:Ik64LockScript = Join-Path $script:Ik64Board 'scripts/rtlnet_board_lock.ps1'
if (Test-Path -LiteralPath $script:Ik64LockScript) {
    . $script:Ik64LockScript
    $script:RtlnetSession = 'ik64'
}
