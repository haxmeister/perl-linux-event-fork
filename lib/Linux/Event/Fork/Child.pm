package Linux::Event::Fork::Child;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.007';

use Carp qw(croak);
use Errno qw(EAGAIN EINTR EPIPE);

use POSIX ();

use Linux::Event::Fork::Exit ();

sub _new ($class, %args) {
  my $self = bless {
    loop => delete $args{loop},
    pid  => delete $args{pid},

    tag  => delete $args{tag},
    data => delete $args{data},

    out_r => delete $args{out_r},
    err_r => delete $args{err_r},
    in_w  => delete $args{in_w},

    on_stdout => delete $args{on_stdout},
    on_stderr => delete $args{on_stderr},
    on_exit   => delete $args{on_exit},

    timeout_id  => undef,
    timeout_kill_id => undef,
    on_timeout  => delete $args{on_timeout},
    timeout      => delete $args{timeout},
    timeout_kill => delete $args{timeout_kill},
    timed_out   => 0,

    capture_stdout => delete $args{capture_stdout},
    capture_stderr => delete $args{capture_stderr},

    w_out   => undef,
    w_err   => undef,
    w_in    => undef,
    sub_pid => undef,

    saw_exit => 0,
    exit     => undef,

    eof_out  => 1,
    eof_err  => 1,

    in_buf  => '',
    in_off  => 0,
    in_close_when_empty => 0,

    _canceled => 0,

    managed_by_fork => delete $args{managed_by_fork},
  }, $class;

  croak "loop missing" if !$self->{loop};
  croak "pid missing"  if !$self->{pid};

  croak "unknown args: " . join(", ", sort keys %args) if %args;

  $self->{eof_out} = $self->{out_r} ? 0 : 1;
  $self->{eof_err} = $self->{err_r} ? 0 : 1;

  return $self;
}

sub exit ($self) { return $self->{exit} }
sub pid  ($self) { return $self->{pid} }
sub loop ($self) { return $self->{loop} }
sub tag  ($self) { return $self->{tag} }
sub data ($self) { return $self->{data} }
sub is_running ($self) { return $self->{saw_exit} ? 0 : 1 }

sub kill ($self, $sig = 'TERM') {
  return 0 if !$self->{pid};
  my $ok = kill($sig, $self->{pid});
  return $ok ? 1 : 0;
}

sub stdin_write ($self, $bytes) {
  my $fh = $self->{in_w} or return 0;
  return 0 if !defined $bytes || $bytes eq '';
  return 0 if $self->{in_close_when_empty};

  $self->{in_buf} .= $bytes;

  my $wrote = $self->_drain_stdin;

  if (!$self->{_canceled} && $self->{in_w} && length($self->{in_buf}) > $self->{in_off}) {
    if (my $w = $self->{w_in}) {
      $w->enable_write if $w->can('enable_write');
    }
  }

  return $wrote;
}

sub close_stdin ($self) {
  return 1 if $self->{_canceled};

  my $fh = $self->{in_w} or return 1;

  if (length($self->{in_buf}) <= $self->{in_off}) {
    $self->_close_stdin_now;
    return 1;
  }

  $self->{in_close_when_empty} = 1;

  if (my $w = $self->{w_in}) {
    $w->enable_write if $w->can('enable_write');
  }

  return 1;
}

sub _close_stdin_now ($self) {
  if (my $w = delete $self->{w_in}) { $w->cancel }
  if (my $fh = delete $self->{in_w}) { close($fh) }

  $self->{in_buf} = '';
  $self->{in_off} = 0;
  $self->{in_close_when_empty} = 0;

  return;
}

