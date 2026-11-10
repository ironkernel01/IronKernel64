# ik64_net_core: network core netlist

Revision 11-10-2026

`ik64_net_core` is the Ethernet network core of IronKernel 64: an RGMII MAC with its pin layer, the PHY
management (MDIO) core, and a protocol wrapper with ARP, ICMP, DHCP and iperf leaves and a CPU path
(frame classifier, checksum offload). It ships as a synthesized netlist, `ik64_net_core.dcp`, with a
readable port stub, `ik64_net_core_stub.sv`, and this document. The RTL behind the netlist is not part of
the distribution.

**The netlist is name-scrambled, not encrypted.** It opens in any Vivado 2026.1 or newer without a key. Its
hierarchy is flattened and every cell and net carries an opaque name (`c_<n>`, `n_<n>`, `m_<n>`); the RTL
file names, line numbers and register names that synthesis stores on cells and nets are removed. The ports
keep their names. An outsider sees the device primitives (LUTs, flip-flops, block RAM, DSP, IDELAY, IDDR,
ODDR) and the wiring between them. An IEEE-1735 encrypted checkpoint with the same ports may replace this
file later; the top level is unaffected (section 7).

| File | Content |
|---|---|
| `ik64_net_core.dcp` | Vivado 2026.1 design checkpoint, out-of-context synthesis for `xc7a200tsbg484-1`, flattened, cell and net names scrambled, constraints inside. |
| `ik64_net_core_stub.sv` | Black-box declaration of `ik64_net_core` (ports, widths, directions). |
| `ik64_net_core.md` | This interface description. |

## 1. Contents and fixed configuration

| Block | Function | Fixed configuration |
|---|---|---|
| MAC | RGMII 10/100/1000 MAC, receive and transmit packet FIFOs, receive clock rate monitor, input delay and DDR pin cells | 8 KiB receive FIFO, 8 KiB transmit FIFO, largest client frame 1518 bytes (FCS excluded), receive data delay 12 taps |
| MDIO | MDC/MDIO bit-bang port, PHY reset hold, PHY interrupt input | 100 MHz register clock, PHY reset held 20 ms after reset release |
| Protocol | Ingress filter and queues, ARP, ICMP echo, DHCP client, iperf server leaves, CPU path with classifier and checksum offload | Leaves at 50 MHz, ingress queue 16 KiB, egress queue 8 KiB, CPU receive FIFO 16 KiB, CPU transmit FIFO 8 KiB, iperf port 5001, socket layer not built |

The MAC client streams connect the MAC to the protocol wrapper inside the core. The socket layer is not
built, so the core has no application stream ports.

## 2. Ports

All signals are `logic`. Resets are active low and synchronous to the clock of their name.

