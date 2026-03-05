package Linux::Event::Fork::Request;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.007';

use Carp qw(croak);

sub _new ($class, %args) {
  my $fork = delete $args{fork} or croak "fork missing";
  my $spec = delete $args{spec} or croak "spec missing";
  croak "unknown args: " . join(", ", sort keys %args) if %args;

  # Copy the spec now so later mutation by the caller cannot affect queued work.
  my %copy = %$spec;

  my $self = bless {
    fork => $fork,
    spec => \%copy,
    canceled => 0,
    started => 0,
    child => undef,
    tag  => $copy{tag},
    data => $copy{data},
  }, $class;

  return $self;
}

sub tag ($self)  { return $self->{tag} }
sub data ($self) { return $self->{data} }

sub started ($self) { return $self->{started} ? 1 : 0 }
sub child   ($self) { return $self->{child} }

sub cancel ($self) {
  return 0 if $self->{canceled};
  $self->{canceled} = 1;
  return 1;
}

sub _canceled ($self) { return $self->{canceled} ? 1 : 0 }

sub _start ($self) {
  return if $self->{canceled};
  return if $self->{started};

  $self->{started} = 1;

  my $child = $self->{fork}->_spawn_now($self->{spec});
  $self->{child} = $child;

  return $child;
}

1;

__END__

=head1 NAME

Linux::Event::Fork::Request - Queued child process request

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;
  use Linux::Event::Fork;

  my $loop = Linux::Event->new;

  my $fork = $loop->fork_helper(max_children => 2);

  my $req = $loop->fork(
    cmd => [qw(/bin/sleep 5)],
    tag => "job-1",

    on_exit => sub ($child, $exit) {
      say "job finished";
    },
  );

  if ($req->isa('Linux::Event::Fork::Request')) {
    say "request queued";
  }

  # cancel before it starts
  $req->cancel;

=head1 DESCRIPTION

A B<Linux::Event::Fork::Request> represents a fork request that has not yet
started because the fork helper has reached its C<max_children> limit.

When capacity becomes available, the helper converts the request into a
L<Linux::Event::Fork::Child> object and the child process starts.

Requests allow applications to inspect or cancel queued work before it begins.

=head1 LIFECYCLE

A request transitions through these states:

  queued -> started -> child object created

or

  queued -> cancelled

Once a request has started it is no longer represented by a Request object;
instead the running process is represented by a
L<Linux::Event::Fork::Child>.

=head1 METHODS

=head2 cancel

  my $ok = $req->cancel;

Cancels the queued request before it starts.

Returns true if the request was successfully cancelled. Returns false if the
request has already started or was previously cancelled.

Cancellation removes the request from the fork helper queue.

=head2 is_cancelled

  if ($req->is_cancelled) { ... }

Returns true if the request has been cancelled.

=head2 tag

  my $tag = $req->tag;

Returns the tag associated with the request (if any).

=head2 data

  my $data = $req->data;

Returns the opaque user data associated with the request.

=head2 helper

  my $fork = $req->helper;

Returns the L<Linux::Event::Fork> helper that owns the queue.

=head2 spec

  my $spec = $req->spec;

Returns the fork specification hash that will be used when the request starts.

This is primarily intended for diagnostics and debugging.

=head1 QUEUE SEMANTICS

Queued requests are processed in FIFO order.

When a running child exits and capacity becomes available, the helper starts
the next request from the queue.

If multiple requests are cancelled, they are simply skipped when the queue is
advanced.

=head1 ERROR HANDLING

Cancelling a request that has already started has no effect.

Requests that are cancelled will never spawn a child and none of the fork
callbacks will run.

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
