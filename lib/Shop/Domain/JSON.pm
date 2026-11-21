package Shop::Domain::JSON;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(encode_json decode_json);

# Pure-Perl, zero-global-state RFC 8259 canonical JSON encoder/decoder.
# 100% safe inside frozen perl5-mt MT::Worker threads (unlike JSON::PP which
# mutates file-scoped lexicals that become read-only after MT::Image::freeze()).

sub _esc_str {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\x08/\\b/g;
    $s =~ s/\x0c/\\f/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord($1))/ge;
    return '"' . $s . '"';
}

sub encode_json {
    my ($v) = @_;
    return 'null' unless defined $v;
    my $r = ref($v);
    if (!$r) {
        return _esc_str("$v");
    }
    if ($r eq 'HASH') {
        my @pairs;
        for my $k (sort keys %$v) {
            push @pairs, _esc_str($k) . ':' . encode_json($v->{$k});
        }
        return '{' . join(',', @pairs) . '}';
    }
    if ($r eq 'ARRAY') {
        return '[' . join(',', map { encode_json($_) } @$v) . ']';
    }
    if ($r eq 'JSON::PP::Boolean' || $r eq 'SCALAR') {
        return $$v ? 'true' : 'false';
    }
    return _esc_str("$v");
}

sub _skip_ws {
    my ($sref, $pref) = @_;
    pos($$sref) = $$pref;
    if ($$sref =~ /\G\s+/gc) {
        $$pref = pos($$sref);
    }
}

sub _parse_str {
    my ($sref, $pref) = @_;
    die "JSON: expected '\"' at $$pref\n" unless substr($$sref, $$pref, 1) eq '"';
    $$pref++;
    my $out = '';
    my $len = length($$sref);
    while ($$pref < $len) {
        my $ch = substr($$sref, $$pref, 1);
        $$pref++;
        return $out if $ch eq '"';
        if ($ch eq '\\') {
            die "JSON: unterminated escape\n" if $$pref >= $len;
            my $e = substr($$sref, $$pref, 1);
            $$pref++;
            if    ($e eq '"' || $e eq '\\' || $e eq '/') { $out .= $e; }
            elsif ($e eq 'b') { $out .= "\x08"; }
            elsif ($e eq 'f') { $out .= "\x0c"; }
            elsif ($e eq 'n') { $out .= "\n"; }
            elsif ($e eq 'r') { $out .= "\r"; }
            elsif ($e eq 't') { $out .= "\t"; }
            elsif ($e eq 'u') {
                my $hex = substr($$sref, $$pref, 4);
                die "JSON: invalid \\u escape\n" unless $hex =~ /^[0-9a-fA-F]{4}$/;
                $$pref += 4;
                $out .= chr(hex($hex));
            }
            else {
                die "JSON: invalid escape '\\$e'\n";
            }
        }
        else {
            $out .= $ch;
        }
    }
    die "JSON: unterminated string\n";
}

sub _parse_val {
    my ($sref, $pref) = @_;
    _skip_ws($sref, $pref);
    my $len = length($$sref);
    die "JSON: unexpected EOF\n" if $$pref >= $len;

    my $ch = substr($$sref, $$pref, 1);
    if ($ch eq '"') {
        return _parse_str($sref, $pref);
    }
    if ($ch eq '{') {
        $$pref++;
        my %obj;
        _skip_ws($sref, $pref);
        if ($$pref < $len && substr($$sref, $$pref, 1) eq '}') {
            $$pref++;
            return \%obj;
        }
        while (1) {
            _skip_ws($sref, $pref);
            my $k = _parse_str($sref, $pref);
            _skip_ws($sref, $pref);
            die "JSON: expected ':' at $$pref\n" unless substr($$sref, $$pref, 1) eq ':';
            $$pref++;
            $obj{$k} = _parse_val($sref, $pref);
            _skip_ws($sref, $pref);
            my $sep = substr($$sref, $$pref, 1);
            if ($sep eq '}') { $$pref++; return \%obj; }
            die "JSON: expected ',' or '}' at $$pref\n" unless $sep eq ',';
            $$pref++;
        }
    }
    if ($ch eq '[') {
        $$pref++;
        my @arr;
        _skip_ws($sref, $pref);
        if ($$pref < $len && substr($$sref, $$pref, 1) eq ']') {
            $$pref++;
            return \@arr;
        }
        while (1) {
            push @arr, _parse_val($sref, $pref);
            _skip_ws($sref, $pref);
            my $sep = substr($$sref, $$pref, 1);
            if ($sep eq ']') { $$pref++; return \@arr; }
            die "JSON: expected ',' or ']' at $$pref\n" unless $sep eq ',';
            $$pref++;
        }
    }
    if (substr($$sref, $$pref, 4) eq 'true') {
        $$pref += 4;
        return 1;
    }
    if (substr($$sref, $$pref, 5) eq 'false') {
        $$pref += 5;
        return 0;
    }
    if (substr($$sref, $$pref, 4) eq 'null') {
        $$pref += 4;
        return undef;
    }
    pos($$sref) = $$pref;
    if ($$sref =~ /\G(-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/gc) {
        $$pref = pos($$sref);
        return $1 + 0;
    }
    die "JSON: unexpected token at $$pref\n";
}

sub decode_json {
    my ($str) = @_;
    die "JSON: input undefined\n" unless defined $str;
    my $copy = $str;
    my $pos  = 0;
    my $val  = _parse_val(\$copy, \$pos);
    _skip_ws(\$copy, \$pos);
    die "JSON: trailing data at $pos\n" if $pos < length($copy);
    return $val;
}

1;
