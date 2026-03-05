package Linux::Event::Fork;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.007';

use Carp qw(croak);
use POSIX ();
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

use Linux::Event::Fork::Child ();
use Linux::Event::Fork::Request ();


sub new ($class, $loop, %args) {
  croak "loop is required" if !$loop || !ref($loop);

  my $max_children = delete $args{max_children};
  $max_children = 0 if !defined $max_children;
  croak "max_children must be a non-negative integer" if $max_children !~ /^\d+$/;

  croak "unknown args: " . join(", ", sort keys %args) if %args;

  return bless {
    loop => $loop,
    max_children => 0 + $max_children,
    running => 0,
    queue => [],
  }, $class;
}

sub loop ($self)    {return $self->{loop} }
sub running ($self) {return $self->{running} }
sub queued ($self)  {return scalar @{ $self->{queue} } }

sub max_children ($self, $new = undef) {
  if (defined $new) {
    croak "max_children must be a non-negative integer"
      if $new !~ /^\d+$/;

    $self->{max_children} = 0 + $new;

    # If we increased the limit, try to start queued work.
    while ($self->{max_children} && $self->{running} < $self->{max_children}) {
      my $req = shift @{ $self->{queue} } or last;
      next if $req->_canceled;
      $req->_start;
    }

    $self->_maybe_fire_drain;
  }

  return $self->{max_children};
}

sub spawn ($self, %spec) {
  # Controlled parallelism: if max_children is set and we are at capacity,
  # enqueue the request and return a Request handle.
  if ($self->{max_children} && $self->{running} >= $self->{max_children}) {
    my $req = Linux::Event::Fork::Request->_new(fork => $self, spec => \%spec);
    push @{ $self->{queue} }, $req;
    return $req;
  }

  return $self->_spawn_now(\%spec);
}

