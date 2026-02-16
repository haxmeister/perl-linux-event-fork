#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Linux::Event;
use Linux::Event::Fork;

# STRESS TEST: Fork timeout churn
# This stresses:
#   - fork/exit churn (many short-lived children)
#   - timeout timer scheduling + cancellation
#   - drain-first teardown stability under load
#
# Expected:
#   - some children exit normally
#   - some children get timed out (TERM)
#   - loop stops cleanly after all children complete

my $loop = Linux::Event->new;

my $N = $ENV{N} // 200;
my $TIMEOUT = $ENV{TIMEOUT} // 0.02;

my $done = 0;
my $timed = 0;
my $ok = 0;

for my $i (1..$N) {
  $loop->fork(
    tag => "job:$i",
    timeout => $TIMEOUT,
    on_timeout => sub ($child) { $timed++ },

    child => sub {
      $SIG{TERM} = sub { exit 0 };
      # Half the time, sleep longer than timeout.
      if ($i % 2 == 0) {
        select(undef, undef, undef, $TIMEOUT * 4);
      } else {
        select(undef, undef, undef, $TIMEOUT / 4);
      }
      exit 0;
    },

    on_exit => sub ($child, $exit) {
      $done++;
      $ok++ if $exit->exited && $exit->code == 0;
      $loop->stop if $done == $N;
    },
  );
}

$loop->run;

print "DONE\n";
print "  N        = $N\n";
print "  ok       = $ok\n";
print "  timedout = $timed\n";
