package Beetle::Message;

use Moose;
use namespace::clean -except => 'meta';
use Data::UUID;
use Devel::StackTrace;
extends qw(Beetle::Base);
use Beetle::Handler;
use Beetle::Constants;
use Data::Dumper;
use Sys::SigAction ();

=head1 NAME

Beetle::Message - Message implementation

=head1 DESCRIPTION

TODO: <plu> add docs

=cut

# current message format version
our $FORMAT_VERSION = 1;

# flag for encoding redundant messages
my $FLAG_REDUNDANT = 1;

# default lifetime of messages
our $DEFAULT_TTL = 86400;

# forcefully abort a running handler after this many seconds.
# can be overriden when registering a handler.
our $DEFAULT_HANDLER_TIMEOUT = 300;

# how many times we should try to run a handler before giving up
our $DEFAULT_HANDLER_EXECUTION_ATTEMPTS = 1;

# how many seconds we should wait before retrying handler execution
our $DEFAULT_HANDLER_EXECUTION_ATTEMPTS_DELAY = 10;

# how many exceptions should be tolerated before giving up
my $DEFAULT_EXCEPTION_LIMIT = 0;

# AMQP options for message publishing
my @PUBLISHING_KEYS = qw(key mandatory immediate persistent reply_to headers);

# Data::UUID instance (otherwise painfully slow)
my $DATA_UUID = Data::UUID->new;

has 'server' => (
    documentation => 'server from which the message was received',
    is            => 'rw',
    isa           => 'Any',
);

has 'queue' => (
    documentation => 'name of the queue on which the message was received',
    is            => 'rw',
    isa           => 'Any',
    required      => 1,
);

has 'header' => (
    documentation => 'the AMQP header received with the message',
    is            => 'rw',
    isa           => 'Any',
    required      => 1,
);

has 'deliver' => (
    documentation => 'the AMQP deliver properties received with the message',
    is            => 'rw',
    isa           => 'Any',
    required      => 0,
);

has 'body' => (
    documentation => '',
    is            => 'rw',
    isa           => 'Any',
    required      => 1,
);

has 'uuid' => (
    documentation => 'the uuid of the message',
    is            => 'ro',
    isa           => 'Str',
);

has 'data' => (
    documentation => 'message payload',
    is            => 'rw',
    isa           => 'Any',
);

has 'format_version' => (
    documentation => 'the message format version of the message',
    is            => 'rw',
    isa           => 'Any',
);

has 'flags' => (
    documentation => 'flags sent with the message',
    is            => 'rw',
    isa           => 'Any',
);

has 'expires_at' => (
    documentation => 'unix timestamp after which the message should be considered stale',
    is            => 'rw',
    isa           => 'Any',
);

has 'timeout' => (
    default       => $DEFAULT_HANDLER_TIMEOUT,
    documentation => 'how many seconds the handler is allowed to execute',
    is            => 'rw',
    isa           => 'Int',
);

has 'delay' => (
    default       => $DEFAULT_HANDLER_EXECUTION_ATTEMPTS_DELAY,
    documentation => 'how long to wait before retrying the message handler',
    is            => 'rw',
    isa           => 'Int',
);

has 'attempts_limit' => (
    default       => $DEFAULT_HANDLER_EXECUTION_ATTEMPTS,
    documentation => 'how many times we should try to run the handler',
    is            => 'rw',
    isa           => 'Int',
);

has 'exceptions_limit' => (
    default       => $DEFAULT_EXCEPTION_LIMIT,
    documentation => 'how many exceptions we should tolerate before giving up',
    is            => 'rw',
    isa           => 'Int',
);

has 'exception' => (
    documentation => 'exception raised by handler execution',
    is            => 'rw',
    isa           => 'Any',
);

has 'handler_result' => (
    documentation => 'value returned by handler execution',
    is            => 'rw',
    isa           => 'Any',
);

has 'store' => (
    is  => 'rw',
    isa => 'Beetle::DeduplicationStore',
);

has '_ack' => (
    default => 0,
    is      => 'rw',
    isa     => 'Bool',
);

around 'BUILDARGS' => sub {
    my $orig  = shift;
    my $class = shift;

    my %args = @_;

    $args{attempts_limit}   = delete $args{attempts}   if defined $args{attempts};
    $args{exceptions_limit} = delete $args{exceptions} if defined $args{exceptions};

    return $class->$orig(%args);
};

sub BUILD {
    my ($self) = @_;

    my $ae_limit = $self->attempts_limit <= $self->exceptions_limit;
    $self->{attempts_limit} = $self->exceptions_limit + 1 if $ae_limit;
    $self->decode;
}