sub _spawn_now ($self, $spec) {
  my %spec = %$spec;

  my $cmd   = delete $spec{cmd};
  my $child = delete $spec{child};

  if (defined $cmd && defined $child) {
    croak "provide exactly one of cmd or child";
  }
  if (!defined $cmd && !defined $child) {
    croak "cmd or child is required";
  }

  if (defined $cmd) {
    croak "cmd must be an arrayref" if ref($cmd) ne 'ARRAY' || !@$cmd;
  } else {
    croak "child must be a coderef" if ref($child) ne 'CODE';
  }

  my $on_stdout  = delete $spec{on_stdout};
  my $on_stderr  = delete $spec{on_stderr};
  my $on_exit    = delete $spec{on_exit};
  my $on_timeout = delete $spec{on_timeout};
  my $timeout    = delete $spec{timeout};
  my $timeout_kill = delete $spec{timeout_kill};
  my $on_start   = delete $spec{on_start};

  my $tag  = delete $spec{tag};
  my $data = delete $spec{data};

  croak "on_stdout must be a coderef"  if defined($on_stdout)  && ref($on_stdout)  ne 'CODE';
  croak "on_stderr must be a coderef"  if defined($on_stderr)  && ref($on_stderr)  ne 'CODE';
  croak "on_exit must be a coderef"    if defined($on_exit)    && ref($on_exit)    ne 'CODE';
  croak "on_timeout must be a coderef" if defined($on_timeout) && ref($on_timeout) ne 'CODE';
  croak "on_start must be a coderef"   if defined($on_start)   && ref($on_start)   ne 'CODE';
  croak "timeout must be numeric seconds" if defined($timeout) && ref($timeout);
  croak "timeout_kill must be numeric seconds" if defined($timeout_kill) && ref($timeout_kill);

  my $capture_stdout = delete $spec{capture_stdout};
  my $capture_stderr = delete $spec{capture_stderr};

  my $stdin      = delete $spec{stdin};
  my $stdin_pipe = delete $spec{stdin_pipe};
  $stdin_pipe = $stdin_pipe ? 1 : 0 if defined $stdin_pipe;

  my $cwd       = delete $spec{cwd};
  my $umask     = delete $spec{umask};
  my $env       = delete $spec{env};
  my $clear_env = delete $spec{clear_env};

  croak "cwd must be a string" if defined($cwd) && ref($cwd);
  croak "umask must be an integer" if defined($umask) && ref($umask);
  croak "env must be a hashref" if defined($env) && ref($env) ne 'HASH';
  $clear_env = $clear_env ? 1 : 0 if defined $clear_env;

  croak "unknown args: " . join(", ", sort keys %spec) if %spec;

  $capture_stdout = defined($capture_stdout) ? ($capture_stdout ? 1 : 0) : (defined($on_stdout) ? 1 : 0);
  $capture_stderr = defined($capture_stderr) ? ($capture_stderr ? 1 : 0) : (defined($on_stderr) ? 1 : 0);

  my ($out_r, $out_w);
  my ($err_r, $err_w);
  my ($in_r,  $in_w);

  if ($capture_stdout) {
    pipe($out_r, $out_w) or croak "pipe(stdout): $!";
    _set_nonblock($out_r);
  }
  if ($capture_stderr) {
    pipe($err_r, $err_w) or croak "pipe(stderr): $!";
    _set_nonblock($err_r);
  }

  my $want_stdin = (defined($stdin) || $stdin_pipe) ? 1 : 0;
  if ($want_stdin) {
    pipe($in_r, $in_w) or croak "pipe(stdin): $!";
    _set_nonblock($in_w);
  }

  my $pid = fork();
  croak "fork: $!" if !defined $pid;

  if ($pid == 0) {
    my $ok = eval {
      if ($want_stdin) {
        close($in_w);
        POSIX::dup2(fileno($in_r), fileno(*STDIN)) or die "dup2(stdin): $!";
      }
      if ($capture_stdout) {
        close($out_r);
        POSIX::dup2(fileno($out_w), fileno(*STDOUT)) or die "dup2(stdout): $!";
      }
      if ($capture_stderr) {
        close($err_r);
        POSIX::dup2(fileno($err_w), fileno(*STDERR)) or die "dup2(stderr): $!";
      }

      close($in_r)  if $want_stdin;
      close($out_w) if $capture_stdout;
      close($err_w) if $capture_stderr;

      if (defined $umask) {
        umask($umask) or die "umask($umask): $!";
      }
      if (defined $cwd) {
        chdir($cwd) or die "chdir($cwd): $!";
      }

      if ($clear_env) { %ENV = () }
      if (defined $env) { %ENV = (%ENV, %$env) }

      if (defined $cmd) {
        exec { $cmd->[0] } @$cmd;
        die "exec($cmd->[0]): $!";
      } else {
        $child->();
        die "child callback returned";
      }
    };

    if (!$ok) {
      my $err = $@;
      if (defined $err && $err ne '') {
        $err =~ s/\s+\z/\n/;
        syswrite(*STDERR, "Linux::Event::Fork child error: $err");
      }
    }

    POSIX::_exit(127);
  }

  close($out_w) if $capture_stdout;
  close($err_w) if $capture_stderr;
  close($in_r)  if $want_stdin;

  # Wrap on_exit so we always release capacity and start the next queued job,
  # even if user code throws.
  my $user_on_exit = $on_exit;
  my $managed = $self->{max_children} ? 1 : 0;

  $on_exit = sub ($child_obj, $exit_obj) {
    if ($user_on_exit) {
      eval { $user_on_exit->($child_obj, $exit_obj); 1 };
    }
    $self->_on_child_finished($child_obj) if $managed;
  };

  my $handle = Linux::Event::Fork::Child->_new(
    loop => $self->{loop},
    pid  => $pid,

    tag  => $tag,
    data => $data,

    out_r => $out_r,
    err_r => $err_r,
    in_w  => $in_w,

    on_stdout => $on_stdout,
    on_stderr => $on_stderr,
    on_exit   => $on_exit,

    timeout      => $timeout,

    timeout_kill => $timeout_kill,
    on_timeout     => $on_timeout,

    capture_stdout => $capture_stdout,
    capture_stderr => $capture_stderr,

    managed_by_fork => ($managed ? $self : undef),
  );

  $self->{running}++ if $managed;

  if ($on_start) {
    eval { $on_start->($handle); 1 };
  }

  if (defined $stdin && $stdin ne '') {
    $handle->stdin_write($stdin);
  }
  if (defined $stdin && !$stdin_pipe) {
    $handle->close_stdin;
  }

  $handle->_arm;
  return $handle;
}

