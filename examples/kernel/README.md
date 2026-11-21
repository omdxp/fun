# A bare-metal kernel in Fun

A 32-bit x86 kernel that QEMU boots directly through multiboot. It loads
its own GDT and interrupt table, remaps the interrupt controllers, counts
timer ticks, turns on paging, and reports every check over the first
serial port before exiting QEMU with its own status.

What each module does:

- `port.fn`: port I/O through `asm` with operands, and QEMU's
  debug-exit device.
- `console.fn`: output to the serial port and to VGA text memory
  (`volatile`), with decimal and hex printing.
- `gdt.fn`: a flat GDT built from `packed compound` entries.
- `idt.fn`: the interrupt table. A file-scope `asm` block generates one
  entry stub per vector with assembler macros, and every stub calls
  `interrupt_dispatch` with the saved registers. Handlers live in an
  array of function values, `fun(InterruptFrame*) void[49] handlers`.
- `pic.fn` and `timer.fn`: the two 8259 interrupt controllers, remapped
  past the CPU's own exceptions, and the interval timer ticking at
  100 Hz on IRQ 0.
- `paging.fn`: page tables declared `align(4096)`, the first 4 MiB
  identity mapped, one page mapped a second time, and a page fault
  handler that maps any other page on its first touch.
- `cpu.fn`: `cpuid`, with a `union` reading the vendor registers back
  as text.
- `main.fn`: runs every check: a breakpoint, a system call that changes
  the caller's registers, timer ticks, and paging.

The build pieces:

- `[build] freestanding = true` and `arch = "x86"` in `fun.toml`.
- `boot/start.S`, the multiboot header and entry code, and
  `boot/linker.ld`, both passed through `[build]`.
- `boot/mem.c`, the `memcpy`/`memset`/`memmove`/`memcmp` every
  freestanding C program has to supply.
- `fun_panic_handler`, which a failed `assert` calls.

Build and run it with clang, lld, and QEMU installed:

```sh
FUN_CC=clang fun build
qemu-system-i386 -kernel fun-out/bin/kernel -serial stdio -display none \
  -no-reboot -device isa-debug-exit,iobase=0xf4,iosize=0x04
```

Or build objects and link them yourself, the way a larger kernel with
its own link step would:

```sh
FUN_CC=clang fun build -obj
ld.lld -m elf_i386 -T boot/linker.ld --build-id=none -o fun-out/kernel.elf \
  fun-out/obj/start.o fun-out/obj/kernel.o fun-out/obj/mem.o
qemu-system-i386 -kernel fun-out/kernel.elf -serial stdio -display none \
  -no-reboot -device isa-debug-exit,iobase=0xf4,iosize=0x04
```

QEMU's exit code is `(status << 1) | 1`, so `1` means every check passed
and `7` means a failed `assert` reached the panic handler.
