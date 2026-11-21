package Shop::TUI::Input;

use strict;
use warnings;

# Parses raw SSH byte streams into structured key events.
# Supports partial ANSI/CSI escape sequences across non-blocking reads.
#
# Event hashref format:
#   { type => 'UP' | 'DOWN' | 'LEFT' | 'RIGHT' | 'ENTER' | 'ESC' |
#             'TAB' | 'SHIFT_TAB' | 'BACKSPACE' | 'CTRL_C' | 'CTRL_L' |
#             'HOME' | 'END' | 'PGUP' | 'PGDN' | 'CHAR' | 'MOUSE',
#     char   => $ch,       # defined for CHAR
#     vim    => $nav_dir,  # 'DOWN'|'UP'|'LEFT'|'RIGHT' for j/k/h/l
#     button => 'left'|'right'|'middle'|'wheel_up'|'wheel_down', # for MOUSE
#     x      => $col,      # 0-based column for MOUSE
#     y      => $row,      # 0-based row for MOUSE
#     press  => 1|0,       # 1 on press ('M'), 0 on release ('m')
#   }

sub new {
    my ($class) = @_;
    return bless {
        buf => '',
    }, $class;
}

# Helper to normalize arrow + vim navigation when not in a text input field
sub nav {
    my ($ev) = @_;
    return '' unless ref($ev) eq 'HASH';
    my $t = $ev->{type} // '';
    return $t if $t eq 'UP' || $t eq 'DOWN' || $t eq 'LEFT' || $t eq 'RIGHT';
    return $ev->{vim} // '';
}

