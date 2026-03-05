package Linux::Event::Fork::Exit;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.007';

use POSIX qw(WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG);

# WCOREDUMP is not available/exported on all Perls/platforms.
# Detect it at compile time and gracefully return 0 when unavailable.
my $HAS_WCOREDUMP = defined &POSIX::WCOREDUMP ? 1 : 0;

sub new ($class, $pid, $status) {
  return bless { pid => $pid, status => $status }, $class;
}

sub pid      ($self) { return $self->{pid} }
sub status   ($self) { return $self->{status} }

sub exited   ($self) { return WIFEXITED($self->{status}) ? 1 : 0 }
sub code     ($self) { return WEXITSTATUS($self->{status}) }

sub signaled ($self) { return WIFSIGNALED($self->{status}) ? 1 : 0 }
sub signal   ($self) { return WTERMSIG($self->{status}) }

sub coredump ($self) {
  return 0 if !$HAS_WCOREDUMP;
  return POSIX::WCOREDUMP($self->{status}) ? 1 : 0;
}

1;

__END__

=head1 NAME

Linux::Event::Fork::Exit - Child process exit information

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;
  use Linux::Event::Fork;

  my $loop = Linux::Event->new;

  $loop->fork(
    cmd => [qw(/bin/false)],

    on_exit => sub ($child, $exit) {
      if ($exit->exited) {
        say "exit code: " . $exit->exit_code;
      }
      elsif ($exit->signaled) {
        say "terminated by signal " . $exit->signal;
      }
    },
  );

  $loop->run;

=head1 DESCRIPTION

A B<Linux::Event::Fork::Exit> object represents the termination status of a
child process.

It wraps the raw status value returned by C<wait(2)> or C<pidfd_wait()> and
provides helper methods for interpreting it.

Instances of this class are passed to the C<on_exit> callback of
L<Linux::Event::Fork> child processes.

=head1 CALLBACK CONTRACT

The exit object is provided to the parent-side callback:

  on_exit => sub ($child, $exit) { ... }

Where:

=over 4

=item * C<$child>

The L<Linux::Event::Fork::Child> object representing the process.

=item * C<$exit>

The L<Linux::Event::Fork::Exit> object describing the termination status.

=back

=head1 METHODS

=head2 status

  my $status = $exit->status;

Returns the raw wait status value.

This is the same integer value returned by C<wait()> and compatible with the
standard POSIX macros.

=head2 exited

  if ($exit->exited) { ... }

Returns true if the process exited normally via C<exit()>.

=head2 exit_code

  my $code = $exit->exit_code;

Returns the exit code (0 - 255) if the process exited normally.

Returns undef if the process did not exit normally.

=head2 signaled

  if ($exit->signaled) { ... }

Returns true if the process terminated due to a signal.

=head2 signal

  my $sig = $exit->signal;

Returns the terminating signal number if the process was killed by a signal.

Returns undef if the process exited normally.

=head2 core_dumped

  if ($exit->core_dumped) { ... }

Returns true if the process terminated and produced a core dump.

=head1 NOTES

These helpers are convenience wrappers around the traditional POSIX wait
status interpretation logic:

  WIFEXITED
  WEXITSTATUS
  WIFSIGNALED
  WTERMSIG
  WCOREDUMP

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
