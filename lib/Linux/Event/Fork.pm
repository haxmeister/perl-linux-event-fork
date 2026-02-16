package Linux::Event::Fork;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

use Carp qw(croak);
use POSIX ();
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

use Linux::Event::Fork::Child ();

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

  my $on_timeout = delete $spec{on_timeout};
  my $timeout    = delete $spec{timeout};

  my $tag  = delete $spec{tag};
  my $data = delete $spec{data};

  croak "on_stdout must be a coderef"  if defined($on_stdout)  && ref($on_stdout)  ne 'CODE';
  croak "on_stderr must be a coderef"  if defined($on_stderr)  && ref($on_stderr)  ne 'CODE';
  croak "on_exit must be a coderef"    if defined($on_exit)    && ref($on_exit)    ne 'CODE';
  croak "on_timeout must be a coderef" if defined($on_timeout) && ref($on_timeout) ne 'CODE';
  croak "timeout must be numeric seconds" if defined($timeout) && ref($timeout);

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

      if (defined $umask) { umask($umask) or die "umask($umask): $!" }
      if (defined $cwd)   { chdir($cwd) or die "chdir($cwd): $!" }

      if ($clear_env) { %ENV = () }
      if (defined $env) { %ENV = (%ENV, %$env) }

      if (defined $cmd) {
        exec {$cmd->[0]} @$cmd;
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

    timeout_s  => $timeout,
    on_timeout => $on_timeout,

    capture_stdout => $capture_stdout,
    capture_stderr => $capture_stderr,
  );

  if (defined $stdin && $stdin ne '') {
    $handle->stdin_write($stdin);
  }
  if (defined $stdin && !$stdin_pipe) {
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