sub ack {
    my ($self) = @_;
    $self->log->debug( sprintf 'Beetle: ack! for message %s', $self->msg_id );
    $self->_ack(1);
}

sub aquire_mutex {
    my ($self) = @_;
    my $mutex;
    if ( $mutex = $self->store->setnx( $self->msg_id => mutex => $self->now ) ) {
        $self->log->debug( sprintf 'Beetle: aquired mutex: %s', $self->msg_id );
    }
    else {
        $self->delete_mutex;
    }
    return $mutex;
}

sub attempts {
    my ($self) = @_;
    $self->store->get( $self->msg_id => 'attempts' ) || 0;
}

sub attempts_limit_reached {
    my ($self) = @_;
    my $attempts = $self->attempts;
    my $result = $attempts >= $self->attempts_limit;
    return $result ? 1 : 0;
}

sub completed {
    my ($self) = @_;
    $self->store->set( $self->msg_id => status => 'completed' );
}

sub decode {
    my ($self) = @_;

    eval {
        my $header       = $self->header;
        my $amqp_headers = $header->{headers} || die 'missing amqp headers';

        $self->{uuid}           = $header->{message_id};
        $self->{format_version} = $amqp_headers->{format_version};
        $self->{flags}          = $amqp_headers->{flags};
        $self->{expires_at}     = $amqp_headers->{expires_at};
    };

    if ($@) {
        $self->log->error('Could not decode message. '. Dumper $self);
        $self->{exception} = $@;
    }
}

sub delayed {
    my ($self) = @_;
    my $t = $self->store->get( $self->msg_id => 'delay' );
    return $t && $t > $self->now ? 1 : 0;
}

sub delete_mutex {
    my ($self) = @_;
    $self->store->del( $self->msg_id => 'mutex' );
    $self->log->debug( sprintf 'Beetle: deleted mutex: %s', $self->msg_id );
}

sub exceptions_limit_reached {
    my ($self) = @_;
    my $value = $self->store->get( $self->msg_id => 'exceptions' );
    my $result = defined $value && $value > $self->exceptions_limit;
    return $result ? 1 : 0;
}

sub expired {
    my ($self) = @_;
    my $result = $self->expires_at < time;
    return $result ? 1 : 0;
}

sub generate_uuid {
    return lc( $DATA_UUID->create_str );
}

sub increment_exception_count {
    my ($self) = @_;
    $self->store->incr( $self->msg_id => 'exceptions' );
}

sub increment_execution_attempts {
    my ($self) = @_;
    $self->store->incr( $self->msg_id => 'attempts' );
}

sub is_completed {
    my ($self) = @_;
    my $value = $self->store->get( $self->msg_id => 'status' );
    my $result = defined $value && $value eq 'completed';
    return $result ? 1 : 0;
}

sub is_timed_out {
    my ($self) = @_;
    my $t = $self->store->get( $self->msg_id => 'timeout' );
    my $result = defined $t && $t < $self->now;
    return $result ? 1 : 0;
}

sub key_exists {
    my ($self) = @_;
    my $successful = $self->store->msetnx( $self->msg_id => { status => 'incomplete', expires => $self->expires_at } );
    if ($successful) {
        return 0;
    }
    $self->log->debug( sprintf "Beetle: received duplicate message: %s on queue: %s", $self->msg_id, $self->queue );
    return 1;
}

sub msg_id {
    my ($self) = @_;
    return sprintf "msgid:%s:%s", $self->queue, $self->uuid;
}

sub now {
    return time();
}

sub process {
    my ( $self, $handler ) = @_;

    $handler = Beetle::Handler->create($handler);

    $self->log->debug( sprintf 'Beetle: processing message %s on %s', $self->msg_id, $self->server || '' );

    my $result = eval { $self->_process_internal($handler) };
    if ($@) {
        my $trace = Devel::StackTrace->new;
        $self->log->warn( sprintf "Beetle: exception '%s' during processing of message %s", $@, $self->msg_id );
        $self->log->warn( sprintf "Beetle: backtrace: %s", $trace->as_string );
        return $INTERNALERROR;
    }

    $handler->process_failure($result) if grep $result eq $_, @FAILURE;

    return $result;
}

sub publishing_options {
    my ( $package, %args ) = @_;

    my $flags = 0;
    $flags |= $FLAG_REDUNDANT if $args{redundant};

    $args{ttl} = $DEFAULT_TTL unless defined $args{ttl};

    my $expires_at = now() + $args{ttl};

    foreach my $key ( keys %args ) {
        delete $args{$key} unless grep $_ eq $key, @PUBLISHING_KEYS;
    }

    $args{message_id} = generate_uuid();
    $args{headers}    ||= {};

    $args{headers}{format_version} = $FORMAT_VERSION;
    $args{headers}{flags}          = $flags;
    $args{headers}{expires_at}     = $expires_at;

    return \%args;
}

