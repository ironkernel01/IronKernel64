# AGENTS.md: working on IronKernel 64 with an AI coding agent

This file is for AI coding agents (Claude Code, Codex and others) and for people who work with one. It lists what to read, how to build and test, the rules the tree enforces, and where a new feature goes. `CLAUDE.md` points here. The full design is in `Documentation/ironkernel64_spec.md`; read its sections 4 (architecture), 7 (registers), 8 (drive protocol) and 10 (build) before changing code in those areas.

Revision 11-10-2026.

## What the system is

A Nexys Video (Artix-7 XC7A200T) with two MicroBlaze V (RISC-V) cores:

- Core 0, "C64" (`fw_c64/`, 256 KiB LMB, no RTOS): screen editor, BASIC-like shell, 6502 interpreter, PSID player, video, audio, OLED, keyboard and the engineering CLI.
- Core 1, "1541" (`fw_1541/`, runs from DDR3, no RTOS): a disk drive. Device 8 is an SMB share (lwIP + libsmb2), device 9 is the built-in tune bank in DDR3.
- The cores talk through a mailbox in shared BRAM (`common/drive_proto.h`).
- Core 0 sends SID register writes with their cycle stamps to `sid_player` in fabric, which drives reDIP-SID at 985,248 Hz. `sid_audio_out` sends 48 kHz audio to the ADAU1761.

## Repository map

| Path | Content |
|---|---|
| `fpga/hdl/` | project RTL (SystemVerilog): `c64_top`, `c64_pkg` (register constants), `sid_player`, `sid_audio_out`, `c64_video`, `dvi_tx`, `c64_oled`, `ps2_rx`, `c64_sysregs`, `common/` (synchronisers, AXI-Lite) |
| `fpga/tb/` | self-checking benches, one `.f` file list each; `regression.txt` lists the regression |
| `fpga/bd/c64_bd.tcl`, `fpga/ip/` | block design (both cores, DDR3, AXI) and IP settings |
| `fpga/netlist/` | closed network core `ik64_net_core.dcp` and its interface document |
| `fpga/build_bitstream.tcl`, `fpga/c64.xdc` | bitstream build with its gates, constraints |
| `fw_c64/src/` | core 0 firmware: `main.c`, `basic.c`, `cpu6502.c`, `psid.c`, `player.c`, `sid*.c`, `video.c`, `oled*.c`, `keyboard.c`, `drive_client.c`, `cli*.c` |
| `fw_c64/cli/` | engineering CLI generated from `cli_commands.txt` by `tools/gen_cli_menu.py` |
| `fw_1541/src/` | core 1 firmware: `main.c`, `drive_server.c`, `cbmdos.c`, `backend_smb.c`, `backend_ram.c`, `bank_format.c`, `netshare.h` |
| `fw_1541/boot/` | core 1 flash bootloader (copies the firmware and the bank from QSPI to DDR3) |
| `fw_1541/lib/`, `fw_1541/net/` | closed network library `libik64_netcore.a` with its header, lwIP options |
| `common/` | headers shared by both cores: `drive_proto.h`, `c64_platform.h` |
| `bank/public/` | the device 9 tunes as text scores |
| `tools/` | generators, checkers, host tests (`*_host_test.c`), `uart_capture.py`, setup scripts |
| `scripts/` | Vivado, simulation, programming and flash-image scripts |
| `Documentation/` | specification and product brief (`.md` sources, `.pdf` built by `build_pdf.ps1`) |
| `diagrams/` | block-diagram sources (`src/*.js`) and rendered PNGs |
| `third_party/` | not committed: `tools/setup_third_party.py` installs it |

## Set up a checkout

1. Vivado and Vitis 2026.1 at `C:\AMDDesignTools\2026.1` (`scripts/ik64_tools.ps1` finds other install roots). Python 3. MSYS2 with the UCRT64 GCC at `C:\msys64` for the host tests and Verilator.
2. `python -I tools/setup_third_party.py` installs reDIP-SID, reSID, libsmb2, Open ROMs and the Dormann tests at the commits pinned in `tools/third_party.json`. Every build script runs `--check` first and stops when a tree differs.
3. Copy `fw_1541/netshare_config.example.h` to `fw_1541/netshare_config.h` and fill it in to use device 8. It is gitignored. Without it, build core 1 with `-Public`.

