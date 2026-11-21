package Shop::DB::SQLite;

use strict;
use warnings;
use parent 'Shop::DB';

use Shop::Domain::JSON ();
sub _dec_json { Shop::Domain::JSON::decode_json($_[0]) }
use File::Path qw(make_path);
use File::Basename qw(dirname);
use POSIX ();

# Spawn sqlite3 with separate stdin/stdout/stderr pipes using pure lexical
# filehandles (avoids Symbol::gensym which mutates frozen package globals in MT::Worker).
sub _spawn_sqlite {
    my (@cmd) = @_;
    pipe(my $in_r,  my $in_w)  or die "Shop::DB::SQLite: pipe failed: $!\n";
    pipe(my $out_r, my $out_w) or die "Shop::DB::SQLite: pipe failed: $!\n";
    pipe(my $err_r, my $err_w) or die "Shop::DB::SQLite: pipe failed: $!\n";

    my $pid = fork();
    die "Shop::DB::SQLite: fork failed: $!\n" unless defined $pid;
    if ($pid == 0) {
        CORE::close($in_w);
        CORE::close($out_r);
        CORE::close($err_r);
        open(STDIN,  '<&', $in_r)  or POSIX::_exit(127);
        open(STDOUT, '>&', $out_w) or POSIX::_exit(127);
        open(STDERR, '>&', $err_w) or POSIX::_exit(127);
        CORE::close($in_r);
        CORE::close($out_w);
        CORE::close($err_w);
        { exec(@cmd); }
        POSIX::_exit(127);
    }

    CORE::close($in_r);
    CORE::close($out_w);
    CORE::close($err_w);
    return ($pid, $in_w, $out_r, $err_r);
}

sub new {
    my ($class, $cfg) = @_;
    $cfg ||= {};
    my $path = $cfg->{path} // $cfg->{sqlite_path} // $ENV{SHOP_SQLITE_PATH} // 'data/shop.db';
    if ($path ne ':memory:') {
        my $dir = dirname($path);
        make_path($dir) if defined $dir && length $dir && !-d $dir;
    }
    return bless {
        path       => $path,
        sqlite_bin => $cfg->{sqlite_bin} // 'sqlite3',
    }, $class;
}

sub driver { 'sqlite' }

sub _quote_literal {
    my ($v) = @_;
    return 'NULL' unless defined $v;
    my $s = "$v";
    $s =~ s/'/''/g;
    return "'$s'";
}

sub _bind_sql {
    my ($sql, @params) = @_;
    return $sql unless @params;
    my $idx = 0;
    my $out = '';
    my $in_sq = 0;
    my $i = 0;
    my $n = length($sql);
    while ($i < $n) {
        my $ch = substr($sql, $i, 1);
        if ($ch eq "'") {
            if ($in_sq && $i + 1 < $n && substr($sql, $i + 1, 1) eq "'") {
                $out .= "''";
                $i += 2;
                next;
            }
            $in_sq = !$in_sq;
            $out .= $ch;
        }
        elsif ($ch eq '?' && !$in_sq) {
            die "Shop::DB::SQLite: not enough bind params for SQL\n" if $idx >= @params;
            $out .= _quote_literal($params[$idx++]);
        }
        else {
            $out .= $ch;
        }
        $i++;
    }
    return $out;
}

sub _run_oneshot {
    my ($self, $sql, $json_mode) = @_;
    my @cmd = ($self->{sqlite_bin}, '-cmd', '.timeout 5000');
    push @cmd, '-json' if $json_mode;
    push @cmd, $self->{path};

    my ($pid, $in_fh, $out_fh, $err_fh) = _spawn_sqlite(@cmd);
    binmode($in_fh,  ':encoding(UTF-8)');
    binmode($out_fh, ':encoding(UTF-8)');
    binmode($err_fh, ':encoding(UTF-8)');

    print $in_fh "$sql;\n";
    close $in_fh;

    local $/;
    my $stdout = <$out_fh> // '';
    my $stderr = <$err_fh> // '';
    close $out_fh;
    close $err_fh;
    waitpid($pid, 0);
    my $rc = $? >> 8;

    if ($rc != 0 || ($stderr =~ /\S/ && $stderr !~ /^Warning:/)) {
        die "Shop::DB::SQLite error (rc=$rc): $stderr\nSQL: $sql\n";
    }
    return $stdout;
}

