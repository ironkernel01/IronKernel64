# Deviations from upstream reDIP-SID

IronKernel 64 compiles Dag Lem's reDIP-SID gateware (CERN-OHL-S-2.0) from
`third_party/redip-sid/ik64/`. That directory is generated, never edited by hand:
`python -I tools/setup_third_party.py` runs `tools/redip_patch.py` as a post step of the
"redip-sid" manifest entry and checks the SHA-256 of every generated file.
Upstream: https://github.com/daglem/reDIP-SID, commit `56608673b3a4e4f637afc026dca07ebdbf7d0769`
(unmodified copy in `third_party/redip-sid/gateware/`). Every changed file carries a notice
naming the date (2026-11-09), the deviation IDs and the original file (CERN-OHL-S-2.0 section 3.3).
Each site is tagged `IK64_DEVIATION Dn` (grep for it).

| ID | File | Change | Reason | Tool that needs it |
|----|------|--------|--------|--------------------|
| D1 | `sid_api.sv` | Remove `initial begin $dumpfile("sid_api.fst"); $dumpvars; end` | `$dumpvars` without `+access` errors (KERNEL_0085); with access it writes a ~500 MB .fst per bench run | Active-HDL 11.1 |
| D2 | `sid_filter.sv` | `unique0 case` -> `case` | `unique0` is a syntax error | Active-HDL 11.1 |
| D3 | all `.sv`/`.svh` (11 files) | `` `default_nettype none `` -> `` `default_nettype wire `` | ANSI `logic` ports in modules whose `#()` header holds only localparams are rejected (Synth 8-6735) while `none` is active | Vivado 2026.1 |
| D4 | `muladd.sv` (substituted, not edited) | `fpga/hdl/redip/muladd.sv` replaces upstream `muladd.sv`: same module name, ports and unregistered arithmetic, inferred DSP48E1 instead of the iCE40 `SB_MAC16` | `SB_MAC16` exists only on iCE40 | Active-HDL 11.1, Vivado 2026.1 |

Sites: D1, D2, D3 in `tools/redip_patch.py` (the `D1_OLD`, `D2_*`, `D3_*` constants, tagged);
D4 in `fpga/hdl/redip/muladd.sv` (header). Behaviour is unchanged by D1..D3; D4 is checked by
`fpga/tb/tb_sid_player.sv` against the reSID reference.