`tools/setup_ironkernel.py` and the `ironkernel/` folder belong to the owner's private network-core sources and are not needed: the netlist and the library are committed prebuilt. The board-lock and Vivado-slot scripts (`scripts/ik64_board.ps1`, `ik64_vivado.ps1`) run without locks on a machine that has neither `ironkernel/src` nor the shared-machine folders under `%LOCALAPPDATA%`.

## Build

All PowerShell commands: `powershell -NoProfile -ExecutionPolicy Bypass -File <script>`. Each script prints one final `PASS`/`FAIL` line and documents its exit codes in its header.

| Step | Command | Output |
|---|---|---|
| Bitstream (about 45 min) | `scripts/ik64_vivado.ps1 -Tcl fpga/build_bitstream.tcl -Log build/fpga/build.log` | `build/fpga/`: `.bit`, `.mmi`, `.xsa`, `build_info.txt` |
| Core 0 | `fw_c64/build.ps1` | `build/fw_c64/c64.elf` |
| Core 1 | `fw_1541/build.ps1` or `fw_1541/build.ps1 -Public` | `build/fw_1541/` or `build/fw_1541_public/` |
| Core 1 bootloader | `fw_1541/boot/build.ps1` | `build/fw_1541_boot/` |
| Tune bank | `python -I tools/mkpublicbank.py` | `build/bank/public.bin` and one `.sid` per tune |
| Flash image | `scripts/make_qspi.ps1` | `build/qspi/ik64_qspi.mcs`, `.bin`, `c64_qspi.bit` |

Firmware-only changes do not need a new bitstream: `make_qspi.ps1` merges the new core 0 ELF and bootloader into the existing bitstream through the MMI.

## Test before every commit

| Changed | Run | Must print |
|---|---|---|
| any firmware | `scripts/ik64_host_tests.sh` | `IK64_HOST_TESTS: 12 passed, 0 failed` |
| `c64_pkg.sv` or `c64_regs.h` | `python -I tools/regs_check.py` (also run by `fw_c64/build.ps1`) | `REGS_CHECK: PASS` |
| RTL | `scripts/ik64_regression.ps1` (Active-HDL) | `IK64_REGRESSION: n passed, 0 failed` |
| `sid_player` or reDIP-SID wiring, without Active-HDL | `scripts/ik64_run_verilator.sh` | `TEST PASS: tb_sid_player` |
| anything in the bitstream | the bitstream build | final PASS (WNS, WHS, CDC, latch, utilisation gates) |
| tunes, credits, third-party items | `python -I tools/check_credits.py` | `check_credits: n checks, 0 missing` |

A new test is self-checking: it prints an anchored `TEST PASS: <name>` or `TEST FAIL: <name>` line, and it accepts `+INJECT_FAILURE`, which must make it fail (the negative control). A new host test goes into `scripts/ik64_host_tests.sh`; a new bench goes into `fpga/tb/regression.txt`.

## Rules the tree enforces

