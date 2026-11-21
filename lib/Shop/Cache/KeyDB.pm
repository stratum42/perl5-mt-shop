package Shop::Cache::KeyDB;

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Digest::SHA qw(sha1_hex);
use Shop::Domain::JSON ();

# Pure-Perl RESP2 client for KeyDB/Redis:
# - Pipelining (single write + batch read for minimal RTT/egress)
# - Compact key prefix (default 's:')
# - Lua EVALSHA with automatic NOSCRIPT -> EVAL fallback
# - Atomic cart reservation leases with TTL
# - Sliding/fixed-window rate limiting
# - Pub/Sub publish & subscribe

my $LUA_RESERVE_CART = <<'LUA';
local cart_key  = KEYS[1]
local lease_key = KEYS[2]
local sku       = ARGV[1]
local qty       = tonumber(ARGV[2])
local ttl       = tonumber(ARGV[3])
local new_qty   = redis.call('HINCRBY', cart_key, sku, qty)
if new_qty <= 0 then
    redis.call('HDEL', cart_key, sku)
    redis.call('DEL', lease_key)
    return 0
end
redis.call('EXPIRE', cart_key, ttl)
redis.call('SET', lease_key, tostring(new_qty), 'EX', ttl)
return new_qty
LUA

my $LUA_RELEASE_CART = <<'LUA';
local cart_key  = KEYS[1]
local lease_key = KEYS[2]
local sku       = ARGV[1]
local qty       = tonumber(ARGV[2])
local cur       = tonumber(redis.call('HGET', cart_key, sku) or '0')
if cur <= 0 then
    redis.call('DEL', lease_key)
    return 0
end
local rem = cur - qty
if rem <= 0 then
    redis.call('HDEL', cart_key, sku)
    redis.call('DEL', lease_key)
    return 0
end
redis.call('HSET', cart_key, sku, tostring(rem))
local ttl = redis.call('TTL', lease_key)
if ttl and ttl > 0 then
    redis.call('SET', lease_key, tostring(rem), 'EX', ttl)
end
return rem
LUA

my $LUA_RATE_LIMIT = <<'LUA';
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local win = tonumber(ARGV[2])
local cur = redis.call('INCR', key)
if cur == 1 then
    redis.call('EXPIRE', key, win)
end
local ttl = redis.call('TTL', key)
if cur > limit then
    return {0, 0, ttl}
end
return {1, limit - cur, ttl}
LUA

sub new {
    my ($class, %opt) = @_;
    return bless {
        host    => $opt{host}    // $ENV{KEYDB_HOST} // '127.0.0.1',
        port    => $opt{port}    // $ENV{KEYDB_PORT} // 6379,
        timeout => $opt{timeout} // 2,
        prefix  => defined $opt{prefix} ? $opt{prefix} : 's:',
        sock    => undef,
        buf     => '',
        sha     => {},
    }, $class;
}

sub _k {
    my ($self, $key) = @_;
    return $self->{prefix} . $key;
}

sub _connect {
    my ($self) = @_;
    return $self->{sock} if $self->{sock} && $self->{sock}->connected;
    my $sock = IO::Socket::INET->new(
        PeerAddr => $self->{host},
        PeerPort => $self->{port},
        Proto    => 'tcp',
        Timeout  => $self->{timeout},
    ) or die "Shop::Cache::KeyDB: connect $self->{host}:$self->{port} failed: $!\n";
    binmode($sock);
    $self->{sock} = $sock;
    $self->{buf}  = '';
    return $sock;
}

sub close {
    my ($self) = @_;
    if ($self->{sock}) {
        close $self->{sock};
        $self->{sock} = undef;
    }
    $self->{buf} = '';
}

sub _encode_resp {
    my (@args) = @_;
    my $out = '*' . scalar(@args) . "\r\n";
    for my $a (@args) {
        my $s = defined $a ? "$a" : '';
        $out .= '$' . length($s) . "\r\n$s\r\n";
    }
    return $out;
}

