// Drawing set: product-brief (1 sheet: IronKernel 64 and what it connects to) for
// Documentation/ironkernel64_product_brief.md.
// Build: node diagrams/src/product-brief.js  ->  diagrams/out/product-brief.pptx
// Render: powershell -File diagrams\tools\render.ps1 diagrams\out\product-brief.pptx
// Fills: white = IronKernel firmware and gateware, gray = board support, blue = third-party or closed core,
// yellow = outside the FPGA.
const path = require("path");
const { newDeck, helpers, FILL } = require("../lib/engslides");

const pres = newDeck("IronKernel 64");
const { box, container, wire, label, notes, legend, frame } = helpers(pres);
const W = FILL.white, G = FILL.gray, B = FILL.blue, Y = FILL.yellow;

const s = pres.addSlide();
const xl = 0.5, xr = 10.7, ew = 2.05;
const c = [2.95, 5.55, 8.15], w = 2.1, h = 0.95;
const r = [1.0, 2.6, 4.2];
const cmx = (i) => c[i] + w / 2, cmy = (j) => r[j] + h / 2;
container(s, 2.75, 0.5, 7.7, 4.95, "Artix-7 XC7A200T on the Nexys Video: two MicroBlaze V cores and fabric");

// outside the FPGA
box(s, xl, r[0], ew, h, "USB keyboard, terminal", ["J15 through the PIC24 (PS/2)", "USB-UART, 115200 8N1"], Y);
box(s, xl, r[2], ew, h, "SMB share (NAS)", ["Gigabit Ethernet,", "RTL8211E, RGMII"], Y);
box(s, xr, r[1], ew, h, "Line out, headphones", ["ADAU1761 codec, I2S", "48 kHz, 16 bit"], Y);
box(s, xr, r[2], ew, h, "HDMI monitor, OLED", ["720p60 through TMDS", "128 x 32 SSD1306"], Y);

// inside
box(s, c[0], r[0], w, h, "Input", ["ps2_rx, UART Lite", "PETSCII key queue"], G);
box(s, c[1], r[0], w, h, "Core 0 \"C64\"", ["6502 interpreter, PSID,", "BASIC shell, screen editor"], W);
box(s, c[2], r[0], w, h, "Fabric SID", ["reDIP-SID 6581, 50 MHz", "write FIFO, 48 kHz out"], B);
box(s, c[0], r[1], w, h, "Core 1 \"1541\"", ["CBM DOS, device 8 and 9", "lwIP, libsmb2, no RTOS"], W);
box(s, c[1], r[1], w, h, "Shared BRAM, mailbox", ["128 KiB, drive protocol", "doorbell interrupts"], W);
box(s, c[2], r[1], w, h, "Audio out", ["2048-frame FIFO, I2S", "ADAU1761 initialisation"], G);
box(s, c[0], r[2], w, h, "Network core", ["closed netlist: MAC, MDIO,", "ARP, DHCP, checksum offload"], B);
box(s, c[2], r[2], w, h, "Video and OLED", ["384 x 240 x 3, TMDS", "now-playing, piano, marquee"], W);

// keyboard -> input -> core 0 -> SID -> audio -> line out
wire(s, xl + ew, cmy(0), c[0], cmy(0));
wire(s, c[0] + w, cmy(0), c[1], cmy(0));
wire(s, c[1] + w, cmy(0), c[2], cmy(0));
wire(s, cmx(2), r[0] + h, cmx(2), r[1]);
wire(s, c[2] + w, cmy(1), xr, cmy(1));
// core 0 <-> shared BRAM <-> core 1
wire(s, cmx(1), r[0] + h, cmx(1), r[1], { start: true });
wire(s, c[1], cmy(1), c[0] + w, cmy(1), { start: true });
// core 1 <-> network core <-> share
wire(s, cmx(0), r[1] + h, cmx(0), r[2], { start: true });
wire(s, xl + ew, cmy(2), c[0], cmy(2), { start: true });
label(s, xl + ew + 0.05, cmy(2) - 0.25, 0.65, "RGMII");
// core 0 -> video: down the gap between the columns
wire(s, c[1] + w - 0.25, r[0] + h, c[1] + w - 0.25, 2.25, { end: false });
wire(s, c[1] + w - 0.25, 2.25, 7.8, 2.25, { end: false });
wire(s, 7.8, 2.25, 7.8, cmy(2), { end: false });
wire(s, 7.8, cmy(2), c[2], cmy(2));
wire(s, c[2] + w, cmy(2), xr, cmy(2));

notes(s, 0.6, 5.6, 12.1, 1.0, [
  "Both cores run C firmware from the standalone BSP. Core 1 runs from DDR3 and serves device 9, a read-only tune bank in the top 1 MiB of its DDR3 partition, with or without the network.",
  "The network core and the network library of core 1 are closed (name-scrambled netlist and prebuilt library); apart from the AMD IP and BSP, every other block is open source.",
]);
legend(s, 0.6, 6.8, [["IronKernel firmware and gateware", W], ["Board support", G], ["Third-party or closed core", B], ["Outside the FPGA", Y]], 3.0);
frame(s);

pres.writeFile({ fileName: path.join(__dirname, "..", "out", "product-brief.pptx") });
