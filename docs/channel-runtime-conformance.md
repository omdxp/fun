# Channel Runtime Conformance

This document defines the stabilization gate for std.channel behavior across runtime backend selections.

## Scope

The gate focuses on behavior that must remain stable while channel/runtime APIs are consolidated:

- Return-code compatibility for core send/recv/select paths
- Select fairness under sustained ready-state load
- Timeout behavior under empty-channel waits
- Cross-backend consistency when selected via environment override

Backends are selected through `FUN_RUNTIME_BACKEND` and validated with both values:

- `posix`
- `windows`

## Compatibility Matrix

The following operations are treated as compatibility anchors:

| Operation | Expected result |
| --- | --- |
| `try_recv` on open+empty channel | `channel_rc_empty()` (`2`) |
| `send_timeout` when space available | `channel_rc_ok()` (`0`) |
| `try_send` on full channel | `channel_rc_full()` (`2`) |
| `recv_timeout_into` with queued value | `channel_rc_ok()` (`0`) and value consumed |
| `recv_timeout_into` on open+empty channel | `channel_rc_timeout()` (`2`) |
| `send_timeout_with_cancel` with raised cancel flag | `channel_rc_cancelled()` (`3`) |
| `send_timeout` after `close()` | `channel_rc_closed()` (`1`) |
| `recv_timeout_into` after close+drain | `channel_rc_closed()` (`1`) |
| `select_recv_default_with` on two open+empty channels | `channel_rc_default()` (`3`), index `channel_select_index_default()` (`-1`) |
| `select_recv_timeout_with` on two open+empty channels | `channel_rc_timeout()` (`2`) |
| `select_recv_timeout_with_cancel` with raised cancel flag | `channel_rc_cancelled()` (`3`) |

Alias constraints are also part of compatibility:

- `channel_rc_timeout() == channel_rc_full() == channel_rc_empty() == 2`
- `channel_rc_default() == channel_rc_cancelled() == 3`

## Stress Benchmark Thresholds

A micro-benchmark validates select round-robin fairness and timeout stability:

- Workload:
	- `select_recv_timeout3_rr_with_tuning` over three prefilled channels (360 receives total)
	- 20 timeout rounds over empty 3-way select with 15ms timeout each
- Fairness threshold: `fairness_skew <= 1`
- Completion threshold: `count_total == 360`
- Timeout threshold: `timeout_failures == 0` across all timeout rounds
- Process elapsed budget per backend run: `150ms <= elapsed_ms <= 5000ms`
- Cross-backend elapsed drift budget: `abs(posix_elapsed_ms - windows_elapsed_ms) <= 800ms`

## CI Gate

The tests in tests/codegen_test.zig are the executable gate:

- `std.channel runtime conformance matrix is stable across backend selectors`
- `std.channel fairness and timeout benchmark stays within backend thresholds`

When these tests fail, treat it as a behavior regression and stabilize before adding new channel/runtime API surface.