sub _fill_buf {
    my ($self, $min_bytes) = @_;
    my $sock = $self->{sock};
    while (length($self->{buf}) < $min_bytes) {
        my $chunk;
        my $n = sysread($sock, $chunk, 8192);
        die "Shop::Cache::KeyDB: EOF from server\n" if !defined $n || $n == 0;
        $self->{buf} .= $chunk;
    }
}

sub _read_line {
    my ($self) = @_;
    my $sock = $self->{sock};
    while (1) {
        my $idx = index($self->{buf}, "\r\n");
        if ($idx >= 0) {
            my $line = substr($self->{buf}, 0, $idx, '');
            substr($self->{buf}, 0, 2, '');
            return $line;
        }
        my $chunk;
        my $n = sysread($sock, $chunk, 8192);
        die "Shop::Cache::KeyDB: EOF while reading line\n" if !defined $n || $n == 0;
        $self->{buf} .= $chunk;
    }
}

sub _read_resp {
    my ($self) = @_;
    my $line = $self->_read_line;
    my $type = substr($line, 0, 1);
    my $rest = substr($line, 1);
    if ($type eq '+') {
        return $rest;
    }
    elsif ($type eq '-') {
        die "KEYDB_ERR: $rest\n";
    }
    elsif ($type eq ':') {
        return int($rest);
    }
    elsif ($type eq '$') {
        my $len = int($rest);
        return undef if $len < 0;
        $self->_fill_buf($len + 2);
        my $data = substr($self->{buf}, 0, $len, '');
        substr($self->{buf}, 0, 2, '');
        return $data;
    }
    elsif ($type eq '*') {
        my $count = int($rest);
        return undef if $count < 0;
        my @arr;
        for (1 .. $count) {
            push @arr, $self->_read_resp;
        }
        return \@arr;
    }
    die "Shop::Cache::KeyDB: unexpected RESP type '$type'\n";
}

sub _write_all {
    my ($sock, $data) = @_;
    my $off = 0;
    my $len = length($data);
    while ($off < $len) {
        my $n = syswrite($sock, $data, $len - $off, $off);
        die "Shop::Cache::KeyDB: write failed: $!\n" if !defined $n || $n <= 0;
        $off += $n;
    }
}

sub cmd {
    my ($self, @args) = @_;
    my $sock = $self->_connect;
    _write_all($sock, _encode_resp(@args));
    return $self->_read_resp;
}

sub pipeline {
    my ($self, $cmds) = @_;
    return [] unless $cmds && @$cmds;
    my $sock = $self->_connect;
    my $wire = '';
    for my $c (@$cmds) {
        $wire .= _encode_resp(@$c);
    }
    _write_all($sock, $wire);
    my @results;
    for (1 .. scalar(@$cmds)) {
        push @results, $self->_read_resp;
    }
    return \@results;
}

