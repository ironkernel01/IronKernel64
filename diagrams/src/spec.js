// Drawing set: spec (2 sheets) for Documentation/ironkernel64_spec.md.
//   sheet 1: architecture (two cores, their register windows, shared BRAM, DDR3)
//   sheet 2: data flow of a tune from the drive to the codec
// Build: node diagrams/src/spec.js  ->  diagrams/out/spec.pptx
// Render: powershell -File diagrams\tools\render.ps1 diagrams\out\spec.pptx
// Fills: white = IronKernel, gray = board support or AMD IP, blue = third-party or closed core, yellow = outside.
const path = require("path");
const { newDeck, helpers, FILL } = require("../lib/engslides");

const pres = newDeck("IronKernel 64 specification");
const { box, container, wire, label, notes, legend, frame } = helpers(pres);
const W = FILL.white, G = FILL.gray, B = FILL.blue, Y = FILL.yellow;
const LEG = [["IronKernel", W], ["Board support, AMD IP", G], ["Third-party or closed core", B], ["Outside the FPGA", Y]];

// ---------------------------------------------------------------- sheet 1: architecture
{
  const s = pres.addSlide();
  container(s, 0.4, 0.45, 5.0, 5.3, "Core 0 \"C64\": MicroBlaze V, window 0x4400_0000");
  container(s, 8.45, 0.45, 4.3, 5.3, "Core 1 \"1541\": MicroBlaze V, window 0x44A0_0000");
  box(s, 0.6, 0.85, 4.6, 0.8, "Core 0 \"C64\"", ["RV32IMC, 256 KiB LMB, 8 KiB caches over DDR3", "6502 interpreter, PSID player, BASIC shell"], W);
  box(s, 8.65, 0.85, 3.9, 0.8, "Core 1 \"1541\"", ["RV32IMC, 64 KiB LMB boot stub, code in DDR3", "CBM DOS, lwIP, libsmb2"], W);
  const t0 = [1.9, 2.5, 3.1, 3.7, 4.3, 4.9];
  const left = [
    ["c64_sysregs", "0x0000: identity, build ID, status, LEDs", W],
    ["sid_audio_out", "0x1_0000: FIFO 2048 frames, I2S", W],
    ["c64_video", "0x2_0000: 384 x 240, 720p60, TMDS", W],
    ["ps2_rx", "0x3_0000: PS/2 scan codes, FIFO 16", W],
    ["sid_player, reDIP-SID", "0x4_0000: write FIFO 512, phi2 replay", B],
    ["c64_oled", "0x5_0000: SSD1306, 2 KiB buffer, scroll", W],
  ];
  left.forEach((b, i) => {
    box(s, 1.0, t0[i], 3.0, 0.5, b[0], [b[1]], b[2]);
    wire(s, 0.75, t0[i] + 0.25, 1.0, t0[i] + 0.25, { start: true });
  });
  wire(s, 0.75, 1.65, 0.75, t0[5] + 0.25, { end: false });
  label(s, 1.0, 1.7, 3.5, "AXI4-Lite, 64 KiB slots, 512 KiB window");
  const right = [
    ["c64_sysregs", "0x0000: core 1 instance", W],
    ["Network core: MAC", "0x1000: RGMII MAC", B],
    ["Network core: MDIO", "0x2000: RTL8211E management", B],
    ["Network core: protocol", "0x1_0000: classifier, offload", B],
    ["AXI DMA, 128 KiB buffers", "streams to the network core (BD)", G],
  ];
  right.forEach((b, i) => {
    box(s, 9.2, t0[i], 3.0, 0.5, b[0], [b[1]], b[2]);
    if (i < 4) wire(s, 12.45, t0[i] + 0.25, 12.2, t0[i] + 0.25, { start: true });
  });
  wire(s, 12.45, 1.65, 12.45, t0[3] + 0.25, { end: false });
  label(s, 9.2, 1.7, 3.0, "AXI4-Lite, 1 MiB window", 7.5);
  box(s, 5.9, 0.85, 2.1, 0.8, "DDR3 path", ["SmartConnect, AXI clock", "converter, MIG, 512 MiB"], G);
  box(s, 5.9, 2.9, 2.1, 0.9, "Shared BRAM", ["128 KiB, dual port", "request, reply, data, log"], W);
  box(s, 5.9, 4.1, 2.1, 0.7, "Mailbox", ["doorbell interrupts"], G);
  wire(s, 5.2, 1.25, 5.9, 1.25, { start: true });
  wire(s, 8.0, 1.25, 8.65, 1.25, { start: true });
  wire(s, 5.0, 1.65, 5.0, 3.35, { start: true, end: false });
  wire(s, 5.0, 3.35, 5.9, 3.35);
  wire(s, 5.0, 3.35, 5.0, 4.45, { end: false });
  wire(s, 5.0, 4.45, 5.9, 4.45);
  wire(s, 8.9, 1.65, 8.9, 3.35, { start: true, end: false });
  wire(s, 8.9, 3.35, 8.0, 3.35);
  wire(s, 8.9, 3.35, 8.9, 4.45, { end: false });
  wire(s, 8.9, 4.45, 8.0, 4.45);
  notes(s, 0.6, 5.9, 12.1, 0.9, [
    "Clocks: cpu_clk 100 MHz for both cores and all register blocks, sid_clk 50 MHz for the SID, pix_clk 74.25 MHz and 371.25 MHz for video, aud_clk 12.288 MHz for the codec, 125 MHz and 62.5 MHz for the network core.",
    "Core 0 reaches the framebuffer (0xC000_0000) through an AXI BRAM controller; the video block reads the other port in pix_clk. Both cores cache only the DDR3 window.",
  ]);
  legend(s, 0.6, 6.95, LEG, 3.0);
  frame(s);
}

