# Concurrency

## Async / Await

- Declare async functions with `async fun name(args) type { ... }`.
- `await` is valid only inside an `async fun` body.
- Calls to async functions and async quirk methods must be awaited.
- The awaited expression must resolve to an async call.

```fun
compound Counter {
  num base;
}

quirk AsyncCounter {
  async add(num x) num;
}

impl Counter as AsyncCounter {
  async add(num x) num { ret self.base + x; }
}

async fun main() {
  Counter c;
  c.base = 41;
  num out = await c.add(1);
  _ = out;
}
```

## `fork` & Channels

`fork <call>;` spawns a *virtual thread*, a fire-and-forget task that
runs on a runtime M:N scheduler: a pool of OS worker threads multiplexes
many cheap `fork` tasks. The target is an `async fun`. `fork` returns
nothing; results flow back through channels.

- **Automatic drain**: `main` blocks until every `fork`ed task has
  completed before it returns, so spawned work always finishes.
- **Cooperative**: a task that blocks on a channel op holds its worker
  (the yield points are the blocking primitives). It is not preemptive.
- **Elastic worker pool**: the scheduler starts with a base pool sized to
  the CPU count, but a task that blocks inside a blocking primitive (a
  channel op, a `Mutex`, a `WaitGroup`) doesn't starve the rest of the
  program, the scheduler spins up an extra worker whenever none is idle
  and the pool has room to grow (default cap 4096, override with
  `FUN_SCHED_MAX_WORKERS`). Idle workers above the base pool retire after
  10 seconds of nothing to do.

```fun
imp std.channel;

async fun square_into(Channel<num>* out, num v) {
  out <- v * v;
}

fun main() num {
  Channel<num> results = channel_new_cap(0, 8);
  fork square_into(&results, 2);
  fork square_into(&results, 3);
  num total = (<-results) + (<-results);
  ret total; // 4 + 9 = 13
}
```

### Channel operators

Sugar over `std.channel`:

- `ch <- v` sends `v` into `ch` (equivalent to `ch.send(v)`).
- `<-ch` receives from `ch` (equivalent to `ch.recv()`, lossy; use
  `ch.recv_into(&out)` for the error-aware form).
- `a < -b` (a comparison against a negative, with a space) is unaffected;
  only the glued `<-` (no space) is the channel operator.

### Result-style send/recv

The low-level `recv_into`/`send` return a numeric status code, but the
ergonomic layer returns a value you can `fit` on:

- `ch.recv_result()` returns `RecvResult<T>` with variants `Ok(T)`,
  `Closed`, `Timeout`, `Cancelled`, `Error(num)` (also
  `recv_result_timeout`, `recv_result_with_token`, `try_recv_result`, and
  `*_async` variants).
- `ch.send_result(v)` returns `SendResult` with variants `Ok`, `Closed`,
  `Full`, `Cancelled`, `Error(num)` (also `send_result_timeout`,
  `try_send_result`, async).

```fun
imp std.io;
imp std.channel;

fun main() {
  Channel<num> ch = channel_new_cap(0, 1);
  ch <- 42;

  fit ch.recv_result() {
    RecvResult.Ok(v) -> {
      println_fmt("got {num}", v);
    }
    RecvResult.Closed -> {
      println("drained");
    }
    RecvResult.Timeout -> {
      println("retry");
    }
    RecvResult.Cancelled -> { }
    RecvResult.Error(e) -> {
      println_fmt("error {num}", e);
    }
  }
}
```

### `std.sync.Mutex`/`CondVar`

`mutex_new()`/`condvar_new()` initialize eagerly at construction, which is
the safe form to use when the value will be shared across threads (for
example captured by multiple `fork`ed tasks). A value that only ever sees
single-threaded use may rely on the lazy fallback in `lock`/`wait`, but a
fresh `Mutex`/`CondVar` several tasks might lock/wait on concurrently for
the first time should always come from `_new()`.

### `std.task` WaitGroup

Wait for a batch of `fork`ed tasks: `wait_group_new(n)`, each task calls
`wg.done()`, and `wg.wait()` blocks until all `n` complete. Its
completion count is guarded by its own internal `Mutex`, so `add()` is
safe to call concurrently from multiple already-forked tasks (growing the
group for their own children), and `wait()` never returns before every
expected `done()` has actually landed.