sub _on_child_finished ($self, $child) {
  # Idempotent: a child should only finish once, but guard anyway.
  return if !$self->{running};
  $self->{running}--;

  # Start queued work, if any.
  while ($self->{max_children} && $self->{running} < $self->{max_children}) {
    my $req = shift @{ $self->{queue} } or last;
    next if $req->_canceled;
    $req->_start;
  }
  $self->_maybe_fire_drain;

  return;
}

sub drain ($self, %args) {
  my $on_done = delete $args{on_done};
  croak "on_done is required" if !defined $on_done;
  croak "on_done must be a coderef" if ref($on_done) ne 'CODE';
  croak "unknown args: " . join(", ", sort keys %args) if %args;

  $self->{_drain_on_done} = $on_done;

  $self->_maybe_fire_drain;

  return 1;
}

sub _maybe_fire_drain ($self) {
  my $cb = $self->{_drain_on_done} or return;

  return if $self->{running};
  return if @{ $self->{queue} };

  delete $self->{_drain_on_done};

  eval { $cb->($self); 1 };
  return;
}


sub cancel_queued ($self, $pred = undef) {
  croak "cancel_queued predicate must be a coderef" if defined($pred) && ref($pred) ne 'CODE';

  my $n = 0;
  my @keep;

  for my $req (@{ $self->{queue} }) {
    next if !defined $req;
    if (!$req->_canceled && (!defined($pred) || $pred->($req))) {
      $req->cancel;
      $n++;
      next;
    }
    push @keep, $req;
  }

  $self->{queue} = \@keep;

  $self->_maybe_fire_drain;

  return $n;
}



sub _set_nonblock ($fh) {
  my $flags = fcntl($fh, F_GETFL, 0);
  croak "fcntl(F_GETFL): $!" if !defined $flags;
  my $ok = fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
  croak "fcntl(F_SETFL,O_NONBLOCK): $!" if !$ok;
  return;
}

1;


__END__

=head1 NAME

Linux::Event::Fork - Asynchronous child process management for Linux::Event

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;
  use Linux::Event::Fork;

  my $loop = Linux::Event->new;

  # Configure the per-loop helper (optional):
  my $fork = $loop->fork_helper(max_children => 4);

  # Spawn a command:
  my $child = $loop->fork(
    cmd => [qw(/bin/echo hello)],

    on_stdout => sub ($child, $bytes) {
      print "stdout: $bytes";
    },

    on_exit => sub ($child, $exit) {
      my $pid    = $child->pid;
      my $status = $exit->status;
      print "pid $pid exited with status $status\n";
    },
  );

  # Drain: called when all running children have exited and the queue is empty.
  $fork->drain(on_done => sub ($fork) {
    $loop->stop;
  });

  $loop->run;

=head1 DESCRIPTION

B<Linux::Event::Fork> provides an asynchronous interface for starting child
processes while integrating with a L<Linux::Event> loop for:

=over 4

=item * stdout/stderr capture (nonblocking pipes)

=item * pid exit notifications

=item * optional timeouts and forced-kill escalation

=item * controlled parallelism (max concurrent children) with queuing

=back

It is intended to be explicit and composable: it does not implement a worker
framework or server model. It provides child handles and request handles that
you can integrate into your application structure.

=head1 LAYERING

This distribution is part of the Linux::Event ecosystem but is not part of the
socket I/O stack.

=over 4

=item * B<Linux::Event::Fork>

Process management: spawn children, capture output, observe exit, apply timeouts.

=item * B<Linux::Event::Listen / Connect / Stream>

Socket acquisition and buffered I/O. Fork does not accept/connect sockets and
does not provide stream buffering.

=back

Fork can be used alongside Stream inside a process (parent or worker). Filehandle
ownership remains explicit.

=head1 LOOP INTEGRATION

This module injects two methods into C<Linux::Event::Loop> at import time:

=head2 $loop->fork

  my $child_or_req = $loop->fork(%spec);

Spawns a new child (or enqueues the request when C<max_children> is reached).
Returns either:

=over 4

=item * L<Linux::Event::Fork::Child>

When started immediately.

=item * L<Linux::Event::Fork::Request>

When queued due to C<max_children> capacity.

=back

=head2 $loop->fork_helper

  my $fork = $loop->fork_helper(%opt);

Returns the per-loop helper object (creating it on first use). You may call
C<fork_helper> again later to adjust supported runtime options (currently:
C<max_children>).

