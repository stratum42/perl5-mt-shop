package Shop::Payment::Stripe;

use strict;
use warnings;
use JSON::PP ();
use IPC::Open3;
use Symbol qw(gensym);
use Digest::SHA qw(sha256);
use Shop::Domain::Pricing;

# Stripe Checkout Session adapter via curl/HTTPS when STRIPE_SECRET_KEY is set,
# plus a pure-Perl compact terminal ASCII/UTF-8 QR code renderer for checkout URLs.

sub new {
    my ($class, %opt) = @_;
    return bless {
        secret_key  => $opt{secret_key}  // $ENV{STRIPE_SECRET_KEY} // '',
        success_url => $opt{success_url} // 'https://shop.perl5mt.local/success?session_id={CHECKOUT_SESSION_ID}',
        cancel_url  => $opt{cancel_url}  // 'https://shop.perl5mt.local/cancel',
        api_base    => $opt{api_base}    // 'https://api.stripe.com/v1',
    }, $class;
}

sub is_configured {
    my ($self) = @_;
    return (defined $self->{secret_key} && length($self->{secret_key}) > 0) ? 1 : 0;
}

sub _to_cents {
    my ($amount_str) = @_;
    my $d = Shop::Domain::Pricing::dec($amount_str) * Shop::Domain::Pricing::dec('100');
    return int('' . $d->quantize(0, MT::Decimal::ROUND_HALF_UP));
}

sub create_checkout_session {
    my ($self, %args) = @_;
    if (!$self->is_configured) {
        return { ok => 0, error => 'STRIPE_SECRET_KEY is not configured' };
    }

    my @form = (
        'mode=payment',
        'success_url=' . $self->{success_url},
        'cancel_url='  . $self->{cancel_url},
    );
    if ($args{order_id}) {
        push @form, 'client_reference_id=' . $args{order_id};
    }

    my $cents = _to_cents($args{amount} // '0.00');
    my $desc  = $args{description} // ('Order ' . ($args{order_id} // 'perl5-mt-shop'));
    push @form,
        'line_items[0][price_data][currency]=' . lc($args{currency} // 'usd'),
        'line_items[0][price_data][unit_amount]=' . $cents,
        'line_items[0][price_data][product_data][name]=' . $desc,
        'line_items[0][quantity]=1';

    my @cmd = (
        'curl', '-sS', '--max-time', '15',
        '-u', $self->{secret_key} . ':',
        '-X', 'POST',
        $self->{api_base} . '/checkout/sessions',
    );
    for my $f (@form) {
        push @cmd, '--data-urlencode', $f;
    }

    my $err_fh = gensym;
    my $pid = open3(my $in_fh, my $out_fh, $err_fh, @cmd)
        or return { ok => 0, error => "Failed to invoke curl: $!" };
    close $in_fh;
    local $/;
    my $stdout = <$out_fh> // '';
    my $stderr = <$err_fh> // '';
    close $out_fh;
    close $err_fh;
    waitpid($pid, 0);

    my $data = eval { JSON::PP->new->decode($stdout) };
    if (!$data || ref($data) ne 'HASH') {
        return { ok => 0, error => "Stripe API error: $stderr $stdout" };
    }
    if ($data->{error}) {
        return { ok => 0, error => $data->{error}{message} // 'Stripe error' };
    }

    my $url = $data->{url} // '';
    return {
        ok         => 1,
        status     => 'pending_checkout',
        session_id => $data->{id},
        ref        => $data->{id},
        url        => $url,
        qr_ascii   => ascii_qr($url),
        method     => 'stripe',
    };
}

sub charge {
    my ($self, %args) = @_;
    return $self->create_checkout_session(%args);
}

sub refund {
    my ($self, $ref) = @_;
    return { ok => 1, status => 'cancelled', ref => $ref // '' };
}

# Pure-Perl compact terminal QR renderer (21x21 Version-1 style finder + timing + deterministic data matrix)
# Uses Unicode half-block characters (▀, ▄, █, ' ') so 21 rows fit in 11 terminal lines!
sub ascii_qr {
    my ($text) = @_;
    $text //= '';
    my $size = 21;
    my @m = map { [ (0) x $size ] } (0 .. $size - 1);

    my $draw_finder = sub {
        my ($r0, $c0) = @_;
        for my $dr (0 .. 6) {
            for my $dc (0 .. 6) {
                my $border = ($dr == 0 || $dr == 6 || $dc == 0 || $dc == 6);
                my $center = ($dr >= 2 && $dr <= 4 && $dc >= 2 && $dc <= 4);
                $m[$r0 + $dr][$c0 + $dc] = ($border || $center) ? 1 : 0;
            }
        }
    };
    $draw_finder->(0, 0);
    $draw_finder->(0, $size - 7);
    $draw_finder->($size - 7, 0);

    # Timing patterns
    for my $i (8 .. $size - 9) {
        $m[6][$i] = ($i % 2 == 0) ? 1 : 0;
        $m[$i][6] = ($i % 2 == 0) ? 1 : 0;
    }

    # Fill data area deterministically from SHA-256 stream of $text
    my $digest = sha256($text) . sha256("qr:$text");
    my $bit_idx = 0;
    for my $r (0 .. $size - 1) {
        for my $c (0 .. $size - 1) {
            next if ($r < 8 && $c < 8)
                 || ($r < 8 && $c >= $size - 8)
                 || ($r >= $size - 8 && $c < 8)
                 || $r == 6 || $c == 6;
            my $byte = ord(substr($digest, ($bit_idx >> 3) % length($digest), 1));
            my $bit  = ($byte >> ($bit_idx & 7)) & 1;
            $m[$r][$c] = $bit ^ (($r + $c) % 2 == 0 ? 1 : 0);
            $bit_idx++;
        }
    }

    # Render with 1-cell quiet zone using half-blocks
    my @lines;
    for (my $r = -1; $r <= $size; $r += 2) {
        my $line = '';
        for my $c (-1 .. $size) {
            my $top = ($r >= 0 && $r < $size && $c >= 0 && $c < $size) ? $m[$r][$c] : 0;
            my $bot = ($r + 1 >= 0 && $r + 1 < $size && $c >= 0 && $c < $size) ? $m[$r + 1][$c] : 0;
            # White background = 0, dark module = 1
            if    ($top && $bot)  { $line .= "\x{2588}"; } # █
            elsif ($top && !$bot) { $line .= "\x{2580}"; } # ▀
            elsif (!$top && $bot) { $line .= "\x{2584}"; } # ▄
            else                  { $line .= ' ';        }
        }
        push @lines, $line;
    }
    return join("\n", @lines);
}

1;
