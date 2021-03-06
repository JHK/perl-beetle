package Beetle::Subscriber;

use Moose;
use namespace::clean -except => 'meta';
use Hash::Merge::Simple qw( merge );
use Beetle::Handler;
use Beetle::Message;
use Beetle::Constants;
use Coro qw(unblock_sub);
use Class::Load;
extends qw(Beetle::Base::PubSub);

=head1 NAME

Beetle::Subscriber - Subscribe for messages

=head1 DESCRIPTION

TODO: <plu> add docs

=cut

has 'handlers' => (
    default => sub { {} },
    handles => {
        get_handler => 'get',
        has_handler => 'exists',
        set_handler => 'set',
    },
    is     => 'ro',
    isa    => 'HashRef',
    traits => [qw(Hash)],
);

has 'mqs' => (
    default => sub { {} },
    handles => {
        get_mq => 'get',
        has_mq => 'exists',
        set_mq => 'set',
    },
    is     => 'ro',
    isa    => 'HashRef',
    traits => [qw(Hash)],
);

has 'subscription_callback' => (
    default => sub { {} },
    is     => 'ro',
    isa    => 'HashRef',
);

sub BUILD {
    my ($self) = @_;
    my @servers = (@{$self->client->servers}, @{$self->client->subscriber_servers});
    $self->{servers} = \@servers;
    $self->{server}  = $servers[ int rand scalar @servers ];
}

sub listen {
    my ( $self, $messages, $code ) = @_;
    my $exchanges = $self->exchanges_for_messages($messages);
    $self->create_exchanges($exchanges);
    my $queues = $self->queues_for_exchanges($exchanges);
    $self->bind_queues($queues);
    $self->subscribe_queues($queues);
    $code->() if defined $code && ref $code eq 'CODE';
    $self->mq->listen;
}

sub stop {
    my ($self) = @_;
    $self->mq->stop;
}

sub register_handler {
    my ( $self, $queues, $options, $handler ) = @_;
    $queues = [$queues] unless ref $queues eq 'ARRAY';
    foreach my $queue (@$queues) {
        $self->set_handler(
            $queue => {
                code    => $handler,
                options => $options,
            }
        );
    }
}

sub exchanges_for_messages {
    my ( $self, $messages ) = @_;
    my %exchanges = ();
    foreach my $m (@$messages) {
        my $message = $self->client->get_message($m);
        next unless $message;
        my $exchange = $message->{exchange};
        $exchanges{$exchange} = 1;
    }
    return [ keys %exchanges ];
}

sub queues_for_exchanges {
    my ( $self, $exchanges ) = @_;
    my %queues = ();
    foreach my $e (@$exchanges) {
        my $exchange = $self->client->get_exchange($e);
        next unless $exchange;
        my $q = $exchange->{queues};
        $queues{$_} = 1 for @$q;
    }
    return [ keys %queues ];
}

sub create_exchanges {
    my ( $self, $exchanges ) = @_;
    $self->each_server(
        sub {
            my $self = shift;
            foreach my $exchange (@$exchanges) {
                $self->exchange($exchange);
            }
        }
    );
}

sub create_exchange {
    my ( $self, $name, $options ) = @_;
    my %rmq_options = %{ $options || {} };
    delete $rmq_options{queues};
    $self->mq->exchange_declare( $name => \%rmq_options );
    return 1;
}

sub bind_queues {
    my ( $self, $queues ) = @_;
    $self->each_server(
        sub {
            my $self = shift;
            foreach my $queue (@$queues) {
                $self->queue($queue);
            }
        }
    );
}

sub mq {
    my ($self) = @_;
    my $has_mq = $self->has_mq( $self->server );
    $self->set_mq( $self->server => $self->new_mq ) unless $has_mq;
    return $self->get_mq( $self->server );
}

sub new_mq {
    my ($self) = @_;
    my $class = $self->config->mq_class;
    Class::Load::load_class($class);
    return $class->new(
        config => $self->config,
        host   => $self->current_host,
        port   => $self->current_port,
    );
}

sub subscribe_queues {
    my ( $self, $queues ) = @_;
    $self->each_server(
        sub {
            my $self = shift;
            foreach my $queue (@$queues) {
                $self->subscribe($queue) if $self->has_handler($queue);
            }
        }
    );
}

sub pause_listening {
    my $s = unblock_sub {
        my ( $self, $queues ) = @_;
        $self->each_server(
            sub {
                my $self = shift;
                foreach my $queue (@$queues) {
                    $self->pause($queue);
                }
            }
        );
    };
    $s->(@_);
}

