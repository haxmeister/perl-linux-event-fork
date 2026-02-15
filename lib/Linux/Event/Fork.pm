package Linux::Event::Fork;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

use Carp qw(croak);
use POSIX ();
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

use Linux::Event::Fork::Child ();

=head1 NAME

Linux::Event::Fork - Policy-layer async child spawning for Linux::Event (installs $loop->fork)

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;
  use Linux::Event::Fork;  # installs $loop->fork (Option B)

  my $loop = Linux::Event->new;

  my $child = $loop->fork(
    cmd => [ $^X, '-we', 'print "hi\n"; exit 0' ],

    on_stdout => sub ($child, $chunk) { ... },

    on_exit => sub ($child, $exit) {
      if ($exit->exited) { say $exit->code }
      $loop->stop;
    },
  );

  $loop->run;

=head1 DESCRIPTION

This distribution is intentionally a policy layer built on L<Linux::Event>'s public
primitives:

=over 4

=item * C<< $loop->watch(...) >> to watch pipes for stdout/stderr capture

=item * C<< $loop->pid(...) >> (pidfd) to observe process exit

=back

Core L<Linux::Event> remains unchanged.

=head1 LOOP METHOD INSTALLATION (OPTION B)

When you C<use Linux::Event::Fork>, this module installs C<< $loop->fork(...) >>
into C<Linux::Event::Loop>. The method is not present unless this distribution is loaded.

The installed method is equivalent to:

  Linux::Event::Fork->new(loop => $loop)->spawn(...)

but uses a per-loop cached helper for minimal overhead.

=head1 SPAWN API

  my $child = $loop->fork(
    cmd => [ $path, @argv ],     # OR: child => sub { ... } (see below)

    on_stdout => sub ($child, $chunk) { ... },  # optional
    on_stderr => sub ($child, $chunk) { ... },  # optional

    on_exit   => sub ($child, $exit)  { ... },  # optional

    stdin => $bytes,             # optional: write then close

    capture_stdout => 1|0,       # optional (default: true if on_stdout provided)
    capture_stderr => 1|0,       # optional (default: true if on_stderr provided)

    data => $any,                # optional: stored on the child handle
  );

=head2 cmd

Exec list form. No shell is involved.

  cmd => [ $path, @argv ]

This becomes:

  exec { $path } $path, @argv

=head2 child

Advanced form. Provide a callback that runs in the child process after fork(),
after Fork has already set up any requested stdio redirections.

  child => sub {
    # runs in the child; typically calls exec()
    exec $path, @argv;
  }

Exactly one of C<cmd> or C<child> must be provided.

If the callback throws an exception or returns normally, the child exits with
status 127. (If it calls C<exec>, it never returns.)

=head1 EXIT AND DRAIN SEMANTICS

This module uses I<drain-first> semantics: C<on_exit> is invoked only after:

=over 4

=item * the child exit is observed via pidfd, and

=item * captured stdout/stderr (if any) have reached EOF

=back

This makes it safe for typical code to stop the loop inside C<on_exit>.

=head1 CHILD HANDLE

The returned object is a L<Linux::Event::Fork::Child>.

=head1 PERFORMANCE NOTES

This module minimizes hot-path branching by pushing almost all work into:

=over 4

=item * a single sysread loop per readiness notification

=item * direct user callback invocation (no fan-out)

=back

=cut

# Option B: install $loop->fork only when this module is loaded.
sub import ($class, @args) {
  no strict 'refs';
  no warnings 'redefine';

  *{"Linux::Event::Loop::fork"} = sub ($loop, %spawn) {
    my $helper = $loop->{_linux_event_fork} //= $class->new(loop => $loop);
    return $helper->spawn(%spawn);
  };

  return;
}

sub new ($class, %args) {
  my $loop = delete $args{loop};
  croak "loop is required" if !$loop;
  croak "unknown args: " . join(", ", sort keys %args) if %args;

  return bless { loop => $loop }, $class;
}

sub loop ($self) { return $self->{loop} }

sub spawn ($self, %spec) {
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

  my $on_stdout = delete $spec{on_stdout};
  my $on_stderr = delete $spec{on_stderr};
  my $on_exit   = delete $spec{on_exit};
  my $data      = delete $spec{data};

  croak "on_stdout must be a coderef" if defined($on_stdout) && ref($on_stdout) ne 'CODE';
  croak "on_stderr must be a coderef" if defined($on_stderr) && ref($on_stderr) ne 'CODE';
  croak "on_exit must be a coderef"   if defined($on_exit)   && ref($on_exit)   ne 'CODE';

  my $capture_stdout = delete $spec{capture_stdout};
  my $capture_stderr = delete $spec{capture_stderr};
  my $stdin          = delete $spec{stdin};

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
  if (defined $stdin) {
    pipe($in_r, $in_w) or croak "pipe(stdin): $!";
    _set_nonblock($in_w); # parent writes
  }

  my $pid = fork();
  croak "fork: $!" if !defined $pid;

  if ($pid == 0) {
    # ---- child ----
    # No Perl teardown / END blocks if we fail; always _exit.
    my $ok = eval {
      if (defined $stdin) {
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

      close($in_r)  if defined $stdin;
      close($out_w) if $capture_stdout;
      close($err_w) if $capture_stderr;

      if (defined $cmd) {
        exec {$cmd->[0]} @$cmd;
        die "exec($cmd->[0]): $!";
      } else {
        $child->();     # typically calls exec()
        die "child callback returned";
      }
    };
    if (!$ok) {
      my $err = $@;
      # Best-effort message; goes to child stderr (possibly captured).
      if (defined $err && $err ne '') {
        $err =~ s/\s+\z/\n/;
        syswrite(*STDERR, "Linux::Event::Fork child error: $err");
      }
    }
    POSIX::_exit(127);
  }

  # ---- parent ----
  close($out_w) if $capture_stdout;
  close($err_w) if $capture_stderr;
  close($in_r)  if defined $stdin;

  my $handle = Linux::Event::Fork::Child->_new(
    loop => $self->{loop},
    pid  => $pid,

    out_r => $out_r,
    err_r => $err_r,
    in_w  => $in_w,

    on_stdout => $on_stdout,
    on_stderr => $on_stderr,
    on_exit   => $on_exit,

    data => $data,

    capture_stdout => $capture_stdout,
    capture_stderr => $capture_stderr,
  );

  if (defined $stdin) {
    $handle->stdin_write($stdin);
    $handle->close_stdin;
  }

  $handle->_arm;
  return $handle;
}

sub _set_nonblock ($fh) {
  my $flags = fcntl($fh, F_GETFL, 0);
  croak "fcntl(F_GETFL): $!" if !defined $flags;
  my $ok = fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
  croak "fcntl(F_SETFL,O_NONBLOCK): $!" if !$ok;
  return;
}

1;