// ---------------------------------------------------------------- sheet 2: data flow
{
  const s = pres.addSlide();
  const pitch = 2.1, bw = 1.85, bh = 0.95;
  const x = (i) => 0.6 + i * pitch;
  const ya = 1.0, yb = 3.1, yc = 5.0;
  const cx = (i) => x(i) + bw / 2;
  box(s, x(0), ya, bw, bh, "Device 8, 9", ["SMB share or", "tune bank in DDR3"], Y);
  box(s, x(1), ya, bw, bh, "Core 1 server", ["drive_server, cbmdos,", "backend_smb, _ram"], W);
  box(s, x(2), ya, bw, bh, "Shared BRAM", ["request, reply,", "61,440-byte data area"], W);
  box(s, x(3), ya, bw, bh, "Core 0 client", ["drive_client:", "OPEN, READ, CLOSE"], W);
  box(s, x(4), ya, bw, bh, "BASIC shell", ["LOAD, LIST, RUN,", "wedge, file buffer"], W);
  box(s, x(5), ya, bw, bh, "PSID loader", ["psid.c: header,", "load, init, play"], W);
  box(s, x(5), yb, bw, bh, "6502 and memory", ["cpu6502, c64mem:", "play call, SID writes"], W);
  box(s, x(4), yb, bw, bh, "SID write tap", ["sidbus_fabric: cycle,", "register, value"], W);
  box(s, x(3), yb, bw, bh, "sid_player", ["FIFO 512, phi2 replay", "985,248 Hz, sid_clk"], B);
  box(s, x(2), yb, bw, bh, "48 kHz stream", ["decimation, sid_strm_cdc", "16 deep, to cpu_clk"], W);
  box(s, x(1), yb, bw, bh, "sid_audio_out", ["FIFO 2048 frames,", "I2S 48 kHz"], W);
  box(s, x(0), yb, bw, bh, "ADAU1761", ["MCLK 12.288 MHz,", "DAC, mixers"], G);
  box(s, x(0), yc, bw, bh, "Line out", ["J5 jack, J3", "headphones"], Y);
  for (let i = 0; i < 5; i++) wire(s, x(i) + bw, ya + bh / 2, x(i + 1), ya + bh / 2, { start: i < 3 });
  wire(s, cx(5), ya + bh, cx(5), yb);
  for (let i = 5; i > 0; i--) wire(s, x(i), yb + bh / 2, x(i - 1) + bw, yb + bh / 2);
  wire(s, cx(0), yb + bh, cx(0), yc);
  notes(s, 2.9, 4.4, 9.8, 1.4, [
    "A file travels left to right in the top row: the drive server reads it into the shared BRAM in chunks, core 0 collects it into its file buffer, RUN parses the PSID header and loads the image into the emulated 64 KiB.",
    "Each play call (50 Hz PAL vertical blank, or the CIA 1 timer) runs on the 6502 interpreter; its SID writes carry the phi2 cycle at which they happen and the fabric replays them at those cycles.",
    "The audio path needs no CPU time after the writes are queued. The voice bars, the piano and the OLED read ENV3 and a firmware envelope model, not the audio stream.",
  ]);
  legend(s, 0.6, 6.95, LEG, 3.0);
  frame(s);
}

pres.writeFile({ fileName: path.join(__dirname, "..", "out", "spec.pptx") });
