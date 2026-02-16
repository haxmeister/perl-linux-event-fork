package Linux::Event::Fork::Child;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

use Carp qw(croak);
use Errno qw(EAGAIN EINTR);

use Linux::Event::Fork::Exit ();

=head1 NAME

Linux::Event::Fork::Child - Child handle returned by Linux::Event::Fork

=head1 SYNOPSIS

  my $child = $loop->fork(...);

  $child->pid;
  $child->kill('TERM');

  # Streaming stdin:
  $child->stdin_write($bytes);
  $child->close_stdin;   # close when all queued bytes are written

  $child->cancel;        # idempotent teardown

=head1 DESCRIPTION

This object represents a single spawned child process, its pid subscription, and
optional stdout/stderr capture watchers.

=head2 INTERNAL BUT DOCUMENTED

This class is considered an internal implementation detail of the distribution
and may evolve, but it is fully documented so users can reason about behavior.

In particular, teardown is explicit and idempotent, output callbacks are delivered
with drain-first semantics, and stdin streaming uses backpressure-aware writes.

=head1 METHODS

=head2 pid

Return the child PID.

=head2 data

Return the user C<data> associated with the handle (if any).

=head2 kill

  $child->kill('TERM');

Send a signal to the child.

=head2 stdin_write

  $child->stdin_write($bytes);

Queue bytes to be written to the child's stdin pipe (if enabled).

This method is non-blocking and may write some bytes immediately if possible.
Remaining bytes are queued and written later when the pipe becomes writable.

Returns the number of bytes written immediately in this call (which may be 0).

=head2 close_stdin

  $child->close_stdin;

Request that stdin be closed once all queued bytes have been written. If no bytes
are queued, the stdin pipe is closed immediately.

=head2 cancel

Idempotently cancels watchers/subscriptions and closes owned filehandles.

=cut

sub _new ($class, %args) {
  my $self = bless {
    loop => delete $args{loop},
    pid  => delete $args{pid},

    out_r => delete $args{out_r},
    err_r => delete $args{err_r},
    in_w  => delete $args{in_w},

    on_stdout => delete $args{on_stdout},
    on_stderr => delete $args{on_stderr},
    on_exit   => delete $args{on_exit},

    data => delete $args{data},

    capture_stdout => delete $args{capture_stdout},
    capture_stderr => delete $args{capture_stderr},

    w_out   => undef,
    w_err   => undef,
    w_in    => undef,
    sub_pid => undef,

    saw_exit => 0,
    exit     => undef,

    eof_out  => 1,  # fixed below
    eof_err  => 1,  # fixed below

    # stdin streaming/backpressure
    in_buf  => '',     # pending bytes
    in_off  => 0,      # offset into in_buf
    in_close_when_empty => 0,

    _canceled => 0,
  }, $class;

  croak "loop missing" if !$self->{loop};
  croak "pid missing"  if !$self->{pid};
  croak "unknown args: " . join(", ", sort keys %args) if %args;

  $self->{eof_out} = $self->{out_r} ? 0 : 1;
  $self->{eof_err} = $self->{err_r} ? 0 : 1;

  return $self;
}

sub pid  ($self) { return $self->{pid} }
sub loop ($self) { return $self->{loop} }
sub data ($self) { return $self->{data} }

sub kill ($self, $sig = 'TERM') {
  return 0 if !$self->{pid};
  my $ok = kill($sig, $self->{pid});
  return $ok ? 1 : 0;
}

sub stdin_write ($self, $bytes) {
  my $fh = $self->{in_w} or return 0;
  return 0 if !defined $bytes || $bytes eq '';
  return 0 if $self->{in_close_when_empty};

  # Append to queue.
  $self->{in_buf} .= $bytes;

  # Try immediate drain.
  my $wrote = $self->_drain_stdin;

  # Ensure write watcher is armed/enabled if we still have pending bytes.
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

  # If nothing pending, close immediately.
  if (length($self->{in_buf}) <= $self->{in_off}) {
    $self->_close_stdin_now;
    return 1;
  }

  $self->{in_close_when_empty} = 1;

  # Ensure watcher is enabled if armed.
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

sub cancel ($self) {
  return 0 if $self->{_canceled};
  $self->{_canceled} = 1;

  if (my $sub = delete $self->{sub_pid}) { $sub->cancel }
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

  # stdin write watcher is only needed if we have a stdin pipe.
  if ($self->{in_w}) {
    $self->{w_in} = $loop->watch($self->{in_w},
      write => sub ($loop, $fh, $w) { $self->_on_stdin_writable($w) },
      error => sub ($loop, $fh, $w) { $self->_on_stdin_writable($w) },
    );

    # If nothing pending, disable write to avoid wakeups.
    if (length($self->{in_buf}) <= $self->{in_off}) {
      $self->{w_in}->disable_write if $self->{w_in}->can('disable_write');
    }
  }

  $self->{sub_pid} = $loop->pid($self->{pid}, sub ($loop, $pid2, $status, $ud) {
    $ud->_on_exit($status);
  }, data => $self);

  return;
}

sub _on_stdin_writable ($self, $w) {
  return if $self->{_canceled};
  return if !$self->{in_w};

  $self->_drain_stdin;

  # If drained fully, disable write until we get more data.
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

  while ($off < $len) {
    my $w = syswrite($fh, $buf, $len - $off, $off);
    if (!defined $w) {
      next if $! == EINTR;
      last if $! == EAGAIN;
      # Treat other errors as fatal: close stdin.
      $self->_close_stdin_now;
      return $wrote_total;
    }
    last if $w == 0;
    $off += $w;
    $wrote_total += $w;
  }

  $self->{in_off} = $off;

  # Compact buffer when fully consumed.
  if ($off >= $len) {
    $self->{in_buf} = '';
    $self->{in_off} = 0;
  } else {
    # Periodic compaction if offset grows large.
    if ($off > 65536) {
      substr($buf, 0, $off, '');
      $self->{in_buf} = $buf;
      $self->{in_off} = 0;
    }
  }

  return $wrote_total;
}

sub _on_exit ($self, $status) {
  return if $self->{_canceled};
  $self->{saw_exit} = 1;
  $self->{exit} = Linux::Event::Fork::Exit->new($status);
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
      $n = 0; # treat other errors as EOF
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
  return if $self->{_canceled};
  return if !$self->{saw_exit};
  return if !$self->{eof_out};
  return if !$self->{eof_err};

  if (my $cb = $self->{on_exit}) {
    $cb->($self, $self->{exit});
  }

  $self->cancel;
  return;
}

1;
