use strict;
use warnings;
use Test::Exception;
use Test::More;

use FindBin qw( $Bin );
use lib ( "$Bin/lib", "$Bin/../lib" );
use Test::Beetle;
use Test::Beetle::Bunny;

BEGIN {
    use_ok('Beetle::Base::PubSub');
    use_ok('Beetle::Publisher');
    use_ok('Beetle::Client');
}

# test "acccessing a bunny for a server which doesn't have one should create it and associate it with the server" do
{
    no warnings 'redefine';
    local *Beetle::Base::PubSub::new_bunny = sub { return 42; };
    my $client = Beetle::Client->new;
    my $pub = Beetle::Publisher->new( client => $client );
    is( $pub->bunny,                     42, 'Method new_bunny works as expected' );
    is( $pub->get_bunny( $pub->server ), 42, 'Bunnies got set correctly' );
}

{
    my $client = Beetle::Client->new;
    my $pub = Beetle::Publisher->new( client => $client );
    is_deeply( $pub->{bunnies}, {}, 'initially there should be no bunnies' );
}

{
    my $client = Beetle::Client->new;
    my $pub = Beetle::Publisher->new( client => $client );
    is_deeply( $pub->{dead_servers}, {}, 'initially there should be no dead servers' );
}

{
    local $Beetle::Publisher::RECYCLE_DEAD_SERVERS_DELAY = 1;
    my $client = Beetle::Client->new( config => { servers => 'localhost:3333 localhost:4444 localhost:5555' } );
    my $publisher = $client->publisher;

    is_deeply( $publisher->servers, [qw(localhost:3333 localhost:4444 localhost:5555)],
        'Servers attribute is correct' );

    my @servers = ();

    for ( 0 .. 2 ) {
        push @servers, $publisher->server;
        $publisher->mark_server_dead;

        isnt( $publisher->server, $servers[$_], 'The dead server moved away' );
        is( defined( $publisher->dead_servers->{ $servers[$_] } ),
            1, 'The dead server got added to the dead servers list' );
    }

    # This should not do anything (yet)
    $publisher->recycle_dead_servers;

    is( $publisher->count_servers,      0, 'No more servers left' );
    is( $publisher->count_dead_servers, 3, 'All servers are in the dead servers list' );

    sleep( $Beetle::Publisher::RECYCLE_DEAD_SERVERS_DELAY + 1 );

    # Now it should recycle the servers
    $publisher->recycle_dead_servers;

    is( $publisher->count_servers,      3, '3 servers back to the servers list' );
    is( $publisher->count_dead_servers, 0, 'No more servers are in the dead servers list' );

    is( $publisher->server, undef, 'No server selected' );

    $publisher->select_next_server;

    like( $publisher->server, qr/localhost:\d{4}/, 'New server selected' );
}

{
    no warnings 'redefine';

    my @servers = ();

    local $Beetle::Publisher::RECYCLE_DEAD_SERVERS_DELAY = 1;

    # If this dies, the publisher will mark the server as dead
    local *Test::Beetle::Bunny::publish = sub {
        my ($self) = @_;
        push @servers, sprintf( '%s:%d', $self->host, $self->port );
        die 'dead server';
    };

    my $client = Beetle::Client->new(
        config => {
            servers     => 'localhost:3333 localhost:4444',
            bunny_class => 'Test::Beetle::Bunny',
        }
    );
    my $publisher = $client->publisher;
    $client->register_queue( mama => { exchange => 'mama-exchange' } );
    $client->register_message( mama => { ttl => 60 * 60, exchange => 'mama-exchange' } );
    $publisher->publish( mama => 'XXX' );

    is_deeply( [ sort @servers ], [qw(localhost:3333 localhost:4444)], 'Server cycling works' );
    is_deeply( $publisher->servers, [], 'Servers attribute is empty as well' );
    is( $publisher->server,             undef, 'No server set because all are dead' );
    is( $publisher->count_dead_servers, 2,     'There are two dead servers now' );

    sleep( $Beetle::Publisher::RECYCLE_DEAD_SERVERS_DELAY + 1 );

    # Override this again to see if the dead servers get recycled properly on a new publish call
    local *Test::Beetle::Bunny::publish = sub { };
    $publisher->publish( mama => 'XXX' );

    is_deeply( [ sort @{ $publisher->servers } ], [qw(localhost:3333 localhost:4444)], 'Server recycling works' );
    is( $publisher->count_dead_servers, 0, 'There are no dead servers anymore' );
}

# test "redundant publishing should send the message to two servers" do
{
    no warnings 'redefine';

    my @servers = ();

    local *Test::Beetle::Bunny::publish = sub {
        my ($self) = @_;
        push @servers, sprintf( '%s:%d', $self->host, $self->port );
    };

    my $client = Beetle::Client->new(
        config => {
            servers     => 'localhost:3333 localhost:4444 localhost:5555',
            bunny_class => 'Test::Beetle::Bunny',
        }
    );
    my $publisher = $client->publisher;

    my $count = $publisher->publish_with_redundancy( 'mama-exchange', 'mama', 'XXX', {} );
    is( $count, scalar(@servers), 'Message got published to two servers' );
}

# test "redundant publishing should return 1 if the message was published to one server only" do
{
    no warnings 'redefine';

    my @servers = ();

    local *Test::Beetle::Bunny::publish = sub {
        my ($self) = @_;
        die if $self->host ne 'dead';
        push @servers, sprintf( '%s:%d', $self->host, $self->port );
    };

    my $client = Beetle::Client->new(
        config => {
            servers     => 'dead:3333 alive:4444 dead:5555',
            bunny_class => 'Test::Beetle::Bunny',
        }
    );
    my $publisher = $client->publisher;

    my $count = $publisher->publish_with_redundancy( 'mama-exchange', 'mama', 'XXX', {} );
    is( $count, scalar(@servers), 'Message got published to one server because only one is alive' );
}

# test "redundant publishing should return 0 if the message was published to no server" do
{
    no warnings 'redefine';

    my @servers = ();

    local *Test::Beetle::Bunny::publish = sub {
        my ($self) = @_;
        die if $self->host ne 'dead';
        push @servers, sprintf( '%s:%d', $self->host, $self->port );
    };

    my $client = Beetle::Client->new(
        config => {
            servers     => 'dead:3333 dead:4444 dead:5555',
            bunny_class => 'Test::Beetle::Bunny',
        }
    );
    my $publisher = $client->publisher;

    my $count = $publisher->publish_with_redundancy( 'mama-exchange', 'mama', 'XXX', {} );
    is( $count, scalar(@servers), 'Message got published to one server because only one is alive' );
}

done_testing;
