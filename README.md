\
# Linux::Event::Fork

Minimal async child spawning on top of **Linux::Event**.

This is a **policy-layer** distribution: it keeps `Linux::Event` core pristine, and
builds child spawning using only public primitives:

- `$loop->watch(...)` for pipes (stdout/stderr/stdin)
- `$loop->pid(...)` for exit observation
- `$loop->after(...)` for timeouts

## Design goals

- **No supervision semantics**: no restarts, backoff, or retry policy.
- **No framework behavior**: explicit callbacks and explicit teardown.
- **Drain-first**: `on_exit` fires only after the child has exited **and** captured pipes reach EOF.
- **Low hot-path noise**: chunk delivery is raw bytes, no implicit parsing.

## Quick start

```perl
use v5.36;
use Linux::Event;
use Linux::Event::Fork;   # installs $loop->fork

my $loop = Linux::Event->new;

$loop->fork(
  tag => "demo",
  cmd => [ $^X, '-we', 'print "hi\n"; exit 0' ],

  on_stdout => sub ($child, $chunk) {
    print "[stdout] $chunk";
  },

  on_exit => sub ($child, $exit) {
    say "exit=" . ($exit->exited ? $exit->code : 'n/a');
    $loop->stop;
  },
);

$loop->run;
```

## Callback contracts

- `on_stdout => sub ($child, $chunk) { ... }`
- `on_stderr => sub ($child, $chunk) { ... }`
- `on_exit   => sub ($child, $exit)  { ... }` where `$exit` is a `Linux::Event::Fork::Exit`

`$chunk` is a raw byte string from `sysread()` and is **not line oriented**.
If you want lines/messages, buffer and split in user code.

## Spawn forms

Exactly one of:

### `cmd`

```perl
cmd => [ $program, @argv ]
```

Uses `exec`. If `exec` fails, the child exits **127** and writes a short message to stderr.

### `child`

```perl
child => sub {
  exec "myprogram", "arg1";
}
```

Runs Perl in the child after stdio plumbing and setup options. If it throws or returns,
the child exits **127** and writes a short message to stderr.

## Stdin

### One-shot stdin bytes

```perl
stdin => $bytes
```

Creates a pipe, writes the bytes, and closes stdin.

### Streaming stdin with backpressure

```perl
stdin_pipe => 1
```

Creates a pipe and keeps it open; you can stream:

```perl
$child->stdin_write($bytes);
$child->close_stdin;
```

Fork ignores SIGPIPE during writes and treats EPIPE as a normal close condition.

## Minimal timeout

```perl
timeout => 2.5,
on_timeout => sub ($child) {
  warn "timed out: " . ($child->tag // $child->pid);
},
```

When the timer fires and the child is still running:

1) calls `on_timeout` (if provided)  
2) sends `TERM` to the child **once**

No escalation to `KILL`, no restarts.

## Output capture controls

By default, a pipe is only created if its callback is provided.

Override with:

- `capture_stdout => 1|0`
- `capture_stderr => 1|0`

If you enable capture without a callback, Fork drains the pipe and discards output
so the child cannot block on a full pipe.

## Setup options (child-side)

Applied in the child after stdio plumbing and before exec/callback:

- `cwd => "/path"`
- `umask => 027`
- `env => { KEY => "value" }` (overlays onto inherited `%ENV`)
- `clear_env => 1` (start from empty `%ENV` before overlay)

## Metadata

- `tag => $label` for identity/logging
- `data => $opaque` for an arbitrary user payload

Both are available on the returned handle (`Linux::Event::Fork::Child`).

## Stress tests

See `examples/README.md` for the 90/91 stress scripts and environment controls.

## License

Same terms as Perl itself.
