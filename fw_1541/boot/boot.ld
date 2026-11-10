/* Core 1 QSPI bootloader: everything in the 64 KiB LMB at 0x0 (the reset vector). */
MEMORY { lmb : ORIGIN = 0x0, LENGTH = 0x10000 }
ENTRY(_start)
SECTIONS
{
  .text : { *(.text.init) *(.text .text.*) } > lmb
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > lmb
  /* no .data / .bss: boot.c has none */
  __global_pointer$ = 0x800;
  __stack_top = ORIGIN(lmb) + LENGTH(lmb);
  /DISCARD/ : { *(.comment) *(.eh_frame) *(.riscv.attributes) *(.note.*) }
}