- Credentials: `fw_1541/netshare_config.h` is never committed, printed or logged. Release images are built with `fw_1541/build.ps1 -Public`, which compiles only the placeholders and fails (exit 42) when a value of the local `netshare_config.h` is found in the ELF.
- `third_party/` is never edited. A change to third-party code is a patch applied by a script plus an entry in `fpga/DEVIATIONS.md` or `fw_1541/DEVIATIONS.md`. A new third-party item goes into `tools/third_party.json` with a note in `tools/third_party/`, then `python -I tools/setup_third_party.py --update-hashes`. Editing a `.SOURCE.txt` note also needs a setup run, or the `--check` guard fails.
- The closed parts (`fpga/netlist/ik64_net_core.dcp`, `fw_1541/lib/libik64_netcore.a`) are used unmodified through `fpga/netlist/ik64_net_core.md` and `fw_1541/lib/ik64_netcore.h`. `fw_1541/net/lwipopts.h` is locked to the SHA-256 the library was built with.
- Core 0 fits in 256 KiB of LMB with text, data and bss together (96 % used). Check the size line of `fw_c64/build.ps1` after a change; it fails with exit 41 when the image does not fit.
- C: C11, `-Wall -Wextra -Werror -pedantic`, no warnings. Every file starts with an SPDX line and a header comment (role, usage, revision `MM-DD-YYYY`).
- RTL: synchronous resets only (the regression's reset-policy scan lists the named exceptions), lowercase port names taken from the Digilent master XDC with interface-role prefixes, `_n` for active-low, every clock-domain crossing through the `fpga/hdl/common` synchronisers.
- Register constants live in `fpga/hdl/c64_pkg.sv`; `fw_c64/src/c64_regs.h` mirrors them exactly.
- The drive mailbox format is `common/drive_proto.h`, used by both cores; change both sides together.
- Documents: present tense, dates `MM-DD-YYYY`. After a change to `Documentation/*.md`, rebuild the PDF with `Documentation/build_pdf.ps1 <name>` and commit both.
- Tunes from HVSC and C64 ROM images are never committed (`.gitignore`).

## Where a feature goes

| Feature | Files | Check |
|---|---|---|
| BASIC command or wedge | `fw_c64/src/basic.c` | `np_switch_host_test`, board |
| CLI command | `fw_c64/cli/cli_commands.txt`, then `python -I tools/gen_cli_menu.py`, handler in `fw_c64/src/cli_cmds.c` | `cli_menu_host_test` |
| New drive command or DOS behaviour | `fw_1541/src/cbmdos.c`, `common/drive_proto.h` if the mailbox changes, `fw_c64/src/drive_client.c` | `cbmdos_host_test`, `bank_host_test` |
| New storage backend | `fw_1541/src/backend.h` interface, a new `backend_*.c` next to `backend_ram.c` and `backend_smb.c` | a host test in the style of `bank_host_test.c` |
| Device 9 tune | `bank/public/<name>.txt` (score format: any existing file), public-domain composition only | `public_bank_test.py`, `sid_host_test` |
| Now-playing screen, OLED | `fw_c64/src/player.c`, `c64screen.c`, `np_piano.c`, `oled_ui.c` | `c64screen_overlay_host_test`, `np_piano_host_test`, `oled_host_test` |
| PSID player | `fw_c64/src/psid.c`, `cpu6502.c`, `c64mem.c` | `psid_cia_host_test`, `sid_host_test` |
| Hardware register or block | RTL in `fpga/hdl/`, constant in `c64_pkg.sv` and `c64_regs.h`, address in `fpga/bd/c64_bd.tcl`, a bench in `fpga/tb/` | `regs_check.py`, regression, bitstream gates |

Update the matching section of the specification (commands: section 9, registers: section 7, protocol: section 8) in the same change.

## Run it on the board

- Flash the image: `scripts/program_qspi.ps1 -Program build/qspi/ik64_qspi.mcs`, set jumper JP4 to "SPI Flash", press PROG; `-Reboot` reconfigures from the flash without a power cycle.
- JTAG development flow: `scripts/program.ps1`, then `scripts/jtag_load.ps1 -Core 1 -Bank build/bank/public.bin`.
- UART: 115200 8N1, no flow control. The USB-UART is usually COM3 on Windows. Everything on the screen is mirrored there, so an agent can drive the system without a keyboard:

```
python tools/uart_capture.py --port COM3 --seconds 10 --out build/u.log --send 'LOAD"$",9\r' --expect "READY\."
python tools/uart_capture.py --port COM3 --seconds 10 --out build/u.log --send 'LIST\r' --expect "BLOCKS FREE"
python tools/uart_capture.py --port COM3 --seconds 10 --out build/u.log --send 'LOAD"CANON",9\r' --expect "READY\."
python tools/uart_capture.py --port COM3 --seconds 30 --out build/u.log --send 'RUN\r'
python tools/uart_capture.py --port COM3 --seconds 4  --out build/u.log --send '\x1b' --expect "READY\."
```

ESC breaks a playing tune to `READY.`; Ctrl-B (`\x02`) opens the engineering CLI (`help`, `version`, `exit`). Core 1's log lines carry a `[1541]` prefix on the same UART. Only one program may hold the COM port at a time.

`Appendix C` of the specification describes the owner's machine, where the board is shared with another project through lock files. On any other machine the lock steps do nothing.