sub _cancel($self) {
  return 0 if $self->{_canceled};
  $self->{_canceled} = 1;

  # If max_children is managing capacity, keep exit observation alive until we
  # actually see the exit status. Otherwise the queue could stall forever.
  my $keep_exit = $self->{managed_by_fork} && !$self->{saw_exit} ? 1 : 0;

  if (!$keep_exit) {
    if (defined(my $tid = delete $self->{timeout_id})) {
      $self->{loop}->cancel($tid);
    }
    if (defined(my $tid = delete $self->{timeout_kill_id})) {
      $self->{loop}->cancel($tid);
    }
    if (my $sub = delete $self->{sub_pid}) { $sub->cancel }
  }

  if (my $w = delete $self->{w_out}) { $w->cancel }
  if (my $w = delete $self->{w_err}) { $w->cancel }
  if (my $w = delete $self->{w_in})  { $w->cancel }

  if (my $fh = delete $self->{out_r}) { close($fh) }
  if (my $fh = delete $self->{err_r}) { close($fh) }
  if (my $fh = delete $self->{in_w})  { close($fh) }

  return 1;
}

sub _arm ($self) {
  my $loop = $self->{loop};

  if ($self->{out_r}) {
    $self->{eof_out} = 0;
    $self->{w_out} = $loop->watch($self->{out_r},
      read  => sub ($loop, $fh, $w) { $self->_drain_stream('out') },
      error => sub ($loop, $fh, $w) { $self->_drain_stream('out') },
    );
  } else {
    $self->{eof_out} = 1;
  }

  if ($self->{err_r}) {
    $self->{eof_err} = 0;
    $self->{w_err} = $loop->watch($self->{err_r},
      read  => sub ($loop, $fh, $w) { $self->_drain_stream('err') },
      error => sub ($loop, $fh, $w) { $self->_drain_stream('err') },
    );
  } else {
    $self->{eof_err} = 1;
  }

  if ($self->{in_w}) {
    $self->{w_in} = $loop->watch($self->{in_w},
      write => sub ($loop, $fh, $w) { $self->_on_stdin_writable($w) },
      error => sub ($loop, $fh, $w) { $self->_on_stdin_writable($w) },
    );

    if (length($self->{in_buf}) <= $self->{in_off}) {
      $self->{w_in}->disable_write if $self->{w_in}->can('disable_write');
    }
  }

  $self->{sub_pid} = $loop->pid($self->{pid}, sub ($loop, $pid2, $status, $ud) {
    $ud->_on_exit($status);

  # Race hardening: if the child exits before pidfd observation is armed,
  # pid() may never deliver a callback. Perform a non-blocking waitpid check.
  if (!$self->{saw_exit}) {
    my $got = POSIX::waitpid($self->{pid}, POSIX::WNOHANG());
    if ($got == $self->{pid}) {
      $self->_on_exit($?);
    }
  }
  }, data => $self);

  if (defined $self->{timeout} && $self->{timeout} > 0) {
    my $secs = 0 + $self->{timeout};
    $self->{timeout_id} = $loop->after($secs, sub ($loop) { $self->_on_timeout });
  }

  return;
}

sub _on_timeout ($self) {
  return if $self->{_canceled};
  return if $self->{saw_exit};
  return if $self->{timed_out};

  $self->{timed_out} = 1;

  if (my $cb = $self->{on_timeout}) {
    $cb->($self);
  }

  $self->kill('TERM');

  if (defined $self->{timeout_kill} && $self->{timeout_kill} > 0) {
    my $secs = 0 + $self->{timeout_kill};
    my $loop = $self->{loop};
    $self->{timeout_kill_id} = $loop->after($secs, sub ($loop) { $self->_on_timeout_kill });
  }
  return;
}

sub _on_timeout_kill ($self) {
  return if $self->{_canceled};
  return if $self->{saw_exit};

  # Hard stop: the child ignored/handled TERM.
  $self->kill('KILL');
  return;
}

sub _on_stdin_writable ($self, $w) {
  return if $self->{_canceled};
  return if !$self->{in_w};

  $self->_drain_stdin;

  if ($self->{in_w} && length($self->{in_buf}) <= $self->{in_off}) {
    if ($self->{in_close_when_empty}) {
      $self->_close_stdin_now;
      return;
    }
    $w->disable_write if $w && $w->can('disable_write');
  }

  return;
}

