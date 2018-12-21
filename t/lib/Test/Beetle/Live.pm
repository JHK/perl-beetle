package    # hide from PAUSE
  Test::Beetle::Live;

use strict;
use warnings;
use FindBin qw( $Bin );
use Test::More;
use Test::TCP::Multi;
use Test::Beetle::Redis ();

use base qw(Exporter);
our @EXPORT = qw(test_beetle_live);

sub test_beetle_live {
    my $cb = shift;

    plan skip_all => 'export BEETLE_LIVE_TEST to enable this test' unless $ENV{BEETLE_LIVE_TEST};

    # By default we do not start anything, but then we expect two
    # rabbitmq-server instances running on 5672 + 5673 and at least
    # one redis-server instance running on 6379
    $cb->(
        {
            rabbit1 => 5672,
            rabbit2 => 5673,
            redis1  => 6379,
        },
    );
}

1;