=head1 CONTROLLED PARALLELISM

=head2 max_children

  my $fork = $loop->fork_helper(max_children => 8);

If C<max_children> is non-zero, the helper limits how many children may be
running at once. When at capacity, new spawn requests are queued and returned as
L<Linux::Event::Fork::Request> objects.

=head2 running / queued

  my $n = $fork->running;
  my $q = $fork->queued;

Introspection helpers: current running child count and queued request count.

=head2 drain

  $fork->drain(on_done => sub ($fork) { ... });

Registers a callback to be invoked once the helper is fully idle:

=over 4

=item * no running children

=item * and the queue is empty

=back

If the helper is already idle when you call C<drain>, the callback fires on the
next opportunity.

=head2 cancel_queued

  my $n = $fork->cancel_queued;
  my $n = $fork->cancel_queued(sub ($req) { ... });

Cancels queued (not yet started) requests. If a predicate is provided, only
requests for which the predicate returns true are cancelled.

Returns the number of requests cancelled.

=head1 SPAWN SPECIFICATION

Exactly one of these is required:

=head2 cmd

  cmd => [ $program, @argv ]

An arrayref. The child process uses C<exec> to replace itself.

=head2 child

  child => sub { ... }

A coderef executed in the child after fork. If it returns, the child exits with
a failure status.

=head1 CALLBACKS

Callbacks are optional unless stated otherwise. All callback arguments are
positional and are passed exactly as shown below.

=head2 on_start

  on_start => sub ($child) { ... }

Called in the parent process after the child handle is created and before the
child is armed (watched).

=head2 on_stdout / on_stderr

  on_stdout => sub ($child, $bytes) { ... }
  on_stderr => sub ($child, $bytes) { ... }

Called when captured stdout/stderr data is read from the child pipes.

If you supply C<on_stdout>, stdout capture is enabled automatically (same for
stderr). You may also force capture with C<capture_stdout> / C<capture_stderr>.

=head2 on_exit

  on_exit => sub ($child, $exit) { ... }

Called when the child exits. C<$exit> is an exit object (see
L<Linux::Event::Fork::Exit>) that contains the raw wait status and helpers.

When C<max_children> is enabled, the helper always releases capacity and starts
the next queued job (if any) even if user C<on_exit> throws.

=head2 on_timeout

  on_timeout => sub ($child) { ... }

Called when the timeout expires. Timeout handling is explicit; see L</TIMEOUTS>.

=head1 TIMEOUTS

=head2 timeout

  timeout => $seconds

Numeric seconds (integer or fractional). When the timeout expires, the child is
considered timed out and C<on_timeout> is invoked (if provided).

=head2 timeout_kill

  timeout_kill => $seconds

Numeric seconds. If set, this is an escalation delay after timeout. The child is
sent a kill signal after this period (exact signal behavior is documented in the
Child/Exit objects).

Notes:

=over 4

=item * Timeouts apply only after the child has been started.

=item * Timeout values must be numeric scalars (not refs).

=back

=head1 STDIN

=head2 stdin

  stdin => $bytes

If set, these bytes are written to the child's stdin after it starts.

=head2 stdin_pipe

  stdin_pipe => 1

If true, keep a writable stdin pipe open so you can write later via the child
handle. If you provide C<stdin> and do not set C<stdin_pipe>, stdin is closed
after the initial write.

=head1 ENVIRONMENT AND PROCESS SETUP

=head2 cwd

  cwd => '/path'

Change directory in the child before exec or before running the C<child> coderef.

=head2 umask

  umask => 022

Set umask in the child.

=head2 env / clear_env

  clear_env => 1,
  env       => { KEY => 'value', ... },

If C<clear_env> is true, the child starts with an empty environment. If C<env> is
provided, it is merged into the child's environment.

=head1 TAGGING AND USER DATA

=head2 tag

  tag => $string

Optional label stored on the child handle for diagnostics/identification.

=head2 data

  data => $any

Opaque user data stored on the child handle.

=head1 RETURN VALUES

=head2 Child handle

When started immediately, C<< $loop->fork >> returns a
L<Linux::Event::Fork::Child> object representing the running child.

=head2 Request handle

When queued due to C<max_children>, C<< $loop->fork >> returns a
L<Linux::Event::Fork::Request> object. The request can be cancelled before it
starts.

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