sub health {
    my ($self) = @_;
    my $ok = eval {
        my $rows = $self->query('SELECT 1 AS ok');
        return (@$rows && $rows->[0]{ok} == 1) ? 1 : 0;
    };
    return $ok ? 1 : 0;
}

sub query {
    my ($self, $sql, @params) = @_;
    my $bound = _bind_sql($sql, @params);
    my $out   = $self->_run_oneshot($bound, 1);
    $out =~ s/^\s+|\s+$//g;
    return [] unless length $out;
    my $rows = _dec_json($out);
    # Normalize keys to lowercase
    for my $r (@$rows) {
        for my $k (keys %$r) {
            my $lk = lc($k);
            if ($lk ne $k) {
                $r->{$lk} = delete $r->{$k};
            }
        }
    }
    return $rows;
}

sub exec {
    my ($self, $sql, @params) = @_;
    my $bound = _bind_sql($sql, @params);
    my $out = $self->_run_oneshot("$bound;\nSELECT changes() AS c", 1);
    $out =~ s/^\s+|\s+$//g;
    if (length $out) {
        my $rows = eval { _dec_json($out) };
        if ($rows && ref($rows) eq 'ARRAY' && @$rows && defined $rows->[-1]{c}) {
            return int($rows->[-1]{c});
        }
    }
    return 1;
}

sub txn {
    my ($self, $code) = @_;
    my ($pid, $in_fh, $out_fh, $err_fh) = _spawn_sqlite($self->{sqlite_bin}, '-cmd', '.timeout 5000', '-json', $self->{path});
    binmode($in_fh,  ':encoding(UTF-8)');
    binmode($out_fh, ':encoding(UTF-8)');
    binmode($err_fh, ':encoding(UTF-8)');
    my $old_sel = select($in_fh); $| = 1; select($old_sel);

    my $tx = Shop::DB::SQLite::Tx->new($in_fh, $out_fh, $err_fh);
    $tx->_raw_exec("BEGIN IMMEDIATE");

    my $want = wantarray;
    my (@res, $res);
    my $ok = eval {
        if ($want) { @res = $code->($tx); }
        else       { $res = $code->($tx); }
        1;
    };
    if (!$ok) {
        my $err = $@;
        eval { $tx->_raw_exec("ROLLBACK"); };
        close $in_fh; close $out_fh; close $err_fh;
        waitpid($pid, 0);
        die $err;
    }
    $tx->_raw_exec("COMMIT");
    close $in_fh;
    close $out_fh;
    close $err_fh;
    waitpid($pid, 0);
    return $want ? @res : $res;
}

package Shop::DB::SQLite::Tx;
use strict;
use warnings;
use Shop::Domain::JSON ();
sub _dec_json { Shop::Domain::JSON::decode_json($_[0]) }

my $SENTINEL = '__SHOP_SQLITE_TX_END__';

sub new {
    my ($class, $in_fh, $out_fh, $err_fh) = @_;
    return bless { in => $in_fh, out => $out_fh, err => $err_fh }, $class;
}

sub _raw_exec {
    my ($self, $sql) = @_;
    my $in  = $self->{in};
    my $out = $self->{out};
    print $in "$sql;\nSELECT '$SENTINEL' AS _s;\n";
    my @lines;
    while (defined(my $line = <$out>)) {
        last if index($line, $SENTINEL) >= 0;
        push @lines, $line;
    }
    return join('', @lines);
}

sub query {
    my ($self, $sql, @params) = @_;
    my $bound = Shop::DB::SQLite::_bind_sql($sql, @params);
    my $raw   = $self->_raw_exec($bound);
    $raw =~ s/^\s+|\s+$//g;
    return [] unless length $raw;
    my $rows = Shop::DB::SQLite::_dec_json($raw);
    for my $r (@$rows) {
        for my $k (keys %$r) {
            my $lk = lc($k);
            $r->{$lk} = delete $r->{$k} if $lk ne $k;
        }
    }
    return $rows;
}

sub exec {
    my ($self, $sql, @params) = @_;
    my $bound = Shop::DB::SQLite::_bind_sql($sql, @params);
    $self->_raw_exec($bound);
    my $raw = $self->_raw_exec('SELECT changes() AS c');
    $raw =~ s/^\s+|\s+$//g;
    if (length $raw) {
        my $rows = eval { Shop::DB::SQLite::_dec_json($raw) };
        return int($rows->[0]{c}) if $rows && ref($rows) eq 'ARRAY' && @$rows;
    }
    return 1;
}

1;
