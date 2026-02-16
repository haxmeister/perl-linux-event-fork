# Linux::Event::Fork

Policy-layer async child spawning for **Linux::Event**.

This distribution stays out of `Linux::Event`'s core: it builds on public primitives
(`$loop->watch`, `$loop->pid`) and installs an *opt-in* convenience method:

- `use Linux::Event::Fork;` installs `$loop->fork(...)` into `Linux::Event::Loop`

## Stdin streaming (backpressure-aware)

To stream to a child's stdin after spawn, enable an explicit stdin pipe:

```perl
my $child = $loop->fork(
  stdin_pipe => 1,
  child => sub { ... },
);

$child->stdin_write($bytes);
$child->close_stdin;
```

If you instead use `stdin => $bytes` at spawn time, Fork will write those bytes
and (by default) close stdin immediately.

