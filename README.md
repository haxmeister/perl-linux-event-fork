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

### What is `$chunk`?

`$chunk` is a raw byte string from `sysread()` on the child's stdout/stderr pipe.
It is **not** line-oriented. Boundaries are arbitrary; buffer in user code if you
want lines or message framing.

## Capture options

By default, stdout and stderr are captured only when you supply the corresponding
callback (`on_stdout`, `on_stderr`).

You may override:

- `capture_stdout => 1` captures stdout even without `on_stdout` (output is drained and discarded)
- `capture_stdout => 0` disables capture even if `on_stdout` is provided
- `capture_stderr => 1` captures stderr even without `on_stderr` (output is drained and discarded)
- `capture_stderr => 0` disables capture even if `on_stderr` is provided

These are useful to prevent the child from blocking on full pipes while you choose
whether to observe output.

## Child setup options (cwd/env/umask)

These options apply **in the child** after stdio plumbing is set up and **before**
`exec` (or before your `child => sub { ... }` callback is invoked).

- `cwd => "/path"`: `chdir` in child
- `umask => 027`: `umask` in child
- `env => { KEY => "value" }`: overlays into `%ENV` in child (inherits existing env)
- `clear_env => 1`: start from an empty `%ENV` before applying `env`

Overlay behavior:

```perl
%ENV = (%ENV, %$env);
```

Clear behavior:

```perl
%ENV = ();
%ENV = (%ENV, %$env);   # if env provided
```

## Child callback failures

If you use `child => sub { ... }` and the callback throws an exception or returns
normally (instead of calling `exec`), the child exits with status **127** and Fork
writes a short best-effort diagnostic to the child's STDERR:

```
Linux::Event::Fork child error: ...
```

If you capture stderr, this diagnostic can be observed in the parent.
