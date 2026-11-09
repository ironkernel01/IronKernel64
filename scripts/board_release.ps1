<#
-------------------------------------------------------------------------------
File: board_release.ps1
Purpose: alias for `ik64_board.ps1 release` (release the Nexys Video board lock
  held by session ik64).
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_release.ps1
Exit codes: as ik64_board.ps1. Final line IK64_BOARD: PASS|FAIL <what>.
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
& (Join-Path $PSScriptRoot 'ik64_board.ps1') release
exit $LASTEXITCODE
