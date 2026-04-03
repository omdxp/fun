
# Fun Standard Library

This directory contains standard library modules for the Fun language.

## Documentation Comments

Reference docs for stdlib modules are generated from source comments in `stdlib/std/*.fn`.

- Use `//` comments immediately above public declarations.
- Add comments for compound fields and quirk members, not just top-level symbols.
- Keep comments focused on behavior/intent.
- Prefer concise one-line summaries unless extra context is needed.

Example:

```fun
// Generic map with typed keys and values.
pub compound Map<K, V> {
	// Key storage array.
	K* key_slots;
}

pub quirk Serialize {
	// Encode the value as text.
	serialize() str;
}
```

## Structure

- **std/**: Standard library namespace
	- **std/c/**: C standard-library signature modules
	- **std/** (pure Fun): core utilities (string, vec, map, set, math, io, fs, path, time, rand, net, cli, log, json, toml)

## Modules

### Pure Fun modules (std/*)

Note: `num`/`dec` are 64-bit by default (`int64_t`/`double`), and Fun also supports fixed-width numeric types (`i8`..`i64`, `u8`..`u64`, `f32`, `f64`) plus arbitrary-width integers (`iN`, `uN`).

- **std/array.fn**: Fixed-size array helpers (get/set/swap/reverse).
- **std/channel.fn**: Bounded blocking ring-buffer channels with timeout send/recv, non-blocking `try_send`/`try_recv`, cancellation-aware send/recv helpers (`send_with_cancel`, `recv_into_with_cancel`, token variants `*_with_token`), await-friendly async APIs (`send_async`, `recv_async`, timeout/token/select async variants), composed async forwarding helpers (`forward_one_to_async`, `forward_one_to_with_token_async`, `select_forward_one_to_async`, `select_forward_one_to_with_token_async`), default-branch select helpers (`select_recv_default_with`, `select_recv3_rr_default_with`), cancellation-aware select APIs (`*_with_cancel`, token variants `*_with_token`), dedicated cancel tokens (`ChannelCancelToken`, `channel_cancel_token_*`), status helper symbols (`channel_rc_*`), select index helpers (`channel_select_index_*`), plus channel-level/per-call select wait-slice/backoff tuning, with synchronization routed through std.sync_runtime.
- **std/cli.fn**: Command-line argument parsing helpers (long/short flags, bundling, `--` stop).
- **std/collections.fn**: Collection quirks (len/is_empty) aligned with std.quirks.
- **std/fs.fn**: File system helpers (exists, read/write, copy, read_lines).
- **std/io.fn**: File helpers (append, size, read bytes, read line, flush).
- **std/json.fn**: JSON stringify/parse for string objects and arrays (with escaping, keys/has/remove).
- **std/log.fn**: Logging with levels and typed log helpers.
- **std/map.fn**: Generic map type `Map<K, V>` with typed keys/values and bytewise hashed lookups by default.
- **std/math.fn**: Math helpers.
- **std/net.fn**: Basic URL parsing, HTTP GET builder, and POSIX TCP/HTTP helpers.
- **std/option.fn**: Generic `Option<T>` container with `some<T>`/`none<T>` helpers.
- **std/c/net.fn**: POSIX socket bindings (sys/socket.h, netinet/in.h, arpa/inet.h, unistd.h).
- **std/sys.fn**: Environment, process control, and randomness helpers.
- **std/path.fn**: Path helpers (join, join_many, basename, dirname, extname, strip_ext, change_ext, is_abs).
- **std/rand.fn**: PRNG utilities (range_dec, chance, shuffle).
- **std/runtime_backend.fn**: Shared runtime backend selector helpers (`runtime_backend_*`) with precedence: `FUN_RUNTIME_BACKEND` -> `FUN_RUNTIME_OS` -> host hints (`OS`/`OSTYPE`) -> posix fallback.
- **std/sync.fn**: POSIX-backed synchronization wrappers (mutex/condition variable method and helper forms).
- **std/sync_backend_posix.fn**: POSIX synchronization backend module (`sync_backend_posix_*`) used by std.sync_runtime.
- **std/sync_backend_windows.fn**: Windows synchronization backend module (`sync_backend_windows_*`) with direct mutex/condvar lifecycle operations over `std.c.thread_windows`.
- **std/sync_runtime.fn**: Backend-facing sync runtime shim (`runtime_mutex_*`, `runtime_condvar_*`) with backend selector helpers (`sync_runtime_backend_*`) routed through std.runtime_backend and backend modules.
- **std/string.fn**: String helpers (count, strip prefix/suffix, split lines, replace, case conversion, repeat, etc.).
- **std/thread.fn**: POSIX-backed thread lifecycle helpers (`thread_new`, plus method and helper forms for start/join/detach).
- **std/thread_backend_posix.fn**: POSIX thread backend module (`thread_backend_posix_*`) used by std.thread_runtime.
- **std/thread_backend_windows.fn**: Windows thread backend module (`thread_backend_windows_*`) with direct thread lifecycle operations over `std.c.thread_windows`.
- **std/thread_runtime.fn**: Backend-facing thread runtime shim (`runtime_thread_*`) with backend selector helpers (`thread_runtime_backend_*`) routed through std.runtime_backend and backend modules.
- **std/thread_pool.fn**: POSIX-backed thread pool helpers (`thread_pool_new`, start_all/join_all/detach_all) routed through std.thread_runtime.
- **std/time.fn**: Time helpers (epoch, formatting, UTC, diffs).
- **std/toml.fn**: Minimal TOML parse/stringify for flat key/value.
- **std/vec.fn**: Dynamic vector helpers (reserve/insert/remove/pop/swap_remove/extend/resize/shrink_to_fit).
- **std/error.fn**: Error value helpers (construct/check ok/err).
- **std/result.fn**: Generic `Result<T>` container with `ok<T>`/`err<T>` helpers.
- **std/quirks.fn**: Common quirks (`Sized`, `Display`) for generic APIs.
- **std/serde.fn**: Serialization quirks (`Serialize`, `Deserialize`) and text conversion helpers.

### C signature modules (std/c/*)

- **std/c/def.fn**: Common C definitions and constants.
- **std/c/io.fn**: stdio bindings (FILE, printf, fopen, etc.).
- **std/c/mem.fn**: stdlib bindings (malloc/free, env, system, etc.).
- **std/c/thread.fn**: pthread-shaped thread/mutex/condition variable signatures with portable codegen support (`pthread.h` on POSIX, Win32 compatibility layer on Windows).
- **std/c/thread_windows.fn**: Windows-oriented pthread compatibility signature module used by Windows backend wrappers.
- **std/c/string.fn**: string.h bindings (strlen, memcpy, memset, etc.).
- **std/c/time.fn**: time.h bindings (time, localtime, strftime, etc.).

Fun maps `imp std.c.*;` imports to C standard headers during code generation. Actual implementations are provided by the C compiler/linker.

Signature-only modules support tooling (IDE completion, future LSP).

Installed location (via `zig build install`):
- `share/fun/stdlib/std/c/*.fn`
