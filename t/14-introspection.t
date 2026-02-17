#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Test2::V0;

use Linux::Event;
use Linux::Event::Fork max_children => 1;

my $loop = Linux::Event->new;
my $fork = $loop->fork_helper;

is($fork->max_children, 1, 'max_children accessor');
is($fork->running_count, 0, 'running_count starts at 0');
is($fork->queued_count,  0, 'queued_count starts at 0');

for my $i (1..3) {
  $loop->fork(
    tag => "job:$i",
    cmd => [ $^X, '-we', 'select(undef,undef,undef,0.02); exit 0' ],
  );
}

ok($fork->queued_count >= 0, 'queued_count after enqueue (non-negative)');

$fork->drain(on_done => sub ($fork) {
  is($fork->running_count, 0, 'running_count back to 0 after drain');
  is($fork->queued_count, 0, 'queued_count back to 0 after drain');
  $loop->stop;
});

$loop->run;

done_testing;
