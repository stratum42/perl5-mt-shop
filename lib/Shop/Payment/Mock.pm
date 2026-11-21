package Shop::Payment::Mock;

use strict;
use warnings;

# Instant zero-network sandbox payment adapter.
# tok_visa (default) succeeds; tok_decline / tok_fail declines.

sub new {
    my ($class, %opt) = @_;
    return bless { %opt }, $class;
}

sub charge {
    my ($self, %args) = @_;
    my $token  = $args{token}  // 'tok_visa';
    my $amount = $args{amount} // '0.00';

    if ($token eq 'tok_decline' || $token eq 'tok_fail') {
        return {
            ok     => 0,
            status => 'declined',
            error  => 'Card declined by mock issuer (tok_decline)',
            method => 'mock',
        };
    }

    my $ref = sprintf('mock_ch_%d_%06d', time(), int(rand(1_000_000)));
    return {
        ok       => 1,
        status   => 'succeeded',
        ref      => $ref,
        amount   => "$amount",
        currency => $args{currency} // 'usd',
        method   => 'mock',
    };
}

sub refund {
    my ($self, $ref) = @_;
    return {
        ok     => 1,
        status => 'refunded',
        ref    => $ref // '',
    };
}

1;
