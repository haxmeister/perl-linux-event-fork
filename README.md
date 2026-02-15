# Linux::Event::Fork

Policy-layer async child spawning for **Linux::Event**.

This distribution stays out of `Linux::Event`'s core: it builds on public primitives
(`$loop->watch`, `$loop->pid`) and installs an *opt-in* convenience method:

- `use Linux::Event::Fork;` installs `$loop->fork(...)` into `Linux::Event::Loop`

## Design

- No supervision semantics (no restarts/backoff)
- No framework behavior
- Explicit teardown; idempotent `cancel`
- Drain-first: `on_exit` fires only after exit observed **and** captured pipes reach EOF

## Quick start

```perl
use v5.36;
use Linux::Event;
use Linux::Event::Fork;

my $loop = Linux::Event->new;

$loop->fork(
  cmd => [ $^X, '-we', 'print "ok\n"; exit 0' ],
  on_stdout => sub ($child, $chunk) { print $chunk },
  on_exit   => sub ($child, $exit)  { $loop->stop },
);

$loop->run;
```

## Callback contracts

- `on_stdout => sub ($child, $chunk) { ... }`
- `on_stderr => sub ($child, $chunk) { ... }`
- `on_exit   => sub ($child, $exit)  { ... }` where `$exit` is a `Linux::Event::Fork::Exit` object

See the POD in `Linux::Event::Fork` and `Linux::Event::Fork::Exit`.
