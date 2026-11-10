# libik64_netcore (core 1 network library)

`libik64_netcore.a` is the closed network library of core 1 ("1541" drive firmware): the network
bring-up, link and lease monitor, the drivers of the network core and the DMA netif of lwIP. It is
prebuilt; its sources are not in this repository.

| File | What it is |
|---|---|
| `libik64_netcore.a` | RISC-V (rv32imc + Zicsr, ilp32) relocatable object in an archive. Debug info stripped; 7 global symbols, all others local. |
| `ik64_netcore.h` | The interface: `ik64_net_init`, `ik64_net_service`, `ik64_net_delay_ms`, `ik64_net_status`, `ik64_uptime_ms64`, their types and the node MAC. |
| `ik64_netcore.symbols` | The 7 exported names (the four network calls, `ik64_uptime_ms64`, lwIP's `sys_now`, newlib's `_gettimeofday`). |
| `ik64_netcore.lwipopts.sha256` | SHA-256 of the `fw_1541/net/lwipopts.h` the library was compiled with. |

## Contents

It drives the network core described in `fpga/netlist/ik64_net_core.md` (MAC, PHY over MDIO, protocol
wrapper with the node MAC address, DHCP leaf, CPU-path classifier and checksum offload, AXI DMA) and
starts lwIP on it. The address configuration comes from the caller (`ik64_net_config_t`); the library
holds no credentials.

## What it needs from the firmware

- `drive_log_write`, `drive_log_printf` and `ik64_fatal` from `fw_1541/src`.
- lwIP 2.2.0 (NO_SYS=1) from the Vitis install and the standalone BSP (AXI DMA and timer drivers, caches).
- `fw_1541/net/lwipopts.h` unchanged: the library depends on its `struct pbuf` and `struct netif`
  layouts and on the checksum and zero-copy options. `fw_1541/build.ps1` stops with exit 4 when the
  file's SHA-256 differs from `ik64_netcore.lwipopts.sha256`.

## Using it

`fw_1541/build.ps1` links it (`-lik64_netcore`) and compiles `fw_1541` against `ik64_netcore.h`.
Nothing else is needed on a machine without the network sources.

## Rebuilding

Needs the private `ironkernel/` repository, the RTLNet source trees and the core 1 BSP:

    python -I tools/setup_ironkernel.py
    powershell -NoProfile -ExecutionPolicy Bypass -File fw_1541/build.ps1          (creates the BSP)
    powershell -NoProfile -ExecutionPolicy Bypass -File ironkernel/build_fwlib.ps1

`ironkernel/build_fwlib.ps1` compiles with the same toolchain and flags as `fw_1541/build.ps1`
(`-Os -g -ffunction-sections -fdata-sections -std=c11 -Wall -Wextra -Werror`), combines the objects with
`ld -r`, strips debug info, localizes every symbol outside `ik64_netcore.symbols`, archives the result and
records the `lwipopts.h` hash.

## Licensing

OWNER TO CONFIRM: the library is distributed as a binary for use with IronKernel 64. The GPL parts of
the firmware link to it under the exception recorded in the root README.md (`c64demo.md`, "Release split").
libsmb2 (LGPL-2.1) stays relinkable: its objects are built from `third_party/libsmb2` and linked
separately from this archive.
