# Linux::Event::Fork

## Minimal timeout

You can set a simple wall-clock timeout (seconds). When it fires, Fork:

1) invokes `on_timeout` (if provided), then
2) sends `TERM` to the child once

Exit handling remains drain-first; `on_exit` still runs only after the child has
exited and any captured pipes have reached EOF.

```perl
$loop->fork(
  timeout => 2.5,
  on_timeout => sub ($child) {
    warn "timed out: " . ($child->tag // $child->pid);
  },

  cmd => [ ... ],
);
```

This is intentionally minimal (no escalation, no restart policy).
