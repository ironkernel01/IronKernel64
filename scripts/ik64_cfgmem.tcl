# -----------------------------------------------------------------------------
# SPDX-License-Identifier: GPL-3.0-or-later
# File: ik64_cfgmem.tcl
# Purpose: write the QSPI flash image files with write_cfgmem (no hardware access): the bitstream at
#   flash offset 0 and the data blob (tools/mkqspi.py) at 0x1000000, for the Spansion S25FL256S (32 MiB,
#   SPIx4) of the Nexys Video. Writes <prefix>.mcs, <prefix>.bin and <prefix>.prm.
# Usage: vivado -mode batch -source ik64_cfgmem.tcl -tclargs <bitstream.bit> <data.bin> <out prefix>
#   Normally through scripts/make_qspi.ps1 and scripts/ik64_vivado.ps1. Prints "ik64_cfgmem:" lines.
# Exit codes: 0 written, 2 bad arguments or missing input, 3 write_cfgmem failed.
# Language: Tcl (Vivado 2026.1).
# Revision: 11-10-2026
#   * 11-10-2026: initial version.
# -----------------------------------------------------------------------------
if {[llength $argv] != 3} { puts "ik64_cfgmem: usage: -tclargs <bit> <data.bin> <out prefix>"; exit 2 }
lassign $argv bit data prefix
foreach f [list $bit $data] { if {![file exists $f]} { puts "ik64_cfgmem: ERROR missing $f"; exit 2 } }
set FLASH_DATA_OFS 0x01000000
if {[catch {
  write_cfgmem -force -format mcs -size 32 -interface SPIx4 \
    -loadbit [list up 0x00000000 $bit] \
    -loaddata [list up $FLASH_DATA_OFS $data] \
    -file ${prefix}.mcs
  write_cfgmem -force -format bin -size 32 -interface SPIx4 \
    -loadbit [list up 0x00000000 $bit] \
    -loaddata [list up $FLASH_DATA_OFS $data] \
    -file ${prefix}.bin
} err]} { puts "ik64_cfgmem: ERROR write_cfgmem: $err"; exit 3 }
puts "ik64_cfgmem: PASS ${prefix}.mcs ([file size ${prefix}.mcs] bytes), ${prefix}.bin ([file size ${prefix}.bin] bytes)"
exit 0