sub _drain_stdin ($self) {
  my $fh = $self->{in_w} or return 0;

  my $buf = $self->{in_buf};
  my $off = $self->{in_off};
  my $len = length($buf);

  my $wrote_total = 0;

  local $SIG{PIPE} = 'IGNORE';

  while ($off < $len) {
    my $w = syswrite($fh, $buf, $len - $off, $off);
    if (!defined $w) {
      next if $! == EINTR;
      last if $! == EAGAIN;
      if ($! == EPIPE) {
        $self->_close_stdin_now;
        return $wrote_total;
      }
      $self->_close_stdin_now;
      return $wrote_total;
    }
    last if $w == 0;
    $off += $w;
    $wrote_total += $w;
  }

  $self->{in_off} = $off;

  if ($off >= $len) {
    $self->{in_buf} = '';
    $self->{in_off} = 0;
  } else {
    if ($off > 65536) {
      substr($buf, 0, $off, '');
      $self->{in_buf} = $buf;
      $self->{in_off} = 0;
    }
  }

  return $wrote_total;
}

sub _on_exit ($self, $status) {
  return if $self->{saw_exit};
  $self->{saw_exit} = 1;
  $self->{exit} = Linux::Event::Fork::Exit->new($self->{pid}, $status);

  $self->_maybe_finish;
  return;
}

sub _drain_stream ($self, $which) {
  return if $self->{_canceled};

  my ($fh_key, $w_key, $cb_key, $eof_key) =
    $which eq 'out'
      ? ('out_r','w_out','on_stdout','eof_out')
      : ('err_r','w_err','on_stderr','eof_err');

  my $fh = $self->{$fh_key} or do {
    $self->{$eof_key} = 1;
    $self->_maybe_finish;
    return;
  };

  my $cb = $self->{$cb_key};

  while (1) {
    my $buf = '';
    my $n = sysread($fh, $buf, 8192);

    if (!defined $n) {
      next if $! == EINTR;
      last if $! == EAGAIN;
      $n = 0;
    }

    if ($n == 0) {
      if (my $w = delete $self->{$w_key}) { $w->cancel }
      close($fh);
      $self->{$fh_key} = undef;

      $self->{$eof_key} = 1;
      $self->_maybe_finish;
      last;
    }

    $cb->($self, $buf) if $cb;
  }

  return;
}

sub _maybe_finish ($self) {
  return if !$self->{saw_exit};
  return if !$self->{eof_out};
  return if !$self->{eof_err};

  if (my $cb = $self->{on_exit}) {
    $cb->($self, $self->{exit});
  }

  # Now safe to fully tear down everything, even for managed children.
  $self->{_canceled} = 0; # allow cancel() to run full teardown path
  $self->{managed_by_fork} = undef;
  $self->_cancel;

  return;
}

1;

__END__

=head1 NAME

Linux::Event::Fork::Child - Handle for a running child process

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;
  use Linux::Event::Fork;

  my $loop = Linux::Event->new;

  my $child = $loop->fork(
    cmd => [qw(/bin/echo hello)],

    on_stdout => sub ($child, $bytes) {
      print "stdout: $bytes";
    },

    on_stderr => sub ($child, $bytes) {
      print "stderr: $bytes";
    },

    on_timeout => sub ($child) {
      warn "child timed out (pid=" . $child->pid . ")\n";
    },

    on_exit => sub ($child, $exit) {
      my $status = $exit->status;
      print "pid " . $child->pid . " exited with status $status\n";
    },
  );

  $loop->run;

=head1 DESCRIPTION

A B<Linux::Event::Fork::Child> object represents a child process that has already
started running.

It provides:

=over 4

=item * Metadata access (pid, tag, data)

=item * Nonblocking writes to the child's stdin (optional)

=item * Signal delivery (kill)

