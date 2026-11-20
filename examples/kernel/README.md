# A bare-metal kernel in Fun

A 32-bit x86 kernel that QEMU boots directly through multiboot. It loads
its own GDT, writes to VGA text memory, prints over the first serial
port, and exits QEMU with its own status.

It shows the pieces a freestanding build uses:

- `[build] freestanding = true` and `arch = "x86"` in `fun.toml`.
- `boot/start.S`, the multiboot header and entry code, and
  `boot/linker.ld`, both passed through `[build]`.
- `boot/mem.c`, the `memcpy`/`memset`/`memmove`/`memcmp` every
  freestanding C program has to supply.
- `packed compound` for the GDT, `volatile` for VGA memory, `as` for
  addresses, and `asm` with operands for port I/O.
- `fun_panic_handler`, which a failed `assert` calls.

Build and run it with clang, lld, and QEMU installed:

```sh
FUN_CC=clang fun build
qemu-system-i386 -kernel fun-out/bin/kernel -serial stdio -display none \
  -no-reboot -device isa-debug-exit,iobase=0xf4,iosize=0x04
```

QEMU's exit code is `(status << 1) | 1`, so `1` means every check passed
and `7` means a failed `assert` reached the panic handler.
