package Linux::Event::Fork::Exit;
use v5.36;
use strict;
use warnings;

=head1 NAME

Linux::Event::Fork::Exit - Structured child-exit result (no POSIX macros required)

=head1 SYNOPSIS

  on_exit => sub ($child, $exit) {
    if ($exit->exited) {
      say "code=" . $exit->code;
    } elsif ($exit->signaled) {
      say "signal=" . $exit->signal;
    }
  };

=head1 DESCRIPTION

C<Linux::Event> exposes raw C<waitpid()> status integers from pidfd observation.
This class provides a stable, documented interface for interpreting that status
without requiring users to import POSIX macros.

=head1 METHODS

=head2 raw

  my $raw = $exit->raw;

The raw status integer (or undef).

=head2 exited, code

  if ($exit->exited) { say $exit->code }

True when the process exited normally. C<code> is the exit code (0..255).

=head2 signaled, signal, core_dump

  if ($exit->signaled) { say $exit->signal }

True when the process terminated by signal. C<core_dump> reports whether a core
dump flag is present.

=head2 stopped, stop_signal

These are provided for completeness but are not typically expected when pidfd is
configured for exit observation.

=head1 NOTE ON STABILITY

This API is intended to remain stable even if internal implementation details change.

=cut

sub new ($class, $status) {
  return bless { raw => $status }, $class;
}

sub raw ($self) { return $self->{raw} }

sub exited ($self) {
  my $st = $self->{raw};
  return 0 if !defined $st;
  return (($st & 0x7f) == 0) ? 1 : 0;
}

sub code ($self) {
  return undef if !$self->exited;
  my $st = $self->{raw};
  return ($st >> 8) & 0xff;
}

sub signaled ($self) {
  my $st = $self->{raw};
  return 0 if !defined $st;
  my $sig = $st & 0x7f;
  return 0 if $sig == 0;       # normal exit
  return 0 if $sig == 0x7f;    # stopped/continued (not expected under WEXITED)
  return 1;
}

sub signal ($self) {
  return undef if !$self->signaled;
  my $st = $self->{raw};
  return $st & 0x7f;
}

sub core_dump ($self) {
  return 0 if !$self->signaled;
  my $st = $self->{raw};
  return ($st & 0x80) ? 1 : 0;
}

sub stopped ($self) {
  my $st = $self->{raw};
  return 0 if !defined $st;
  return (($st & 0x7f) == 0x7f) ? 1 : 0;
}

sub stop_signal ($self) {
  return undef if !$self->stopped;
  my $st = $self->{raw};
  return ($st >> 8) & 0xff;
}

1;