=item * Parent-side lifecycle callbacks (stdout/stderr/exit/timeout)

=back

Child objects are returned by C<< $loop->fork(...) >> when the child starts
immediately. If the request is queued due to C<max_children>, the fork call
returns a L<Linux::Event::Fork::Request> instead.

=head1 LAYERING

This object is part of L<Linux::Event::Fork> (process management). It is not part
of the socket I/O stack.

For sockets and buffered I/O, see:

=over 4

=item * L<Linux::Event::Listen> - accept produces an accepted fh

=item * L<Linux::Event::Connect> - connect produces a connected fh

=item * L<Linux::Event::Stream> - buffered I/O + backpressure, owns the fh

=back

=head1 EXECUTION MODEL

All methods on this object are called from the B<parent process>.

The only code that runs in the child process is your fork specification:

=over 4

=item * C<< cmd => [...] >> (exec)

=item * C<< child => sub { ... } >> (runs in child)

=back

Callbacks such as C<on_stdout>, C<on_stderr>, C<on_exit>, and C<on_timeout> run in
the parent, inside the Linux::Event event loop.

=head1 CALLBACK CONTRACT

Callbacks stored on the child are invoked with these signatures:

=head2 on_stdout / on_stderr

  on_stdout => sub ($child, $bytes) { ... }
  on_stderr => sub ($child, $bytes) { ... }

C<$bytes> is a byte string read from the corresponding pipe. Chunk sizing is an
implementation detail; do not depend on a specific size.

If no handler is provided (and capture is not forced), the corresponding stream
may not be captured.

=head2 on_timeout

  on_timeout => sub ($child) { ... }

Invoked when the timeout expires (as configured by the fork request). Timeout
handling may send TERM and (optionally) escalate to KILL; see L<Linux::Event::Fork>
for request-level timeout options.

=head2 on_exit

  on_exit => sub ($child, $exit) { ... }

Invoked once when the child has exited and any enabled stdout/stderr streams have
reached EOF.

C<$exit> is a L<Linux::Event::Fork::Exit> object containing the raw wait status
and convenience accessors.

=head1 METHODS

=head2 pid

  my $pid = $child->pid;

Returns the PID of the running child.

=head2 loop

  my $loop = $child->loop;

Returns the owning loop instance.

=head2 tag

  my $tag = $child->tag;

Returns the tag associated with the fork request (if any).

=head2 data

  my $data = $child->data;

Returns the arbitrary data payload associated with the fork request (if any).

=head2 kill

  my $ok = $child->kill($signal);

Sends a signal to the child process. Returns true on success.

The default signal is C<TERM>:

  $child->kill;         # TERM
  $child->kill('KILL'); # KILL

=head2 stdin_write

  my $n = $child->stdin_write($bytes);

Queue bytes for writing to the child's stdin and attempt to write immediately.
Returns the number of bytes actually written synchronously during this call.

Remaining bytes (if any) are written later by the event loop when stdin becomes
writable.

If stdin is not available for this child (no stdin pipe was created), this
returns 0.

=head2 close_stdin

  $child->close_stdin;

Closes the write end of the child's stdin.

If there are buffered bytes pending, stdin will be closed after the buffered
bytes are fully written.

=head1 LIFETIME NOTES

=over 4

=item * The Child object becomes inert after C<on_exit> runs.

=item * If stdout/stderr capture is enabled, C<on_exit> runs only after those
streams reach EOF (so you do not lose trailing output).

=item * Closing stdin early is explicit: call C<close_stdin> when you are done
writing.

=back

=head1 SEE ALSO

L<Linux::Event> - core event loop

L<Linux::Event::Listen> - server-side socket acquisition

L<Linux::Event::Connect> - client-side socket acquisition

L<Linux::Event::Fork> - asynchronous child processes

L<Linux::Event::Clock> - high resolution monotonic clock utilities

=head1 AUTHOR

Joshua S. Day

=head1 LICENSE

Same terms as Perl itself.

=cut