### 2.1 Clocks and resets

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk125` | in | 1 | 125 MHz, MAC transmit clock |
| `clk125_90` | in | 1 | 125 MHz, 90 degrees behind `clk125` (2 ns), forwarded as RGMII TXC |
| `clk200` | in | 1 | 200 MHz, IDELAYCTRL reference |
| `axis_clk` | in | 1 | 62.5 MHz, MAC client side and protocol ingress filter |
| `cpu_clk` | in | 1 | 100 MHz, AXI4-Lite registers, CPU streams, MDIO core |
| `sid_clk` | in | 1 | 50 MHz, protocol leaves |
| `clk125_resetn` | in | 1 | reset for `clk125` and `clk125_90` |
| `clk200_resetn` | in | 1 | reset for `clk200` (drives the IDELAYCTRL reset) |
| `axis_resetn` | in | 1 | reset for `axis_clk` |
| `cpu_resetn_sync` | in | 1 | reset for `cpu_clk` |
| `sid_resetn` | in | 1 | reset for `sid_clk` |

The six clocks come from one MMCM. The five resets are released from one common assertion, because the
packet FIFOs and clock-crossing bundles need both of their sides out of reset together. The receive clock
`eth_rxck` enters at the pin (125 MHz at 1 Gb/s, 25 MHz at 100 Mb/s, 2.5 MHz at 10 Mb/s); the core derives
its receive domain from it with a BUFIO and a BUFR.

### 2.2 RGMII and PHY pins (Realtek RTL8211E, 2.5 V)

| Port | Dir | Width | Description |
|---|---|---|---|
| `eth_rxck` | in | 1 | RGMII receive clock. Must be a clock-capable pin in the bank of `eth_rxd` and `eth_rxctl`. |
| `eth_rxctl` | in | 1 | RX_CTL, DDR |
| `eth_rxd` | in | 4 | RXD, DDR |
| `eth_txck` | out | 1 | RGMII transmit clock, 90 degrees after the data edges at 1 Gb/s |
| `eth_txctl` | out | 1 | TX_CTL, DDR |
| `eth_txd` | out | 4 | TXD, DDR |
| `eth_mdc` | out | 1 | MDIO clock |
| `mdio_o`, `mdio_t`, `mdio_i` | out, out, in | 1 | MDIO data line: the I, T and O pins of an IOBUF in the top (`mdio_t` = 1 releases the line; `mdio_i` is asynchronous) |
| `eth_rst_b` | out | 1 | PHY reset, active low, low until the MDIO core releases it |
| `eth_int_b` | in | 1 | PHY interrupt, active low, asynchronous |

The core contains the input buffers (IBUF) of `eth_rxck`, `eth_rxctl` and `eth_rxd`. The top sets
`IO_BUFFER_TYPE` to `none` on those six ports so that it does not add a second buffer. The top adds the
output buffers of all outputs and the IOBUF of the MDIO line. The PHY needs its RX delay enabled over MDIO
(register write by the firmware); the receive timing assumes it.

### 2.3 Register slots (AXI4-Lite slaves, `cpu_clk`)

Three slaves, each with ports `s_axi_<slot>_{awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bresp,
bvalid, bready, araddr, arvalid, arready, rdata, rresp, rvalid, rready}`. Data is 32 bits. One transaction
is outstanding at a time; every response is OKAY. Addresses are byte addresses within the slot.

| Slot | Port prefix | Address width | Window |
|---|---|---|---|
| MAC | `s_axi_mac_` | 12 | 4 KiB |
| MDIO | `s_axi_mdio_` | 12 | 4 KiB |
| PROTOCOL | `s_axi_prot_` | 16 | 64 KiB |

### 2.4 CPU streams (`cpu_clk`)

AXI4-Stream, 64-bit data, `tkeep` 8 bits, byte 0 in `tdata[7:0]`, whole Ethernet frames without FCS.

| Ports | Dir | Description |
|---|---|---|
| `cpu_eth_rx_tdata`, `_tkeep`, `_tvalid`, `_tlast` / `_tready` | out / in | Frames to the CPU: frames that no hardware leaf claimed and that the classifier passes. Outputs are registered. |
| `cpu_eth_tx_tdata`, `_tkeep`, `_tvalid`, `_tlast` / `_tready` | in / out | Frames from the CPU, 14 to 1518 bytes. `tready` falls only between frames. |

### 2.5 Interrupt and status

| Port | Dir | Clock | Description |
|---|---|---|---|
| `mdio_irq` | out | `cpu_clk` | Level, active high: PHY interrupt masked by the MDIO `IRQ_EN` bit |
| `mac_stat_link_up` | out | `axis_clk` | Link flag written by the firmware (MAC `CTRL.LINK_UP`) |
| `mac_stat_speed` | out, 2 bits | `axis_clk` | Configured speed: 0 10 Mb/s, 1 100 Mb/s, 2 1000 Mb/s |
| `mac_stat_rx_clk_ok` | out | `axis_clk` | Receive clock measured in band for the configured speed |
| `prot_stat_ip_valid` | out | `sid_clk` | IPv4 address valid |
| `prot_stat_dhcp_bound` | out | `sid_clk` | DHCP lease held |

The top re-synchronizes every status bit it uses into its own domain.

## 3. Register map as the firmware uses it

Slot bases in the firmware's window: MAC `+0x1000`, MDIO `+0x2000`, PROTOCOL `+0x10000` (core 1 window base
`0x44A00000`). Every block starts with the same three read-only registers: `0x000` ID (four ASCII
characters, first character in bits [31:24]), `0x004` VERSION (`0x10222026`), `0x008` CAPS (build
parameters).

### 3.1 MAC (ID `MAC1` = `0x4D414331`)

| Offset | Name | Access | Content |
|---|---|---|---|
| `0x008` | CAPS | RO | [7:0] receive FIFO KiB, [15:8] transmit FIFO KiB, [31:16] largest frame |
| `0x00C` | CTRL | RW | [0] RX_EN, [1] TX_EN (0 discards queued frames), [5:4] SPEED (0 10M, 1 100M, 2 1000M), [8] LINK_UP, [16] CNT_CLEAR (write 1) |
| `0x010` | STATUS | RO | [0] RX_CLK_OK, [1] IDELAY_RDY, [2] RX_IN_RESET, [5:4] speed in effect, [8] in-band link, [10:9] in-band speed, [11] in-band duplex |
| `0x014` | RX_CLK_RATE | RO | Receive clock rate window count |
| `0x018` | RX_IDELAY_TAP | RO | Input delay tap (12) |
| `0x020` / `0x024` / `0x028` / `0x02C` | RX_GOOD / RX_BAD / RX_OVERFLOW / TX_FRAMES | RO | Counters |

Firmware order on link-up: write SPEED, set RX_EN and TX_EN, set LINK_UP, poll STATUS.RX_CLK_OK.

### 3.2 MDIO (ID `MDIO` = `0x4D44494F`)

| Offset | Name | Access | Content |
|---|---|---|---|
| `0x008` | CAPS | RO | [23:0] clock kHz, [31:24] power-on reset milliseconds |
| `0x00C` | CTRL | RW | [0] MDC, [1] MDIO_OE, [2] MDIO_OUT, [8] PHY_RESET, [9] IRQ_EN |
| `0x010` | STATUS | RO | [0] MDIO_IN, [1] PHY_INT, [2] POR_DONE, [3] PHY_RESET_ACTIVE |
| `0x014` | BITBANG | W / R | Write: bits [2:0] set the three pin bits of CTRL. Read: [0] MDIO_IN |

The firmware shifts Clause 22 frames through BITBANG and waits for STATUS.POR_DONE after reset.

### 3.3 PROTOCOL (ID `PROT` = `0x50524F54`)

Sub-map of the 64 KiB slot: wrapper `0x0000`, ARP `0x1000`, ICMP `0x2000`, DHCP `0x3000`, iperf `0x4000`,
classifier `0x8000`, checksum offload `0x9000`. A window of a block that is not built reads 0.

Wrapper registers used by the firmware:

| Offset | Name | Access | Content |
|---|---|---|---|
| `0x008` | CAPS | RO | [4:0] leaves built, [5] CPU path built, [15:8] ingress KiB, [23:16] egress KiB |
| `0x00C` | CTRL | RW | [0] FILTER_ENABLE (0 = promiscuous), [1] CPU_PATH_ENABLE, [12:8] leaf enables, [16] CNT_CLEAR |
| `0x014` | LOCAL_MAC_HI | RW | [15:0] MAC octets 0 and 1, staged |
| `0x018` | LOCAL_MAC_LO | RW | MAC octets 2 to 5; this write commits all 48 bits |
| `0x01C` / `0x020` / `0x024` | STATIC_IP / NETMASK / GATEWAY | RW | Fallback address, host byte order |
| `0x028` / `0x02C` / `0x030` | EFFECTIVE_IP / MASK / GW | RO | Lease while DHCP is in use, else the static values |
| `0x034` | CPU_CAPS | RO | CPU queue sizes |
| `0x040` to `0x068` | counters | RO | Ingress, egress, delivered, CPU receive, claimed, dropped, CPU transmit, discarded, rejected |

The MAC address registers feed ARP, ICMP, DHCP and the CPU path; the firmware writes them before starting
DHCP.

DHCP leaf (window `0x3000`, ID `DHCP` = `0x44484350`):

| Offset | Name | Access | Content |
|---|---|---|---|
| `0x00C` | CTRL | RW | [0] START (pulse), [1] STOP (pulse), [2] AUTO (level, firmware intent), [3] RENEW_NOW (pulse), [16] CNT_CLEAR |
| `0x010` | STATUS | RO | [2:0] state (0 INIT, 1 SELECTING, 2 REQUESTING, 3 BOUND, 4 RENEWING, 5 FAIL), [8] BOUND, [9] FAIL, [16] ENABLE |
| `0x014` to `0x02C` | LEASE_IP, MASK, ROUTER, SERVER, TIME_S, ELAPSED_S, XID | RO | Lease data |

The classifier and checksum offload windows are programmed by the CPU-path driver in `libik64_netcore.a`;
`fw_1541` does not access them directly.

## 4. Constraints and top-level requirements

### 4.1 Constraints inside the checkpoint

The checkpoint carries, scoped to the core:

- the IODELAY group `ik64_rgmii` on the five receive IDELAYE2 cells and the IDELAYCTRL;
- every clock-domain crossing of the core: false paths to the first stage of each synchronizer chain and
  to the asynchronous reset pins, maximum delay and bus skew of one source period on each Gray-coded
  counter, maximum delay of one destination period on each held request and response bundle, and the
  matching `report_cdc` waivers.

The constraints name their cells by the scrambled names and their clocks by the port they enter
(`get_clocks -of_objects [get_ports cpu_clk]`), so they apply under whatever clock names the top derives.
The forwarded clock `rgmii_txc` is not in the checkpoint: it belongs on the `eth_txck` pad, which only the
top can name (section 4.2).

The crossing constraints assume these clock periods: `clk125` and `clk125_90` 8 ns, `clk200` 5 ns,
`axis_clk` 16 ns, `cpu_clk` 10 ns, `sid_clk` 20 ns, `eth_rxck` 8 ns.

### 4.2 Constraints the top applies

`fpga/constraints/ik64_rgmii.xdc` holds the pin-level timing:

- `create_clock` 8 ns on `eth_rxck` (`rgmii_rxc`) and the virtual clock `rgmii_rxc_v`;
- the generated clock `rgmii_txc` on the `eth_txck` pad, sourced at the clock pin of the one ODDR that
  `clk125_90` drives, 1:1. It is rooted on the pad so that the output buffer is in the clock path as it is
  in the data paths; a clock rooted on the ODDR output leaves about 1.5 ns of buffer delay out and reports
  a false setup violation of that size;
- input delays on `eth_rxd` and `eth_rxctl` (maximum -1.2 ns, minimum -2.8 ns, both edges), with the
  same-edge capture multicycle and false paths between `rgmii_rxc_v` and `rgmii_rxc`;
- output delays on `eth_txd` and `eth_txctl` against `rgmii_txc` (+1.0 and -1.0 ns, both edges);
- `SLEW FAST` on the transmit pins.

Pin locations and I/O standards (LVCMOS25, bank 13) are in `fpga/c64.xdc`. The six clocks and five
resets of section 2.1 are defined and constrained by the top; no `set_clock_groups` is needed between them.

### 4.3 IDELAYCTRL

The core instantiates its own IDELAYCTRL (reference `clk200`, reset from `clk200_resetn`) for the receive
IDELAYE2 cells, in the IODELAY group `ik64_rgmii`. The top provides a 200 MHz `clk200` and a reset for it.
The DDR3 memory controller carries its own IDELAYCTRL in a different IODELAY group; the two coexist and
the top adds no third one. The IDELAYE2 cells of the core and its IDELAYCTRL must land in one clock region
of the RGMII bank (the placer handles this from the group).

### 4.4 Clock resources

The core uses one BUFIO and one BUFR (receive clock, `BYPASS`) in the region of `eth_rxck`, and no BUFG:
the top supplies `clk125`, `clk125_90`, `clk200`, `axis_clk`, `cpu_clk` and `sid_clk` on global clocks.

## 5. Resources (out-of-context synthesis, xc7a200tsbg484-1)

| Resource | Used | Available |
|---|---|---|
| Slice LUTs | 13,213 | 134,600 |
| Slice registers | 21,698 | 269,200 |
| Block RAM tiles | 53.5 | 365 |
| DSP48E1 | 2 | 740 |
| IBUF / ILOGIC / OLOGIC | 6 / 5 / 6 | |
| IDELAYCTRL / BUFIO / BUFR | 1 / 1 / 1 | |

## 6. Tool version

The checkpoint is created and read with Vivado 2026.1; releases before 2026.1 do not open it. The part is
`xc7a200tsbg484-1`. The checkpoint is not encrypted. A checkpoint encrypted with the AMD public key
`xilinxt_2026.1-2030.x` (Vivado 2026.1 up to 2030.x open it) can replace this file without a change to the
top: the ports, the clock requirements of section 4 and the register maps stay the same.

## 7. Rebuilding the netlist

The build needs the private network sources. With access to them:

```
python -I tools/setup_ironkernel.py
powershell -NoProfile -ExecutionPolicy Bypass -File ironkernel/build_netcore.ps1
```

`setup_ironkernel.py` installs the private `ironkernel/` repository and the pinned source trees. The build
script synthesizes the core out of context with full flattening, records the crossing constraints of
section 4.1, gives every cell and net an opaque name, rewrites the constraints with the new names, exports
the netlist to EDIF and reads it back (which drops the RTL file names and line numbers), and writes
`ik64_net_core.dcp` and `ik64_net_core_stub.sv` to this folder. `ironkernel/verify_netcore.tcl` shows what
an outsider sees in the result. With the `-Encrypt` option the script instead encrypts every source file with
Vivado's `encrypt` command and the AMD public key (the command needs a Vivado license that includes IEEE-1735
encryption) and keeps the hierarchy. Without access to the sources, the committed netlist is used as it is.

## 8. License

OWNER TO CONFIRM: the binary netlist `ik64_net_core.dcp` is redistributable for use with IronKernel 64,
published as a CERN-OHL-S Available Component. The exact wording of the notice and the exception that
lets the GPL parts of IronKernel 64 combine with the netlist are recorded in the root `README.md`.