sub ping {
    my ($self) = @_;
    my $ok = eval { ($self->cmd('PING') // '') eq 'PONG' };
    return $ok ? 1 : 0;
}

sub get {
    my ($self, $key) = @_;
    return $self->cmd('GET', $self->_k($key));
}

sub set {
    my ($self, $key, $val, $ttl) = @_;
    if (defined $ttl && $ttl > 0) {
        return $self->cmd('SET', $self->_k($key), $val, 'EX', int($ttl));
    }
    return $self->cmd('SET', $self->_k($key), $val);
}

sub del {
    my ($self, @keys) = @_;
    return 0 unless @keys;
    return $self->cmd('DEL', map { $self->_k($_) } @keys);
}

sub incr {
    my ($self, $key) = @_;
    return $self->cmd('INCR', $self->_k($key));
}

sub expire {
    my ($self, $key, $ttl) = @_;
    return $self->cmd('EXPIRE', $self->_k($key), int($ttl));
}

sub eval_lua {
    my ($self, $script, $keys, $argv) = @_;
    $keys ||= [];
    $argv ||= [];
    my $sha = $self->{sha}{$script} //= sha1_hex($script);
    my $res;
    my $ok = eval {
        $res = $self->cmd('EVALSHA', $sha, scalar(@$keys), @$keys, @$argv);
        1;
    };
    if (!$ok) {
        if ($@ =~ /NOSCRIPT/i) {
            return $self->cmd('EVAL', $script, scalar(@$keys), @$keys, @$argv);
        }
        die $@;
    }
    return $res;
}

sub reserve_cart_lease {
    my ($self, $user_fp, $sku, $qty, $ttl) = @_;
    $ttl ||= 900;
    my $cart_key  = $self->_k("c:$user_fp");
    my $lease_key = $self->_k("l:$user_fp:$sku");
    return $self->eval_lua($LUA_RESERVE_CART, [$cart_key, $lease_key], [$sku, int($qty), int($ttl)]);
}

sub release_cart_lease {
    my ($self, $user_fp, $sku, $qty) = @_;
    my $cart_key  = $self->_k("c:$user_fp");
    my $lease_key = $self->_k("l:$user_fp:$sku");
    return $self->eval_lua($LUA_RELEASE_CART, [$cart_key, $lease_key], [$sku, int($qty)]);
}

sub get_cart_items {
    my ($self, $user_fp) = @_;
    my $raw = $self->cmd('HGETALL', $self->_k("c:$user_fp"));
    my %items;
    if ($raw && ref($raw) eq 'ARRAY') {
        for (my $i = 0; $i < @$raw; $i += 2) {
            $items{$raw->[$i]} = int($raw->[$i + 1]);
        }
    }
    return \%items;
}

sub clear_cart {
    my ($self, $user_fp) = @_;
    my $items = $self->get_cart_items($user_fp);
    my @keys = ($self->_k("c:$user_fp"), map { $self->_k("l:$user_fp:$_") } keys %$items);
    return $self->cmd('DEL', @keys);
}

# Session resume state (last view, selected SKU, active promo, etc.)
sub save_session_state {
    my ($self, $user_fp, $state, $ttl) = @_;
    return 0 unless defined $user_fp && length $user_fp && ref($state) eq 'HASH';
    $ttl = 86400 unless defined $ttl && $ttl > 0;
    my $json = Shop::Domain::JSON::encode_json($state);
    my $res  = $self->set("sess:$user_fp", $json, int($ttl));
    return (defined $res && $res eq 'OK') ? 1 : 0;
}

sub load_session_state {
    my ($self, $user_fp) = @_;
    return undef unless defined $user_fp && length $user_fp;
    my $raw = $self->get("sess:$user_fp");
    return undef unless defined $raw && length $raw;
    my $state = eval { Shop::Domain::JSON::decode_json($raw) };
    return (ref($state) eq 'HASH') ? $state : undef;
}

sub clear_session_state {
    my ($self, $user_fp) = @_;
    return 0 unless defined $user_fp && length $user_fp;
    return $self->del("sess:$user_fp");
}

sub rate_limit {
    my ($self, $bucket, $limit, $window_sec) = @_;
    my $res = $self->eval_lua(
        $LUA_RATE_LIMIT,
        [$self->_k("rl:$bucket")],
        [int($limit), int($window_sec)]
    );
    return ($res->[0], $res->[1], $res->[2]);
}

sub publish {
    my ($self, $channel, $payload) = @_;
    return $self->cmd('PUBLISH', $self->_k("ch:$channel"), $payload);
}

sub subscribe {
    my ($self, $channel, $cb) = @_;
    my $sock = $self->_connect;
    _write_all($sock, _encode_resp('SUBSCRIBE', $self->_k("ch:$channel")));
    my $ack = $self->_read_resp;
    if ($cb) {
        while (my $msg = $self->_read_resp) {
            if (ref($msg) eq 'ARRAY' && ($msg->[0] // '') eq 'message') {
                my $continue = $cb->($msg->[1], $msg->[2]);
                last if defined $continue && !$continue;
            }
        }
    }
    return $ack;
}

sub poll_message {
    my ($self, $timeout) = @_;
    $timeout = 0.05 unless defined $timeout;
    return undef unless $self->{sock};
    if (length($self->{buf}) == 0) {
        my $sel = IO::Select->new($self->{sock});
        return undef unless $sel->can_read($timeout);
    }
    my $msg = $self->_read_resp;
    if (ref($msg) eq 'ARRAY' && ($msg->[0] // '') eq 'message') {
        return ($msg->[1], $msg->[2]);
    }
    return undef;
}

1;