sub redundant {
    my ($self) = @_;
    my $result = $self->flags & $FLAG_REDUNDANT;
    return $result ? 1 : 0;
}

sub reset_timeout {
    my ($self) = @_;
    $self->store->set( $self->msg_id => timeout => 0 );
}

sub set_delay {
    my ($self) = @_;
    $self->store->set( $self->msg_id => delay => $self->now + $self->delay );
}

sub set_timeout {
    my ($self) = @_;
    $self->store->set( $self->msg_id => timeout => $self->now + $self->timeout );
}

sub simple {
    my ($self) = @_;
    my $result = !$self->redundant && $self->attempts_limit == 1;
    return $result ? 1 : 0;
}

sub _handler_failed {
    my ( $self, $result ) = @_;

    $self->increment_exception_count;

    if ( $self->attempts_limit_reached ) {
        $self->ack;
        $self->log->debug( sprintf 'Beetle: reached the handler execution attempts limit: %d on %s',
            $self->attempts_limit, $self->msg_id );
        return $ATTEMPTSLIMITREACHED;
    }

    elsif ( $self->exceptions_limit_reached ) {
        $self->ack;
        $self->log->debug( sprintf 'Beetle: reached the handle exceptions limit: %d on %s',
            $self->exceptions_limit, $self->msg_id );
        return $EXCEPTIONSLIMITREACHED;
    }

    else {
        $self->delete_mutex;
        $self->reset_timeout;
        $self->set_delay;
        return $result;
    }
}

sub _process_internal {
    my ( $self, $handler ) = @_;

    if ($self->exception) {
        return $DECODINGERROR;
    }

    elsif ( $self->expired ) {
        $self->log->warn( sprintf 'Beetle: ignored expired message (%s)', $self->msg_id );
        $self->ack;
        return $ANCIENT;
    }

    elsif ( $self->simple ) {
        $self->ack;
        my $result = $self->_run_handler($handler);
        return $result eq $HANDLERCRASH ? $ATTEMPTSLIMITREACHED : $OK;
    }

    elsif ( !$self->key_exists ) {
        $self->set_timeout;
        return $self->_execute_handler($handler);
    }

    elsif ( $self->is_completed ) {
        $self->ack;
        return $OK;
    }

    elsif ( $self->delayed ) {
        $self->log->warn( sprintf 'Beetle: ignored delayed message (%s)!', $self->msg_id );
        return $DELAYED;
    }

    elsif ( !$self->is_timed_out ) {
        return $HANDLERNOTYETTIMEDOUT;
    }

    elsif ( $self->attempts_limit_reached ) {
        $self->ack;
        $self->log->warn( sprintf 'Beetle: reached the handler execution attempts limit: %d on %s',
            $self->attempts_limit, $self->msg_id );
        return $ATTEMPTSLIMITREACHED;
    }

    elsif ( $self->exceptions_limit_reached ) {
        $self->ack;
        $self->log->warn( sprintf 'Beetle: reached the handler exceptions attempts limit: %d on %s',
            $self->exceptions_limit, $self->msg_id );
        return $EXCEPTIONSLIMITREACHED;
    }

    else {
        $self->set_timeout;
        if ( $self->aquire_mutex ) {
            $self->_execute_handler($handler);
        }
        else {
            return $MUTEXLOCKED;
        }
    }
}

# def run_handler(handler)
sub _run_handler {
    my ( $self, $handler ) = @_;

    my $exception;

    my $timed_out = Sys::SigAction::timeout_call($self->timeout, sub {
        eval { $handler->call($self); };
        $exception = $@;
    });

    if ($timed_out) {
        $exception = sprintf('Reached timeout after %s seconds', $self->timeout)
    }

    return $OK unless $exception;

    $handler->process_exception($exception) if Scalar::Util::blessed $handler && $handler->can('process_exception');

    $self->log->error( sprintf 'Beetle: message handler crashed on %s', $self->msg_id );
    $self->log->error("Beetle: error message: $exception");

    return $HANDLERCRASH;
}

# def run_handler!(handler)
sub _execute_handler {
    my ( $self, $handler ) = @_;
    $self->increment_execution_attempts;
    my $result = $self->_run_handler($handler);
    if ( $result eq $OK ) {
        $self->completed;
        $self->ack;
        return $result;
    }
    else {
        return $self->_handler_failed($result);
    }
}

__PACKAGE__->meta->make_immutable;

=head1 AUTHOR

See L<Beetle>.

=head1 COPYRIGHT AND LICENSE

See L<Beetle>.

=cut

1;
