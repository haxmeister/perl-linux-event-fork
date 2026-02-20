# Linux::Event::Fork

[![CI](https://github.com/haxmeister/perl-linux-event-fork/actions/workflows/ci.yml/badge.svg)](https://github.com/haxmeister/perl-linux-event-fork/actions/workflows/ci.yml)

Minimal async child process management on top of **Linux::Event**.

---

## Synopsis

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

## Description

`Linux::Event::Fork` provides structured, non-blocking child process
management integrated with `Linux::Event`.

Features:

- Nonblocking stdout/stderr capture
- Optional streaming stdin
- Timeout with optional SIGKILL escalation
- Controlled parallelism (`max_children`)
- FIFO queueing of excess work
- Drain callback when all work completes
- Cancel queued requests
- Runtime adjustment of `max_children`

---

## Controlled Parallelism

Concurrency is controlled via the constructor:

```perl
my $forker = Linux::Event::Fork->new($loop, max_children => 4);
```

When `running >= max_children`, additional `spawn()` calls return a
`Linux::Event::Fork::Request` object and are queued.

Increasing the limit at runtime:

```perl
$forker->max_children(8);
```

may immediately start queued work.

---

## Return Values

`spawn()` returns:

- `Linux::Event::Fork::Child`  — if the child started immediately
- `Linux::Event::Fork::Request` — if queued due to capacity limits

This allows explicit handling of queued work when desired.

---

## Execution Model

All `on_*` callbacks run in the **parent process** inside the event loop.

Only the `child => sub { ... }` callback runs in the **child process**.

---

## CI Notes

If GitHub Actions fails during:

```
Run shogo82148/actions-setup-perl@v1
install perl
Error: Error: failed to verify ...
```

This is an upstream attestation verification issue in the action, not a
problem with this distribution.

If it occurs, you can fix CI by either:

1. Pinning to a specific action release tag instead of `@v1`
2. Disabling verification in the action config (if supported)
3. Switching to an alternative Perl setup action

This does not affect CPAN builds.

---

See the `examples/` directory for additional usage patterns.
