package Shop::State::EventBus;

use strict;
use warnings;
use MT;
use MT::SharedHash;
use MT::Channel;
sub _enc_json { MT::Pool::_encode_list($_[0]) }
sub _dec_json { my ($v) = MT::Pool::_decode_list($_[0]); return $v }

# Lock-free / sharded cross-worker EventBus built on MT::SharedHash + MT::Channel.
# Each active SSH session registers an inbox MT::Channel ID + session metadata.

sub new {
    my ($class) = @_;
    return bless {
        sessions       => MT::SharedHash->new,
        free_ch        => MT::Channel->new(16384),
        recycled_count => 0,
    }, $class;
}

sub attach {
    my ($class, $ids) = @_;
    return bless {
        sessions       => MT::SharedHash->attach($ids->{sessions_id}),
        free_ch        => defined($ids->{free_id}) ? MT::Channel->attach($ids->{free_id}) : undef,
        recycled_count => 0,
    }, $class;
}

sub state_ids {
    my ($self) = @_;
    return {
        sessions_id => $self->{sessions}->id,
        free_id     => $self->{free_ch} ? $self->{free_ch}->id : undef,
    };
}

sub recycled_count {
    my ($self) = @_;
    return $self->{recycled_count} // 0;
}

sub _drain_channel {
    my ($ch) = @_;
    return unless $ch;
    while (1) {
        my ($ok) = eval { $ch->try_recv };
        last unless $ok;
    }
}

sub register_session {
    my ($self, $session_id, $meta, $cap) = @_;
    $meta ||= {};
    $cap  ||= 64;

    my $chan;
    if (defined $meta->{chan_id}) {
        $chan = MT::Channel->attach($meta->{chan_id});
    } else {
        if ($self->{free_ch}) {
            my ($ok, $cid) = eval { $self->{free_ch}->try_recv };
            if ($ok && defined $cid) {
                my $recycled = eval { MT::Channel->attach($cid) };
                if ($recycled) {
                    _drain_channel($recycled);
                    $chan = $recycled;
                    $self->{recycled_count}++;
                }
            }
        }
        $chan ||= MT::Channel->new($cap);
    }

    my %rec = (
        %$meta,
        session_id   => $session_id,
        chan_id      => $chan->id,
        cap          => $cap,
        connected_at => $meta->{connected_at} // time(),
    );
    $self->{sessions}->set($session_id, _enc_json(\%rec));
    return $chan;
}

sub unregister_session {
    my ($self, $session_id) = @_;
    my $raw     = $self->{sessions}->get($session_id);
    my $deleted = $self->{sessions}->delete($session_id);
    if (defined $raw) {
        my $rec = eval { _dec_json($raw) };
        if ($rec && defined $rec->{chan_id}) {
            my $ch = eval { MT::Channel->attach($rec->{chan_id}) };
            if ($ch) {
                # Return the channel slot to the shared free-list instead of closing it
                if ($self->{free_ch} && $self->{free_ch}->len < 16000) {
                    _drain_channel($ch);
                    my $pushed = eval { $self->{free_ch}->send($rec->{chan_id}); 1 };
                    eval { $ch->close } unless $pushed;
                } else {
                    eval { $ch->close };
                }
            }
        }
    }
    return $deleted;
}

sub update_session {
    my ($self, $session_id, $patch) = @_;
    my $raw = $self->{sessions}->get($session_id);
    return 0 unless defined $raw;
    my $rec = _dec_json($raw);
    for my $k (keys %$patch) {
        $rec->{$k} = $patch->{$k};
    }
    $self->{sessions}->set($session_id, _enc_json($rec));
    return 1;
}

sub list_sessions {
    my ($self) = @_;
    my @out;
    for my $sid (sort $self->{sessions}->keys) {
        my $raw = $self->{sessions}->get($sid);
        next unless defined $raw;
        my $rec = eval { _dec_json($raw) };
        push @out, $rec if $rec;
    }
    return \@out;
}

sub _try_deliver {
    my ($rec, $payload) = @_;
    return 0 unless defined $rec->{chan_id};
    my $ch  = MT::Channel->attach($rec->{chan_id});
    my $cap = $rec->{cap} || 64;
    # Never block broadcaster if a slow session's inbox is nearly full
    return 0 if $ch->len >= $cap - 1;
    my $ok = eval { $ch->send($payload); 1 };
    return $ok ? 1 : 0;
}

sub broadcast {
    my ($self, $event) = @_;
    my $payload = ref($event) ? _enc_json($event) : "$event";
    my $sent = 0;
    for my $rec (@{ $self->list_sessions }) {
        $sent += _try_deliver($rec, $payload);
    }
    return $sent;
}

sub send_to_user {
    my ($self, $user_fp, $event) = @_;
    return 0 unless defined $user_fp && length $user_fp;
    my $payload = ref($event) ? _enc_json($event) : "$event";
    my $sent = 0;
    for my $rec (@{ $self->list_sessions }) {
        next unless ($rec->{user_fp} // '') eq $user_fp;
        $sent += _try_deliver($rec, $payload);
    }
    return $sent;
}

sub poll_inbox {
    my ($self, $inbox_chan) = @_;
    my @events;
    return \@events unless $inbox_chan;
    while (1) {
        my ($ok, $raw) = $inbox_chan->try_recv;
        last unless $ok;
        my $ev = eval { _dec_json($raw) };
        push @events, ($ev || { type => 'raw', data => $raw });
    }
    return \@events;
}

1;
