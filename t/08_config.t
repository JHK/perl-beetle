use strict;
use warnings;
use Test::Exception;
use Test::More;

use FindBin qw( $Bin );
use lib ( "$Bin/lib", "$Bin/../lib" );
use Test::Beetle;

BEGIN {
    use_ok('Beetle::Client');
}

{
    my $client   = Beetle::Client->new( config => {} );
    my $got      = $client->config;
    my $expected = {
        'bunny_class'                     => 'Beetle::Bunny',
        'gc_threshold'                    => 259200,
        'logger'                          => 'STDERR',
        'loglayout'                       => '[%d] [%p] (%C:%L) %m%n',
        'loglevel'                        => 'INFO',
        'mq_class'                        => 'Beetle::AMQP',
        'password'                        => 'guest',
        'redis_db'                        => 4,
        'redis_hosts'                     => 'localhost:6379',
        'redis_operation_retries'         => 180,
        'servers'                         => 'localhost:5672',
        'additional_subscription_servers' => '',
        'user'                            => 'guest',
        'verbose'                         => 0,
        'vhost'                           => '/',
    };
    is_deeply( $got, $expected, 'Empty config hashref uses default' );
}

{
    my $expected = {
        'bunny_class'                     => 'Test::Beetle::Bunny',
        'gc_threshold'                    => 123,
        'logger'                          => '/dev/null',
        'loglayout'                       => '%m%n',
        'loglevel'                        => 'INFO',
        'mq_class'                        => 'Beetle::AMQP',
        'password'                        => 'secret',
        'redis_db'                        => 1,
        'redis_hosts'                     => 'somehost:6379',
        'redis_operation_retries'         => 123,
        'servers'                         => 'otherhost:5672',
        'additional_subscription_servers' => '',
        'user'                            => 'me',
        'verbose'                         => 1,
        'vhost'                           => '/foo',
    };
    my $client = Beetle::Client->new( config => $expected );
    my $got = $client->config;
    is_deeply( $got, $expected, 'Custom config works' );
}

{
    my $expected = {
        'bunny_class'                     => 'Foo::Bunny',
        'gc_threshold'                    => 456,
        'logger'                          => '/dev/zero',
        'loglayout'                       => 'FOO: %m%n',
        'loglevel'                        => 'WARN',
        'mq_class'                        => 'Foo::AMQP',
        'password'                        => 'secret123',
        'redis_db'                        => 2,
        'redis_hosts'                     => 'somehost:123',
        'redis_operation_retries'         => 456,
        'servers'                         => 'otherhost:456',
        'additional_subscription_servers' => '',
        'user'                            => 'admin',
        'verbose'                         => 1,
        'vhost'                           => '/bar',
    };
    my $client = Beetle::Client->new( configfile => "$Bin/etc/config.pl" );
    my $got = $client->config;
    delete $got->{configfile};
    is_deeply( $got, $expected, 'Custom config from file works' );
}

done_testing;