sub parse {
    my ($self, $bytes) = @_;
    $bytes = '' unless defined $bytes;
    my $buf = $self->{buf} . $bytes;
    $self->{buf} = '';

    my @events;
    my $len = length($buf);
    my $i   = 0;

    while ($i < $len) {
        my $b = ord(substr($buf, $i, 1));

        # Escape sequences
        if ($b == 0x1b) {
            if ($i + 1 >= $len) {
                # Standalone ESC (no following bytes in this chunk)
                push @events, { type => 'ESC' };
                $i++;
                next;
            }
            my $next = substr($buf, $i + 1, 1);
            if ($next eq '[' || $next eq 'O') {
                # CSI (\e[...) or SS3 (\eO...)
                if ($next eq 'O') {
                    if ($i + 2 >= $len) {
                        # Incomplete SS3, buffer it
                        $self->{buf} = substr($buf, $i);
                        last;
                    }
                    my $c = substr($buf, $i + 2, 1);
                    if    ($c eq 'A') { push @events, { type => 'UP' }; }
                    elsif ($c eq 'B') { push @events, { type => 'DOWN' }; }
                    elsif ($c eq 'C') { push @events, { type => 'RIGHT' }; }
                    elsif ($c eq 'D') { push @events, { type => 'LEFT' }; }
                    elsif ($c eq 'H') { push @events, { type => 'HOME' }; }
                    elsif ($c eq 'F') { push @events, { type => 'END' }; }
                    $i += 3;
                    next;
                }

                # CSI: \e[ followed by parameter bytes (0x30-0x3F), intermediate (0x20-0x2F), final (0x40-0x7E)
                my $j = $i + 2;
                while ($j < $len) {
                    my $cb = ord(substr($buf, $j, 1));
                    last if $cb >= 0x40 && $cb <= 0x7e;
                    $j++;
                }
                if ($j >= $len) {
                    # Incomplete CSI sequence; if absurdly long, drop ESC
                    if ($len - $i > 24) {
                        push @events, { type => 'ESC' };
                        $i++;
                    } else {
                        $self->{buf} = substr($buf, $i);
                        last;
                    }
                    next;
                }

                my $params = substr($buf, $i + 2, $j - ($i + 2));
                my $final  = substr($buf, $j, 1);

                # SGR Mouse reporting: \e[<Cb;Cx;CyM (press) or \e[<Cb;Cx;Cym (release)
                if (($final eq 'M' || $final eq 'm') && $params =~ /\A<(\d+);(\d+);(\d+)\z/) {
                    my ($cb, $cx, $cy) = (int($1), int($2), int($3));
                    my $press = ($final eq 'M') ? 1 : 0;
                    my $btn;
                    if ($cb & 64) {
                        $btn = (($cb & 3) == 0) ? 'wheel_up'
                             : (($cb & 3) == 1) ? 'wheel_down'
                             :                    'wheel_up';
                    } elsif (!($cb & 32)) {
                        my $low = $cb & 3;
                        $btn = ($low == 0) ? 'left'
                             : ($low == 1) ? 'middle'
                             : ($low == 2) ? 'right'
                             :               'left';
                    }
                    if (defined $btn) {
                        push @events, {
                            type   => 'MOUSE',
                            button => $btn,
                            x      => ($cx > 0 ? $cx - 1 : 0),
                            y      => ($cy > 0 ? $cy - 1 : 0),
                            press  => $press,
                        };
                    }
                    $i = $j + 1;
                    next;
                }

                if    ($final eq 'A') { push @events, { type => 'UP' }; }
                elsif ($final eq 'B') { push @events, { type => 'DOWN' }; }
                elsif ($final eq 'C') { push @events, { type => 'RIGHT' }; }
                elsif ($final eq 'D') { push @events, { type => 'LEFT' }; }
                elsif ($final eq 'H') { push @events, { type => 'HOME' }; }
                elsif ($final eq 'F') { push @events, { type => 'END' }; }
                elsif ($final eq 'Z') { push @events, { type => 'SHIFT_TAB' }; }
                elsif ($final eq '~') {
                    if    ($params eq '1' || $params eq '7') { push @events, { type => 'HOME' }; }
                    elsif ($params eq '4' || $params eq '8') { push @events, { type => 'END' }; }
                    elsif ($params eq '5')                   { push @events, { type => 'PGUP' }; }
                    elsif ($params eq '6')                   { push @events, { type => 'PGDN' }; }
                    elsif ($params eq '3')                   { push @events, { type => 'BACKSPACE' }; }
                }
                $i = $j + 1;
                next;
            }
            # Lone ESC followed by non-CSI char
            push @events, { type => 'ESC' };
            $i++;
            next;
        }

        # Control keys
        if ($b == 0x03) {
            push @events, { type => 'CTRL_C' };
            $i++;
            next;
        }
        if ($b == 0x0c) {
            push @events, { type => 'CTRL_L' };
            $i++;
            next;
        }
        if ($b == 0x0d || $b == 0x0a) {
            push @events, { type => 'ENTER' };
            # Collapse \r\n into a single ENTER
            if ($b == 0x0d && $i + 1 < $len && ord(substr($buf, $i + 1, 1)) == 0x0a) {
                $i += 2;
            } else {
                $i++;
            }
            next;
        }
        if ($b == 0x09) {
            push @events, { type => 'TAB' };
            $i++;
            next;
        }
        if ($b == 0x7f || $b == 0x08) {
            push @events, { type => 'BACKSPACE' };
            $i++;
            next;
        }

        # Printable ASCII (0x20 .. 0x7e)
        if ($b >= 0x20 && $b <= 0x7e) {
            my $ch = chr($b);
            my $ev = { type => 'CHAR', char => $ch };
            if    ($ch eq 'j') { $ev->{vim} = 'DOWN'; }
            elsif ($ch eq 'k') { $ev->{vim} = 'UP'; }
            elsif ($ch eq 'h') { $ev->{vim} = 'LEFT'; }
            elsif ($ch eq 'l') { $ev->{vim} = 'RIGHT'; }
            push @events, $ev;
            $i++;
            next;
        }

        # Ignore other control / non-ASCII bytes
        $i++;
    }

    return @events;
}

1;
