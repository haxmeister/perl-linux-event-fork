# Linux::Event::Fork

[![CI](https://github.com/haxmeister/perl-linux-event-fork/actions/workflows/ci.yml/badge.svg)](https://github.com/haxmeister/perl-linux-event-fork/actions/workflows/ci.yml)

High‑performance, event‑loop–integrated child process management for Linux.

Built on top of **Linux::Event**, this module provides structured,
non‑blocking process spawning with precise lifecycle control and bounded
parallelism.

---

## Linux::Event Ecosystem

The Linux::Event modules are designed as a composable stack of small,
explicit components rather than a framework.

Each module has a narrow responsibility and can be combined with the others
to build event-driven applications.

Core layers:

Linux::Event
    The event loop. Linux-native readiness engine using epoll and related
    kernel facilities. Provides watchers and the dispatch loop.

Linux::Event::Listen
    Server-side socket acquisition (bind + listen + accept). Produces accepted
    nonblocking filehandles.

Linux::Event::Connect
    Client-side socket acquisition (nonblocking connect). Produces connected
    nonblocking filehandles.

Linux::Event::Stream
    Buffered I/O and backpressure management for an established filehandle.

Linux::Event::Fork
    Asynchronous child process management integrated with the event loop.

Linux::Event::Clock
    High resolution monotonic time utilities used for scheduling and deadlines.

Canonical network composition:

Listen / Connect
        ↓
      Stream
        ↓
  Application protocol

Example stack:

Linux::Event::Listen → Linux::Event::Stream → your protocol

or

Linux::Event::Connect → Linux::Event::Stream → your protocol

The core loop intentionally remains a primitive layer and does not grow
into a framework. Higher-level behavior is composed from small modules.

## Why Linux::Event::Fork?

Traditional `fork/exec` usage does not integrate cleanly with event loops.
`Linux::Event::Fork` provides:

- Fully nonblocking stdout/stderr capture
- Optional streaming stdin (parent → child)
- Timeout with optional SIGKILL escalation
- Deterministic concurrency limits (`max_children`)
- FIFO queueing when capacity is exceeded
- Drain callback when all work completes
- Cancellation of queued work
- Runtime adjustment of concurrency limits

It is intentionally minimal and predictable — not a supervisor, not a promise
framework, and not a job scheduler.

---

## Quick Start

```perl
use v5.36;
use Linux::Event;
use Linux::Event::Fork;

my $loop   = Linux::Event->new;
my $forker = Linux::Event::Fork->new($loop, max_children => 4);

for (1..100) {
    $forker->spawn(
        cmd => [ $^X, '-we', 'print "hi\n"; exit 0' ],
    );
}

$forker->drain(on_done => sub ($fork) {
    $loop->stop;
});

$loop->run;
```

---

## Concurrency Model

Concurrency is controlled at construction:

```perl
my $forker = Linux::Event::Fork->new($loop, max_children => 4);
```

When:

```
running >= max_children
```

additional `spawn()` calls return a `Linux::Event::Fork::Request` object and
are queued.

You may increase capacity at runtime:

```perl
$forker->max_children(8);
```

Queued work may start immediately when the limit increases.

---

## Return Types

`spawn()` returns:

- `Linux::Event::Fork::Child`   — child started immediately
- `Linux::Event::Fork::Request` — queued due to capacity limits

This explicit separation avoids ambiguous “half‑started” handles.

---

## Execution Model

- All `on_*` callbacks run in the **parent process**.
- Only `child => sub { ... }` runs inside the **child process**.
- All behavior is driven by the Linux::Event loop.

---

## CI Notes

If GitHub Actions fails during:

```
Run shogo82148/actions-setup-perl@v1
install perl
Error: Error: failed to verify ...
```

This is an upstream attestation verification issue in the action and does
not affect CPAN builds.

Possible mitigations:

1. Pin to a specific action release
2. Disable verification (if supported)
3. Use an alternative Perl setup action

---

## See Also

- `examples/` directory for focused usage patterns
- `Linux::Event` for the underlying event loop
