package Beetle::Publisher;

use Moose;
use Hash::Merge::Simple qw( merge );
use Net::RabbitMQ;
use Beetle::Message;
use Data::Dumper;
extends qw(Beetle::Base::PubSub);

my $RPC_DEFAULT_TIMEOUT = 10;
our $RECYCLE_DEAD_SERVERS_DELAY = 10;

has 'client' => (
    is       => 'ro',
    isa      => 'Any',
    weak_ref => 1,
);

has 'exchanges_with_bound_queues' => (
    default => sub { {} },
    handles => {
        has_exchanges_with_bound_queues => 'exists',
        set_exchanges_with_bound_queues => 'set',
    },
    is     => 'ro',
    isa    => 'HashRef',
    traits => [qw(Hash)],
);

has 'dead_servers' => (
    clearer => 'clear_dead_servers',
    default => sub { {} },
    handles => {
        all_dead_servers   => 'elements',
        count_dead_servers => 'count',
        remove_dead_server => 'delete',
        set_dead_server    => 'set',
    },
    is        => 'ro',
    isa       => 'HashRef',
    predicate => 'has_dead_servers',
    traits    => [qw(Hash)],
);

# def publish(message_name, data, opts={}) #:nodoc:
#   opts = @client.messages[message_name].merge(opts.symbolize_keys)
#   exchange_name = opts.delete(:exchange)
#   opts.delete(:queue)
#   recycle_dead_servers unless @dead_servers.empty?
#   if opts[:redundant]
#     publish_with_redundancy(exchange_name, message_name, data, opts)
#   else
#     publish_with_failover(exchange_name, message_name, data, opts)
#   end
# end
#
sub publish {
    my ( $self, $message_name, $data, $options ) = @_;
    $options ||= {};

    my $message = $self->client->get_message($message_name);
    $options = merge $options, $message;

    my $exchange_name = delete $options->{exchange};
    delete $options->{queue};

    $self->recycle_dead_servers if $self->has_dead_servers;

    if ( $options->{redundant} ) {
        $self->publish_with_redundancy( $exchange_name, $message_name, $data, $options );
    }
    else {
        $self->publish_with_failover( $exchange_name, $message_name, $data, $options );
    }
}

sub publish_with_failover {
    my ( $self, $exchange_name, $message_name, $data, $options ) = @_;

    $self->log->debug( sprintf 'Beetle: sending %s', $message_name );

    my $tries     = $self->count_servers;
    my $published = 0;

    $options = Beetle::Message->publishing_options(%$options);

    for ( 1 .. $tries ) {
        $self->select_next_server;
        $self->bind_queues_for_exchange($exchange_name);

        $self->log->debug(
            sprintf 'Beetle: trying to send message %s:%s to %s',
            $message_name, $options->{message_id},
            $self->server
        );

        eval {
            my $exchange = $self->exchange($exchange_name);
            my $header   = {
                content_type  => 'application/octet-stream',
                delivery_mode => 2,
                headers       => $options->{headers},
                message_id    => $options->{message_id},
                priority      => 0
            };
            $self->bunny->publish( $exchange_name, $message_name, $data, $header );
        };
        unless ($@) {
            $published = 1;
            $self->log->debug('Beetle: message sent!');
            last;
        }
        else {
            $self->log->error($@);
        }

        $self->stop_bunny;
        $self->mark_server_dead;
        $self->log->error( sprintf 'Beetle: message could not be delivered: %s', $message_name );
    }

    return $published;
}

sub publish_with_redundancy {
    my ( $self, $exchange_name, $message_name, $data, $options ) = @_;

    if ( $self->count_servers < 2 ) {
        $self->log->error('Beetle: at least two active servers are required for redundant publishing');
        return $self->publish_with_failover( $exchange_name, $message_name, $data, $options );
    }

    my @published = ();

    $options = Beetle::Message->publishing_options(%$options);

    while (1) {
        last if scalar(@published) == 2;
        last unless $self->count_servers;
        last if scalar(@published) == $self->count_servers;

        $self->select_next_server;
        next if grep $_ eq $self->server, @published;

        $self->bind_queues_for_exchange($exchange_name);

        $self->log->debug(
            sprintf 'Beetle: trying to send message %s:%s to %s',
            $message_name, $options->{message_id},
            $self->server
        );

        my $header = {
            content_type  => 'application/octet-stream',
            delivery_mode => 2,
            headers       => $options->{headers},
            message_id    => $options->{message_id},
            priority      => 0
        };

        eval { $self->bunny->publish( $exchange_name, $message_name, $data, $header ); };
        unless ($@) {
            push @published, $self->server;
            $self->log->debug( sprintf 'Beetle: message sent (%d)!', scalar(@published) );
            next;
        }

        $self->stop_bunny;
        $self->mark_server_dead;
    }

    if ( scalar(@published) == 0 ) {
        $self->log->error( sprintf 'Beetle: message could not be delivered: %s', $message_name );
    }
    elsif ( scalar(@published) == 1 ) {
        $self->log->error('Beetle: failed to send message redundantly');
    }

    return scalar @published;
}

