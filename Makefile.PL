#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  NAME         => 'Linux::Event::Fork',
  AUTHOR       => 'Joshua S. Day <HAX@cpan.org>',
  LICENSE      => 'perl',
  VERSION_FROM => 'lib/Linux/Event/Fork.pm',
  ABSTRACT     => 'Policy-layer async child spawning for Linux::Event (installs $loop->fork)',
  MIN_PERL_VERSION => '5.36.0',

  PREREQ_PM => {
    'Linux::Event' => 0.004,   # core primitives
  },

  TEST_REQUIRES => {
    'Test2::V0' => 0,
  },

  META_MERGE => {
    'meta-spec' => { version => 2 },
    resources => {
      repository => {
        type => 'git',
        url  => 'https://github.com/haxmeister/perl-linux-event-fork.git',
        web  => 'https://github.com/haxmeister/perl-linux-event-fork',
      },
      bugtracker => {
        web => 'https://github.com/haxmeister/perl-linux-event-fork/issues',
      },
    },
  },
);
