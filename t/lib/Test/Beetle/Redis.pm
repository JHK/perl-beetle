package    # hide from PAUSE
  Test::Beetle::Redis;

use strict;
use warnings;
use Test::More;
use Beetle::DeduplicationStore;

use base qw(Exporter);
our @EXPORT = qw(test_redis);

sub test_redis {
    my $cb = shift;

    my $store = Beetle::DeduplicationStore->new( hosts => "redis1:6379" );
    $cb->($store);
}

1;