sub rpc {
    my ( $self, $message_name, $data, $options ) = @_;
    $options ||= {};

    my $exchange_name = delete $options->{exchange};
    delete $options->{queue};

    $self->recycle_dead_servers if $self->has_dead_servers;

    $self->log->debug( sprintf 'Beetle: performing rpc with message %s', $message_name );

    my $status = 'TIMEOUT';
    my $tries  = $self->count_servers;
    my $result;

    $self->select_next_server;
    $self->bind_queues_for_exchange($exchange_name);

    # TODO: <plu> Check rabbitmq-interface if this is correct

    # create non durable, autodeleted temporary queue with a server assigned name
    my $queue = $self->bunny->queue;
    $options = Beetle::Message->publishing_options( %$options, reply_to => $queue->{name} );

    $self->log->debug(
        sprintf 'Beetle: trying to send message %s:%s to %s',
        $message_name, $options->{message_id},
        $self->server
    );

    eval { $self->exchange($exchange_name)->publish( $data, $options ); };
    unless ($@) {
        $self->log->debug('Beetle: message sent!');
        $self->log->debug( sprintf 'Beetle: listening on reply queue %s', $queue->{name} );

        # TODO: <plu> finish this
        # $queue->subscribe( message_max => 1, timeout => $options->{timeout} || $RPC_DEFAULT_TIMEOUT );
        #     queue.subscribe(:message_max => 1, :timeout => opts[:timeout] || RPC_DEFAULT_TIMEOUT) do |msg|
        #       logger.debug "Beetle: received reply!"
        #       result = msg[:payload]
        #       status = msg[:header].properties[:headers][:status]
        #     end
        #     logger.debug "Beetle: rpc complete!"
    }

    return ( $status, $result );
}

sub purge {
    my ( $self, $queue_name ) = @_;
    $self->each_server(
        sub {
            my $self = shift;
            $self->bunny->purge( $self->queue($queue_name) );
        }
    );
}

sub stop_bunny {
    my ($self) = @_;

    # TODO: <plu> proper exception handling missing
    eval { $self->bunny->close };
}

sub stop {
    my ($self) = @_;
    $self->each_server(
        sub {
            my $self = shift;

            $self->stop_bunny;

            $self->{bunnies}{ $self->server }   = undef;
            $self->{exchanges}{ $self->server } = {};
            $self->{queues}{ $self->server }    = {};
        }
    );
}

# private

sub recycle_dead_servers {
    my ($self)  = @_;
    my @recycle = ();
    my %servers = $self->all_dead_servers;
    while ( my ( $server, $time ) = each %servers ) {
        if ( time - $time > $RECYCLE_DEAD_SERVERS_DELAY ) {
            push @recycle, $server;
            $self->remove_dead_server($server);
        }
    }
    $self->add_server(@recycle);
}

sub mark_server_dead {
    my ($self) = @_;

    # TODO: <plu> no clue how to get the error message here
    $self->log->info( sprintf 'Beetle: server %s down: %s', $self->server, 'TODO' );

    $self->set_dead_server( $self->server => time );

    my @servers = grep $_ ne $self->server, $self->all_servers;
    $self->{servers} = \@servers;
    $self->{server}  = $servers[ int rand scalar @servers ];
}

sub select_next_server {
    my ($self) = @_;
    unless ( $self->count_servers ) {
        $self->log->error('Beetle: message could not be delivered - no server available');
        return 0;
    }
    my $index = 0;
    foreach my $server ( $self->all_servers ) {
        last if defined $self->server && $self->server eq $server;
        $index++;
    }
    my $next   = ( $index + 1 ) % $self->count_servers;
    my $server = $self->get_server($next);
    $self->set_current_server($server);
}

sub bind_queues_for_exchange {
    my ( $self, $exchange_name ) = @_;
    return if $self->has_exchanges_with_bound_queues($exchange_name);
    my $exchange = $self->client->get_exchange($exchange_name);
    my $queues   = $exchange->{queues};
    foreach my $queue (@$queues) {
        $self->set_exchanges_with_bound_queues( $exchange_name => 1 );
        $self->queue($queue);
    }
}

sub bind_queue {
    my ( $self, $queue_name, $creation_keys, $exchange_name, $binding_keys ) = @_;
    $self->log->debug( sprintf 'Creating queue with options: %s', Dumper($creation_keys) );
    $self->bunny->queue_declare( $queue_name, $creation_keys );
    $self->log->debug( sprintf 'Binding queue %s to %s with options %s',
        $queue_name, $exchange_name, Dumper($binding_keys) );
    $self->exchange($exchange_name);
    $self->bunny->queue_bind( $queue_name, $exchange_name, $binding_keys->{key} );
}

1;