sub resume_listening {
    my $s = unblock_sub {
        my ( $self, $queues ) = @_;
        $self->each_server(
            sub {
                my $self = shift;
                foreach my $queue (@$queues) {
                    $self->resume($queue);
                }
            }
        );
    };
    $s->(@_);
}

sub subscribe {
    my ( $self, $queue_name ) = @_;

    $self->error( sprintf 'no handler for queue %s', $queue_name ) unless $self->has_handler($queue_name);

    my $handler         = $self->get_handler($queue_name);
    my $amqp_queue_name = $self->client->get_queue($queue_name)->{amqp_name};

    my $callback = $self->create_subscription_callback(
        {
            queue_name      => $queue_name,
            amqp_queue_name => $amqp_queue_name,
            handler         => $handler,
            mq              => $self->mq
        }
    );

    $self->log->debug( sprintf 'Beetle: subscribing to queue %s with key # on server %s',
        $amqp_queue_name, $self->server );

    eval {
        $self->mq->subscribe( $queue_name => $callback );
        $self->set_subscription_callback( $queue_name => $callback );
    };
    if ($@) {
        $self->error("Beetle: binding multiple handlers for the same queue isn't possible: $@");
    }
}

sub pause {
    my ( $self, $queue_name ) = @_;

    $self->log->debug( sprintf 'Beetle: pausing subscription on queue %s', $queue_name );
    $self->mq->unsubscribe( $queue_name );
}

sub resume {
    my ( $self, $queue_name ) = @_;

    if (my $callback = $self->get_subscription_callback( $queue_name )) {

        $self->log->debug( sprintf 'Beetle: resuming subscription on queue %s', $queue_name );
        eval {
            $self->mq->subscribe( $queue_name => $callback );
        };
        if ($@) {
            $self->error("Beetle: error resuming subscription on queue $queue_name: $@");
        }
    }
}

sub create_subscription_callback {
    my ( $self, $args ) = @_;

    my $queue_name      = $args->{queue_name};
    my $amqp_queue_name = $args->{amqp_queue_name};
    my $handler         = $args->{handler}{code};
    my $options         = $args->{handler}{options};
    my $mq              = $args->{mq};

    return sub {
        my ($amqp_message) = @_;
        my $header         = $amqp_message->{header};
        my $body           = $amqp_message->{body}->payload;
        my $deliver        = $amqp_message->{deliver};
        my $processor = eval { Beetle::Handler->create( $handler, $options ) };
        my $processing_result = eval {
            my $server = sprintf '%s:%d', $mq->host, $mq->port;
            my $message_options = merge $options,
              { server => $server, store => $self->client->deduplication_store };
            my $message = Beetle::Message->new(
                config  => $self->config,
                queue   => $amqp_queue_name,
                header  => $header,
                body    => $body,
                deliver => $deliver,
                %$message_options,
            );
            my $result = $message->process($processor);
            if ( grep $_ eq $result, @REJECT ) {
                sleep 1;
                $mq->reject({ delivery_tag => $message->deliver->method_frame->delivery_tag });
            }
            else {
                if ( $message->_ack ) {
                    $self->log->debug( sprintf 'Ack! using delivery_tag: %s',
                        $message->deliver->method_frame->delivery_tag );
                    $mq->ack( { delivery_tag => $message->deliver->method_frame->delivery_tag } );
                    unless ( $message->simple ) {
                        if ( !$message->redundant || $message->store->incr( $message->msg_id => 'ack_count' ) == 2 ) {
                            $self->log->debug(sprintf 'Deleting keys for message %s', $message->msg_id);
                            $message->store->del_keys( $message->msg_id );
                        }
                    }
                }
            }
            # TODO: complete the implementation of reply_to
            return $result;
        };

        $processor->processing_completed() if $processor;
        return $processing_result;

    };
}

sub get_subscription_callback {
    my ($self, $queue) = @_;

    my $server = $self->server;
    return $self->subscription_callback->{$server}->{$queue};
}

sub set_subscription_callback {
    my ($self, $queue, $callback) = @_;

    my $server = $self->server;
    $self->subscription_callback->{$server}->{$queue} = $callback;
}

sub bind_queue {
    my ( $self, $queue_name, $creation_keys, $exchange_name, $binding_keys ) = @_;
    $self->mq->queue_declare( $queue_name => $creation_keys );
    $self->exchange($exchange_name);
    $self->mq->queue_bind( $queue_name, $exchange_name, $binding_keys->{key} );
}

__PACKAGE__->meta->make_immutable;

=head1 AUTHOR

See L<Beetle>.

=head1 COPYRIGHT AND LICENSE

See L<Beetle>.

=cut

1;
