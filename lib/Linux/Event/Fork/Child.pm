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

  $child->stdin_write("input");
  $child->close_stdin;

  $child->cancel;   # idempotent teardown

=head1 DESCRIPTION

This object represents a single spawned child process, its pid subscription, and
optional stdout/stderr capture watchers.

=head2 INTERNAL BUT DOCUMENTED

This class is considered an internal implementation detail of the distribution
and may evolve, but it is fully documented so users can reason about behavior.

In particular, teardown is explicit and idempotent, and output callbacks are
delivered with drain-first semantics.

=head1 METHODS

=head2 pid

Return the child PID.

=head2 data

Return the user C<data> associated with the handle (if any).

=head2 kill

  $child->kill('TERM');

Send a signal to the child.

=head2 stdin_write, close_stdin

Write bytes to the child's stdin pipe (if enabled) and optionally close it.

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
    sub_pid => undef,

    saw_exit => 0,
    exit     => undef,

    # Correct initialization: EOF only if we are not capturing that stream.
    eof_out  => 1,  # fixed below
    eof_err  => 1,  # fixed below

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

  my $off = 0;
  my $len = length($bytes);

  while ($off < $len) {
    my $w = syswrite($fh, $bytes, $len - $off, $off);
    if (!defined $w) {
      next if $! == EINTR;
      last if $! == EAGAIN;
      croak "syswrite(stdin): $!";
    }
    last if $w == 0;
    $off += $w;
  }

  return $off;
}

sub close_stdin ($self) {
  my $fh = delete $self->{in_w} or return 1;
  close($fh);
  return 1;
}

sub cancel ($self) {
  return 0 if $self->{_canceled};
  $self->{_canceled} = 1;

  if (my $sub = delete $self->{sub_pid}) { $sub->cancel }
  if (my $w = delete $self->{w_out}) { $w->cancel }
  if (my $w = delete $self->{w_err}) { $w->cancel }

  if (my $fh = delete $self->{out_r}) { close($fh) }
  if (my $fh = delete $self->{err_r}) { close($fh) }
  if (my $fh = delete $self->{in_w})  { close($fh) }

  return 1;
}

sub _arm ($self) {
  my $loop = $self->{loop};

  if ($self->{out_r}) {
    $self->{eof_out} = 0;  # ensure correct even if caller mutated state
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

  $self->{sub_pid} = $loop->pid($self->{pid}, sub ($loop, $pid2, $status, $ud) {
    $ud->_on_exit($status);
  }, data => $self);

  return;
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
