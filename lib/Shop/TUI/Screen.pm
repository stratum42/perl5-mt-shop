package Shop::TUI::Screen;

use strict;
use warnings;
use utf8;
use MT::Array ();

# Low-egress double-buffered 2D cell ANSI renderer.
#
# Style encoding (64-bit packed integer for O(1) cell comparison, zero mutable state):
#   bits 0..24  : fg (if bit 24 == 0: 0=default, 30..37/90..97=ANSI16, 256..511=256-color;
#                     if bit 24 == 1: 24-bit RGB (r<<16)|(g<<8)|b)
#   bits 25..49 : bg (same encoding as fg)
#   bits 50..53 : flags (bold, dim, rev, ul)

use constant {
    STYLE_DEFAULT => 0,
    FLAG_BOLD     => 1,
    FLAG_DIM      => 2,
    FLAG_REV      => 4,
    FLAG_UL       => 8,

    RGB_FLAG      => 0x1000000,
    COLOR_MASK    => 0x1ffffff,
    GRAPHEME_BASE => 0x200000,

    # Standard 16-color foreground constants (minimal 2-byte SGR codes)
    FG_DEFAULT => 0,
    FG_BLACK   => 30,
    FG_RED     => 31,
    FG_GREEN   => 32,
    FG_YELLOW  => 33,
    FG_BLUE    => 34,
    FG_MAGENTA => 35,
    FG_CYAN    => 36,
    FG_WHITE   => 37,
    FG_BBLACK  => 90,
    FG_BRED    => 91,
    FG_BGREEN  => 92,
    FG_BYELLOW => 93,
    FG_BBLUE   => 94,
    FG_BMAGENTA=> 95,
    FG_BCYAN   => 96,
    FG_BWHITE  => 97,

    # Standard 16-color background constants
    BG_DEFAULT => 0,
    BG_BLACK   => 40,
    BG_RED     => 41,
    BG_GREEN   => 42,
    BG_YELLOW  => 43,
    BG_BLUE    => 44,
    BG_MAGENTA => 45,
    BG_CYAN    => 46,
    BG_WHITE   => 47,
    BG_BBLACK  => 100,
    BG_BRED    => 101,
    BG_BGREEN  => 102,
    BG_BYELLOW => 103,
    BG_BBLUE   => 104,
    BG_BMAGENTA=> 105,
    BG_BCYAN   => 106,
    BG_BWHITE  => 107,
};

# Standard 16-color ANSI palette RGB approximations for clean degradation
my @ANSI16_RGB = (
    [   0,   0,   0 ], # 0  black
    [ 170,   0,   0 ], # 1  red
    [   0, 170,   0 ], # 2  green
    [ 170,  85,   0 ], # 3  yellow
    [   0,   0, 170 ], # 4  blue
    [ 170,   0, 170 ], # 5  magenta
    [   0, 170, 170 ], # 6  cyan
    [ 170, 170, 170 ], # 7  white
    [  85,  85,  85 ], # 8  bright black
    [ 255,  85,  85 ], # 9  bright red
    [  85, 255,  85 ], # 10 bright green
    [ 255, 255,  85 ], # 11 bright yellow
    [  85,  85, 255 ], # 12 bright blue
    [ 255,  85, 255 ], # 13 bright magenta
    [  85, 255, 255 ], # 14 bright cyan
    [ 255, 255, 255 ], # 15 bright white
);

my @CUBE_STEPS = (0, 95, 135, 175, 215, 255);

sub rgb {
    my ($r, $g, $b) = @_;
    $r = int($r // 0); $r = 0 if $r < 0; $r = 255 if $r > 255;
    $g = int($g // 0); $g = 0 if $g < 0; $g = 255 if $g > 255;
    $b = int($b // 0); $b = 0 if $b < 0; $b = 255 if $b > 255;
    return RGB_FLAG | ($r << 16) | ($g << 8) | $b;
}

sub _parse_color {
    my ($val, $rgb_ref) = @_;
    if (ref($rgb_ref) eq 'ARRAY' && @$rgb_ref >= 3) {
        return rgb($rgb_ref->[0], $rgb_ref->[1], $rgb_ref->[2]);
    }
    return 0 unless defined $val;
    if (ref($val) eq 'ARRAY' && @$val >= 3) {
        return rgb($val->[0], $val->[1], $val->[2]);
    }
    if (!ref($val) && $val =~ /\A#?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})\z/) {
        return rgb(hex($1), hex($2), hex($3));
    }
    return int($val) & COLOR_MASK;
}

sub pack_style {
    my (%s) = @_;
    my $fg = _parse_color($s{fg}, $s{fg_rgb});
    my $bg = _parse_color($s{bg}, $s{bg_rgb});
    my $fl = 0;
    $fl |= FLAG_BOLD if $s{bold};
    $fl |= FLAG_DIM  if $s{dim};
    $fl |= FLAG_REV  if $s{rev};
    $fl |= FLAG_UL   if $s{ul};
    return ($fl << 50) | (($bg & COLOR_MASK) << 25) | ($fg & COLOR_MASK);
}

sub detect_color_depth {
    my ($term, $colorterm) = @_;
    $term      = '' unless defined $term;
    $colorterm = '' unless defined $colorterm;
    return 'truecolor' if $colorterm =~ /truecolor|24bit/i || $term =~ /truecolor|direct/i;
    return '256'       if $term =~ /256color|xterm-256|tmux-256|screen-256|kitty|alacritty|wezterm|iterm/i;
    return '16';
}

sub rgb_to_256 {
    my ($r, $g, $b) = @_;
    # Nearest 6x6x6 cube point
    my $ri = $r < 48 ? 0 : ($r < 115 ? 1 : int(($r - 35) / 40));
    my $gi = $g < 48 ? 0 : ($g < 115 ? 1 : int(($g - 35) / 40));
    my $bi = $b < 48 ? 0 : ($b < 115 ? 1 : int(($b - 35) / 40));
    $ri = 5 if $ri > 5; $gi = 5 if $gi > 5; $bi = 5 if $bi > 5;
    my $cr = $CUBE_STEPS[$ri];
    my $cg = $CUBE_STEPS[$gi];
    my $cb = $CUBE_STEPS[$bi];
    my $cube_dist = ($r - $cr)**2 + ($g - $cg)**2 + ($b - $cb)**2;
    my $cube_idx  = 16 + 36 * $ri + 6 * $gi + $bi;

    # Nearest 24-step grayscale ramp (232..255 => 8, 18, ..., 238)
    my $avg = int(($r + $g + $b) / 3);
    my $gi_gray = $avg < 8 ? 0 : ($avg > 238 ? 23 : int(($avg - 8) / 10));
    my $gv = 8 + 10 * $gi_gray;
    my $gray_dist = ($r - $gv)**2 + ($g - $gv)**2 + ($b - $gv)**2;
    my $gray_idx  = 232 + $gi_gray;

    return $gray_dist < $cube_dist ? $gray_idx : $cube_idx;
}

sub _idx256_to_rgb {
    my ($idx) = @_;
    $idx = int($idx // 0);
    if ($idx < 16) {
        return @{ $ANSI16_RGB[$idx] };
    }
    if ($idx < 232) {
        my $n = $idx - 16;
        my $ri = int($n / 36);
        my $gi = int(($n % 36) / 6);
        my $bi = $n % 6;
        return ($CUBE_STEPS[$ri], $CUBE_STEPS[$gi], $CUBE_STEPS[$bi]);
    }
    my $v = 8 + 10 * ($idx - 232);
    return ($v, $v, $v);
}

sub rgb_to_16 {
    my ($r, $g, $b, $is_bg) = @_;
    my $best_i = 0;
    my $best_d = 1e9;
    for (my $i = 0; $i < 16; $i++) {
        my $p = $ANSI16_RGB[$i];
        my $d = ($r - $p->[0])**2 + ($g - $p->[1])**2 + ($b - $p->[2])**2;
        if ($d < $best_d) {
            $best_d = $d;
            $best_i = $i;
        }
    }
    if ($is_bg) {
        return $best_i < 8 ? (40 + $best_i) : (100 + $best_i - 8);
    }
    return $best_i < 8 ? (30 + $best_i) : (90 + $best_i - 8);
}

# Unicode character display width (0 = combining/control, 1 = normal/box-drawing, 2 = wide/emoji)
sub char_width {
    my ($ch) = @_;
    return 0 if !defined $ch || !length($ch);
    my $cp = ord($ch);
    return 0 if $cp < 0x20 || ($cp >= 0x7f && $cp < 0xa0);
    return 1 if $cp < 0x300;
    # Combining diacritical marks & zero-width joiners
    return 0 if ($cp >= 0x0300 && $cp <= 0x036f)
             || ($cp >= 0x1ab0 && $cp <= 0x1aff)
             || ($cp >= 0x1dc0 && $cp <= 0x1dff)
             || ($cp >= 0x20d0 && $cp <= 0x20ff)
             || ($cp >= 0xfe20 && $cp <= 0xfe2f)
             || $cp == 0x200b || $cp == 0x200c || $cp == 0x200d || $cp == 0xfe0e || $cp == 0xfe0f;
    # Box-drawing & Block elements & Geometric shapes are single-width
    return 1 if $cp >= 0x2500 && $cp <= 0x25ff;
    # East Asian Wide / Fullwidth / Hangul / CJK / Emoji
    return 2 if ($cp >= 0x1100 && $cp <= 0x115f)
             || ($cp >= 0x2329 && $cp <= 0x232a)
             || ($cp >= 0x2e80 && $cp <= 0xa4cf && $cp != 0x303f)
             || ($cp >= 0xac00 && $cp <= 0xd7a3)
             || ($cp >= 0xf900 && $cp <= 0xfaff)
             || ($cp >= 0xfe10 && $cp <= 0xfe19)
             || ($cp >= 0xfe30 && $cp <= 0xfe6f)
             || ($cp >= 0xff00 && $cp <= 0xff60)
             || ($cp >= 0xffe0 && $cp <= 0xffe6)
             || ($cp >= 0x1f300 && $cp <= 0x1faff)
             || ($cp >= 0x20000 && $cp <= 0x3fffd);
    return 1;
}

# UAX #29 extended grapheme cluster display width (0, 1, or 2)
sub grapheme_width {
    my ($g) = @_;
    return 0 if !defined $g || !length($g);
    return char_width($g) if length($g) == 1;
    # Regional indicator flag pair, ZWJ sequence, or emoji presentation (U+FE0F)
    return 2 if index($g, "\x{200D}") >= 0
             || index($g, "\x{FE0F}") >= 0
             || $g =~ /\A[\x{1F1E6}-\x{1F1FF}]{2}/;
    # Base character + combining marks (e.g. e\x{0301}) -> width of base char
    return char_width(substr($g, 0, 1));
}

sub _to_chars {
    my ($str) = @_;
    return '' unless defined $str;
    my $copy = $str;
    if (!utf8::is_utf8($copy) && $copy =~ /[\x80-\xff]/) {
        utf8::decode($copy);
    }
    return $copy;
}

sub display_width {
    my ($str) = @_;
    return 0 unless defined $str;
    my $s = _to_chars($str);
    # Strip ANSI CSI escapes if present
    $s =~ s/\e\[[0-9;?]*[ -\/]*[\@-\~]//g if index($s, "\e") >= 0;
    # SIMD-accelerated printable-ASCII fast-path (no \X scan needed)
    return length($s) if $s !~ /[^\x20-\x7e]/;
    my $w = 0;
    while ($s =~ /(\X)/g) {
        $w += grapheme_width($1);
    }
    return $w;
}

sub clip_to_width {
    my ($str, $max_w) = @_;
    return '' if !defined $str || !defined $max_w || $max_w <= 0;
    my $s = _to_chars($str);
    # Printable-ASCII fast-path
    if ($s !~ /[^\x20-\x7e]/) {
        return length($s) <= $max_w ? $s : substr($s, 0, $max_w);
    }
    my $out = '';
    my $w   = 0;
    while ($s =~ /(\X)/g) {
        my $g  = $1;
        my $gw = grapheme_width($g);
        last if $w + $gw > $max_w;
        $out .= $g;
        $w   += $gw;
    }
    return $out;
}

sub new {
    my ($class, %args) = @_;
    my $cols = int($args{cols} // 80);
    my $rows = int($args{rows} // 24);
    $cols = 20 if $cols < 20;
    $rows = 8  if $rows < 8;

    my $env = ref($args{env}) eq 'HASH' ? $args{env} : {};
    my $term      = $args{term}      // $env->{TERM}      // '';
    my $colorterm = $args{colorterm} // $env->{COLORTERM} // '';
    my $depth     = $args{color_depth} // detect_color_depth($term, $colorterm);
    $depth = '16' unless $depth eq 'truecolor' || $depth eq '256' || $depth eq '16';

    my $self = bless {
        cols        => $cols,
        rows        => $rows,
        color_depth => $depth,
        ascii_boxes => $args{ascii_boxes} ? 1 : 0,
        curr_ch     => [],
        curr_st     => [],
        prev_ch     => [],
        prev_st     => [],
        cx          => -1,
        cy          => -1,
        cur_st      => -1,  # unknown SGR state until first reset
        needs_full_clear => 1,

        # Egress telemetry
        frames_rendered        => 0,
        empty_frames_skipped   => 0,
        full_frame_bytes_est   => 0,
        diff_bytes_emitted     => 0,
        last_frame_full_est    => 0,
        last_frame_diff_bytes  => 0,
    }, $class;

    $self->_alloc_buffers();
    return $self;
}

sub _alloc_buffers {
    my ($self) = @_;
    my $n = $self->{cols} * $self->{rows};
    # Use perl5-mt native packed IV arrays (contiguous C int64_t[n], zero per-cell SV overhead):
    # curr_ch/prev_ch store Unicode codepoints: 32 = ' ', 0 = sentinel, -1 = wide-char continuation.
    $self->{curr_ch} = MT::Array::packed('IV', (32) x $n);
    $self->{curr_st} = MT::Array::packed('IV', (0)  x $n);
    $self->{prev_ch} = MT::Array::packed('IV', (0)  x $n);
    $self->{prev_st} = MT::Array::packed('IV', (-1) x $n);
    $self->{cx} = -1;
    $self->{cy} = -1;
    $self->{cur_st} = -1;
    $self->{needs_full_clear} = 1;
}

sub cols            { $_[0]->{cols} }
sub rows            { $_[0]->{rows} }
sub color_depth     { $_[0]->{color_depth} }
sub last_full_bytes { $_[0]->{last_frame_full_est} }
sub last_diff_bytes { $_[0]->{last_frame_diff_bytes} }

sub set_color_depth {
    my ($self, $depth) = @_;
    return unless defined $depth && ($depth eq 'truecolor' || $depth eq '256' || $depth eq '16');
    $self->{color_depth} = $depth;
}

sub resize {
    my ($self, $cols, $rows) = @_;
    $cols = int($cols // 80);
    $rows = int($rows // 24);
    $cols = 20 if $cols < 20;
    $rows = 8  if $rows < 8;
    return 0 if $cols == $self->{cols} && $rows == $self->{rows};
    $self->{cols} = $cols;
    $self->{rows} = $rows;
    $self->_alloc_buffers();
    return 1;
}

sub invalidate {
    my ($self) = @_;
    my $n = $self->{cols} * $self->{rows};
    $self->{prev_ch} = MT::Array::packed('IV', (0)  x $n);
    $self->{prev_st} = MT::Array::packed('IV', (-1) x $n);
    $self->{cx} = -1;
    $self->{cy} = -1;
    $self->{cur_st} = -1;
    $self->{needs_full_clear} = 1;
}

sub clear {
    my ($self, $st) = @_;
    $st //= 0;
    my $n = $self->{cols} * $self->{rows};
    my $curr_ch = $self->{curr_ch};
    my $curr_st = $self->{curr_st};
    for (my $i = 0; $i < $n; $i++) {
        $curr_ch->[$i] = 32;
        $curr_st->[$i] = $st;
    }
}

sub clear_rect {
    my ($self, $x, $y, $w, $h, $st) = @_;
    $st //= 0;
    my ($cols, $rows) = ($self->{cols}, $self->{rows});
    my $curr_ch = $self->{curr_ch};
    my $curr_st = $self->{curr_st};

    my $x0 = $x < 0 ? 0 : $x;
    my $y0 = $y < 0 ? 0 : $y;
    my $x1 = ($x + $w) > $cols ? $cols : ($x + $w);
    my $y1 = ($y + $h) > $rows ? $rows : ($y + $h);
    return if $x0 >= $x1 || $y0 >= $y1;

    for (my $ry = $y0; $ry < $y1; $ry++) {
        my $base = $ry * $cols;
        for (my $rx = $x0; $rx < $x1; $rx++) {
            $curr_ch->[$base + $rx] = 32;
            $curr_st->[$base + $rx] = $st;
        }
    }
}

sub set_cell {
    my ($self, $x, $y, $ch, $st) = @_;
    return if $x < 0 || $y < 0 || $x >= $self->{cols} || $y >= $self->{rows};
    my $idx = $y * $self->{cols} + $x;
    if (defined $ch && length($ch)) {
        my $s = _to_chars($ch);
        $self->{curr_ch}[$idx] = ord(substr($s, 0, 1));
    } else {
        $self->{curr_ch}[$idx] = 32;
    }
    $self->{curr_st}[$idx] = $st // 0;
}

sub _intern_grapheme {
    my ($self, $g, $gw) = @_;
    my $map = $self->{_g_by_str} ||= {};
    my $id  = $map->{$g};
    return $id if defined $id;
    my $arr = $self->{_g_by_id} ||= [];
    my $bytes = $g;
    utf8::encode($bytes) if utf8::is_utf8($bytes);
    my $idx = scalar(@$arr);
    push @$arr, [ $bytes, $gw, $g ];
    $id = GRAPHEME_BASE + $idx;
    $map->{$g} = $id;
    return $id;
}

sub write_str {
    my ($self, $x, $y, $str, $st, $max_w) = @_;
    return if !defined $str || $y < 0 || $y >= $self->{rows};
    $st //= 0;
    my $cols  = $self->{cols};
    my $limit = defined $max_w ? ($x + $max_w) : $cols;
    $limit = $cols if $limit > $cols;
    return if $x >= $limit;

    my $s = _to_chars($str);
    # Strip control characters that could corrupt terminal state
    $s =~ s/[\x00-\x1f\x7f]/ /g;

    my $curr_ch = $self->{curr_ch};
    my $curr_st = $self->{curr_st};
    my $base    = $y * $cols;

    # Printable-ASCII fast-path (skips \X grapheme scanner completely)
    if ($s !~ /[^\x20-\x7e]/) {
        my $len = length($s);
        my $i   = 0;
        if ($x < 0) {
            $i = -$x;
            $x = 0;
        }
        while ($i < $len && $x < $limit) {
            $curr_ch->[$base + $x] = ord(substr($s, $i, 1));
            $curr_st->[$base + $x] = $st;
            $i++;
            $x++;
        }
        return;
    }

    # Full UAX #29 extended grapheme cluster path (\X)
    while ($s =~ /(\X)/g && $x < $limit) {
        my $g  = $1;
        my $gw = grapheme_width($g);
        next if $gw == 0;

        if ($x < 0) {
            $x += $gw;
            next;
        }
        my $val = length($g) == 1 ? ord($g) : $self->_intern_grapheme($g, $gw);
        if ($gw == 2) {
            last if $x + 2 > $limit;
            $curr_ch->[$base + $x]     = $val;
            $curr_st->[$base + $x]     = $st;
            $curr_ch->[$base + $x + 1] = -1; # wide-char continuation sentinel
            $curr_st->[$base + $x + 1] = $st;
            $x += 2;
        } else {
            $curr_ch->[$base + $x] = $val;
            $curr_st->[$base + $x] = $st;
            $x++;
        }
    }
}

sub hline {
    my ($self, $x, $y, $w, $ch, $st) = @_;
    $ch //= ($self->{ascii_boxes} ? '-' : '─');
    $ch = _to_chars($ch);
    my $cp = ord(substr($ch, 0, 1));
    $st //= 0;
    return if $y < 0 || $y >= $self->{rows} || $w <= 0;
    my $cols = $self->{cols};
    my $x0 = $x < 0 ? 0 : $x;
    my $x1 = ($x + $w) > $cols ? $cols : ($x + $w);
    return if $x0 >= $x1;
    my $base = $y * $cols;
    my $curr_ch = $self->{curr_ch};
    my $curr_st = $self->{curr_st};
    for (my $rx = $x0; $rx < $x1; $rx++) {
        $curr_ch->[$base + $rx] = $cp;
        $curr_st->[$base + $rx] = $st;
    }
}

sub vline {
    my ($self, $x, $y, $h, $ch, $st) = @_;
    $ch //= ($self->{ascii_boxes} ? '|' : '│');
    $ch = _to_chars($ch);
    my $cp = ord(substr($ch, 0, 1));
    $st //= 0;
    return if $x < 0 || $x >= $self->{cols} || $h <= 0;
    my $rows = $self->{rows};
    my $y0 = $y < 0 ? 0 : $y;
    my $y1 = ($y + $h) > $rows ? $rows : ($y + $h);
    return if $y0 >= $y1;
    my $cols = $self->{cols};
    my $curr_ch = $self->{curr_ch};
    my $curr_st = $self->{curr_st};
    for (my $ry = $y0; $ry < $y1; $ry++) {
        my $idx = $ry * $cols + $x;
        $curr_ch->[$idx] = $cp;
        $curr_st->[$idx] = $st;
    }
}

sub box {
    my ($self, $x, $y, $w, $h, $st, $title, $title_st) = @_;
    return if $w < 2 || $h < 2;
    $st //= 0;
    my ($tl, $tr, $bl, $br, $hz, $vt) = $self->{ascii_boxes}
        ? ('+', '+', '+', '+', '-', '|')
        : ('╭', '╮', '╰', '╯', '─', '│');

    $self->set_cell($x,          $y,          $tl, $st);
    $self->set_cell($x + $w - 1, $y,          $tr, $st);
    $self->set_cell($x,          $y + $h - 1, $bl, $st);
    $self->set_cell($x + $w - 1, $y + $h - 1, $br, $st);
    $self->hline($x + 1, $y,          $w - 2, $hz, $st);
    $self->hline($x + 1, $y + $h - 1, $w - 2, $hz, $st);
    $self->vline($x,          $y + 1, $h - 2, $vt, $st);
    $self->vline($x + $w - 1, $y + 1, $h - 2, $vt, $st);
    if (defined $title && length($title) && $w > 4) {
        my $t = " $title ";
        $t = clip_to_width($t, $w - 4) if display_width($t) > $w - 4;
        $self->write_str($x + 2, $y, $t, $title_st // $st, $w - 4);
    }
}

# Cursor jump optimizer: picks shortest ANSI sequence from (cx, cy) to (tx, ty)
sub _move_cursor {
    my ($cx, $cy, $tx, $ty) = @_;
    return '' if $cy == $ty && $cx == $tx;

    # Canonical CUP
    my $best;
    if ($tx == 0 && $ty == 0) {
        $best = "\e[H";
    } elsif ($tx == 0) {
        $best = "\e[" . ($ty + 1) . "H";
    } else {
        $best = "\e[" . ($ty + 1) . ";" . ($tx + 1) . "H";
    }
    my $best_len = length($best);

    return $best if $cx < 0 || $cy < 0;

    if ($cy == $ty) {
        if ($tx == 0) {
            return "\r";
        }
        my $dx = $tx - $cx;
        if ($dx > 0) {
            my $cuf = $dx == 1 ? "\e[C" : "\e[${dx}C";
            if (length($cuf) < $best_len) { $best = $cuf; $best_len = length($cuf); }
        } else {
            my $adx = -$dx;
            my $cub = $adx == 1 ? "\b" : ($adx == 2 ? "\b\b" : "\e[${adx}D");
            if (length($cub) < $best_len) { $best = $cub; $best_len = length($cub); }
            my $cr_cuf = "\r" . ($tx == 1 ? "\e[C" : "\e[${tx}C");
            if (length($cr_cuf) < $best_len) { $best = $cr_cuf; $best_len = length($cr_cuf); }
        }
    } elsif ($ty == $cy + 1 && $tx == 0) {
        if (2 < $best_len) { $best = "\r\n"; $best_len = 2; }
    } elsif ($tx == $cx) {
        my $dy = $ty - $cy;
        if ($dy > 0) {
            my $cud = $dy == 1 ? "\n" : "\e[${dy}B";
            if (length($cud) < $best_len) { $best = $cud; $best_len = length($cud); }
        } else {
            my $ady = -$dy;
            my $cuu = $ady == 1 ? "\e[A" : "\e[${ady}A";
            if (length($cuu) < $best_len) { $best = $cuu; $best_len = length($cuu); }
        }
    }

    return $best;
}

sub color_to_sgr {
    my ($val, $is_bg, $depth) = @_;
    $depth ||= '256';
    return ($is_bg ? '49' : '39') if $val == 0;

    if ($val & RGB_FLAG) {
        my $r = ($val >> 16) & 0xff;
        my $g = ($val >> 8)  & 0xff;
        my $b =  $val        & 0xff;
        if ($depth eq 'truecolor') {
            return ($is_bg ? '48;2;' : '38;2;') . "$r;$g;$b";
        } elsif ($depth eq '256') {
            my $idx = rgb_to_256($r, $g, $b);
            return ($is_bg ? '48;5;' : '38;5;') . $idx;
        } else {
            return '' . rgb_to_16($r, $g, $b, $is_bg);
        }
    }

    if ($val >= 256) {
        my $idx = $val - 256;
        if ($depth eq '16') {
            my ($r, $g, $b) = _idx256_to_rgb($idx);
            return '' . rgb_to_16($r, $g, $b, $is_bg);
        }
        return ($is_bg ? '48;5;' : '38;5;') . $idx;
    }

    return '' . $val;
}

# Minimal SGR delta emitter
sub _sgr_delta {
    my ($cur, $tgt, $depth) = @_;
    return '' if $cur == $tgt;
    return "\e[m" if $tgt == 0;
    $depth ||= '256';

    my $tfg =  $tgt        & COLOR_MASK;
    my $tbg = ($tgt >> 25) & COLOR_MASK;
    my $tfl = ($tgt >> 50) & 0x0f;

    # Option B: full reset + target attributes
    my @reset_codes = ('0');
    push @reset_codes, '1' if $tfl & FLAG_BOLD;
    push @reset_codes, '2' if $tfl & FLAG_DIM;
    push @reset_codes, '7' if $tfl & FLAG_REV;
    push @reset_codes, '4' if $tfl & FLAG_UL;
    push @reset_codes, color_to_sgr($tfg, 0, $depth) if $tfg != 0;
    push @reset_codes, color_to_sgr($tbg, 1, $depth) if $tbg != 0;
    my $opt_reset = "\e[" . join(';', @reset_codes) . "m";

    return $opt_reset if $cur < 0;

    my $cfg =  $cur        & COLOR_MASK;
    my $cbg = ($cur >> 25) & COLOR_MASK;
    my $cfl = ($cur >> 50) & 0x0f;

    # Option A: incremental delta
    my @delta;
    my $c_bold = ($cfl & FLAG_BOLD) ? 1 : 0;
    my $t_bold = ($tfl & FLAG_BOLD) ? 1 : 0;
    my $c_dim  = ($cfl & FLAG_DIM)  ? 1 : 0;
    my $t_dim  = ($tfl & FLAG_DIM)  ? 1 : 0;

    if (($c_bold && !$t_bold) || ($c_dim && !$t_dim)) {
        push @delta, '22';
        push @delta, '1' if $t_bold;
        push @delta, '2' if $t_dim;
    } else {
        push @delta, '1' if !$c_bold && $t_bold;
        push @delta, '2' if !$c_dim  && $t_dim;
    }

    my $c_rev = ($cfl & FLAG_REV) ? 1 : 0;
    my $t_rev = ($tfl & FLAG_REV) ? 1 : 0;
    if ($c_rev != $t_rev) {
        push @delta, $t_rev ? '7' : '27';
    }

    my $c_ul = ($cfl & FLAG_UL) ? 1 : 0;
    my $t_ul = ($tfl & FLAG_UL) ? 1 : 0;
    if ($c_ul != $t_ul) {
        push @delta, $t_ul ? '4' : '24';
    }

    if ($cfg != $tfg) {
        push @delta, color_to_sgr($tfg, 0, $depth);
    }
    if ($cbg != $tbg) {
        push @delta, color_to_sgr($tbg, 1, $depth);
    }

    return '' unless @delta;
    my $opt_delta = "\e[" . join(';', @delta) . "m";
    return length($opt_delta) <= length($opt_reset) ? $opt_delta : $opt_reset;
}

# Estimate what a naive full-frame ANSI render of the current buffer would cost
sub _estimate_full_frame_bytes {
    my ($self) = @_;
    my ($cols, $rows) = ($self->{cols}, $self->{rows});
    my $curr_st = $self->{curr_st};
    my $depth   = $self->{color_depth};
    # Naive full-frame: \e[2J\e[H + per-row CUP + all cells + SGR transitions
    my $est = 7 + 16; # clear + home + sync wrapper
    my $st = 0;
    for (my $y = 0; $y < $rows; $y++) {
        $est += length("\e[" . ($y + 1) . ";1H") + $cols;
        my $base = $y * $cols;
        for (my $x = 0; $x < $cols; $x++) {
            my $nst = $curr_st->[$base + $x];
            if ($nst != $st) {
                $est += length(_sgr_delta($st, $nst, $depth));
                $st = $nst;
            }
        }
    }
    return $est;
}

# Render diff between curr and prev buffers into minimal ANSI UTF-8 byte stream.
# Returns '' if nothing changed.
sub render {
    my ($self) = @_;
    my ($cols, $rows) = ($self->{cols}, $self->{rows});
    my $curr_ch = $self->{curr_ch};
    my $curr_st = $self->{curr_st};
    my $prev_ch = $self->{prev_ch};
    my $prev_st = $self->{prev_st};
    my $depth   = $self->{color_depth};

    my $cx     = $self->{cx};
    my $cy     = $self->{cy};
    my $cur_st = $self->{cur_st};

    my $buf = '';

    if ($self->{needs_full_clear}) {
        $buf .= "\e[m\e[2J\e[H";
        $cx = 0;
        $cy = 0;
        $cur_st = 0;
        $self->{needs_full_clear} = 0;
        # Since we cleared the terminal to blank with default style,
        # prev is now effectively all (32=' ', 0)!
        my $n = $cols * $rows;
        for (my $i = 0; $i < $n; $i++) {
            $prev_ch->[$i] = 32;
            $prev_st->[$i] = 0;
        }
    }

    for (my $y = 0; $y < $rows; $y++) {
        my $base = $y * $cols;

        # Quick scan: find first and last changed column on this row (pure integer compares!)
        my $first_chg = -1;
        my $last_chg  = -1;
        for (my $x = 0; $x < $cols; $x++) {
            my $idx = $base + $x;
            if ($curr_ch->[$idx] != $prev_ch->[$idx] || $curr_st->[$idx] != $prev_st->[$idx]) {
                $first_chg = $x if $first_chg < 0;
                $last_chg  = $x;
            }
        }
        next if $first_chg < 0; # Entire row unchanged!

        # Check for trailing blank cells with default style (EL / \e[K optimization)
        my $last_nonblank = $cols - 1;
        while ($last_nonblank >= 0) {
            my $idx = $base + $last_nonblank;
            last if $curr_ch->[$idx] != 32 || $curr_st->[$idx] != 0;
            $last_nonblank--;
        }

        my $use_el = 0;
        my $el_start = $last_nonblank + 1;
        if ($el_start <= $last_chg) {
            my $trailing_changed = 0;
            for (my $x = $el_start; $x <= $last_chg; $x++) {
                my $idx = $base + $x;
                if ($curr_ch->[$idx] != $prev_ch->[$idx] || $curr_st->[$idx] != $prev_st->[$idx]) {
                    $trailing_changed++;
                }
            }
            if ($trailing_changed > 4) {
                $use_el = 1;
                $last_chg = $last_nonblank;
            }
        }

        # Emit changed cells from first_chg .. last_chg
        for (my $x = $first_chg; $x <= $last_chg; $x++) {
            my $idx = $base + $x;
            my $cp = $curr_ch->[$idx];
            my $st = $curr_st->[$idx];
            next if $cp == $prev_ch->[$idx] && $st == $prev_st->[$idx];

            # Skip wide-char continuation sentinel (covered by preceding cell)
            if ($cp < 0) {
                $prev_ch->[$idx] = -1;
                $prev_st->[$idx] = $st;
                next;
            }

            if ($cx != $x || $cy != $y) {
                $buf .= _move_cursor($cx, $cy, $x, $y);
                $cx = $x;
                $cy = $y;
            }
            if ($cur_st != $st) {
                $buf .= _sgr_delta($cur_st, $st, $depth);
                $cur_st = $st;
            }

            my ($out_ch, $cw);
            if ($cp >= GRAPHEME_BASE) {
                my $ge = $self->{_g_by_id}[$cp - GRAPHEME_BASE];
                $out_ch = $ge->[0];
                $cw     = $ge->[1];
            } else {
                my $ch = chr($cp);
                $cw = ($cp < 0x1100) ? 1 : char_width($ch);
                $out_ch = $ch;
                utf8::encode($out_ch) if $cp >= 0x80;
            }
            $cw = 1 if $cw < 1;
            $buf .= $out_ch;
            $prev_ch->[$idx] = $cp;
            $prev_st->[$idx] = $st;

            if ($x + $cw >= $cols) {
                $cx = -1;
            } else {
                $cx += $cw;
            }
        }

        # Emit Erase-to-EOL (\e[K) for trailing default-blank cells
        if ($use_el) {
            if ($cx != $el_start || $cy != $y) {
                $buf .= _move_cursor($cx, $cy, $el_start, $y);
                $cx = $el_start;
                $cy = $y;
            }
            if ($cur_st != 0) {
                $buf .= "\e[m";
                $cur_st = 0;
            }
            $buf .= "\e[K";
            for (my $x = $el_start; $x < $cols; $x++) {
                my $idx = $base + $x;
                $prev_ch->[$idx] = 32;
                $prev_st->[$idx] = 0;
            }
        }
    }

    $self->{cx}     = $cx;
    $self->{cy}     = $cy;
    $self->{cur_st} = $cur_st;

    if (!length($buf)) {
        $self->{empty_frames_skipped}++;
        $self->{last_frame_full_est}   = 0;
        $self->{last_frame_diff_bytes} = 0;
        return '';
    }

    # Wrap non-empty diff in Synchronized Output (DEC mode 2026)
    my $out = "\e[?2026h" . $buf . "\e[?2026l";

    my $full_est = $self->_estimate_full_frame_bytes();
    my $diff_len = length($out);

    $self->{frames_rendered}++;
    $self->{full_frame_bytes_est} += $full_est;
    $self->{diff_bytes_emitted}   += $diff_len;
    $self->{last_frame_full_est}   = $full_est;
    $self->{last_frame_diff_bytes} = $diff_len;

    return $out;
}

# Enter alternate screen, hide cursor, enable SGR mouse reporting (1000 + 1006)
sub init_sequence {
    return "\e[?1049h\e[?25l\e[?1000h\e[?1006h\e[m\e[2J\e[H";
}

# Disable SGR mouse reporting, reset SGR, show cursor, leave alternate screen
sub cleanup_sequence {
    return "\e[?1006l\e[?1000l\e[m\e[?25h\e[?1049l";
}

sub metrics {
    my ($self) = @_;
    my $full = $self->{full_frame_bytes_est};
    my $diff = $self->{diff_bytes_emitted};
    my $pct  = $full > 0 ? sprintf('%.2f', 100.0 * (1.0 - ($diff / $full))) + 0 : 0.0;
    my $last_full = $self->{last_frame_full_est};
    my $last_diff = $self->{last_frame_diff_bytes};
    my $last_pct  = $last_full > 0 ? sprintf('%.2f', 100.0 * (1.0 - ($last_diff / $last_full))) + 0 : 0.0;
    return {
        color_depth           => $self->{color_depth},
        frames_rendered       => $self->{frames_rendered},
        empty_frames_skipped  => $self->{empty_frames_skipped},
        full_frame_bytes_est  => $full,
        diff_bytes_emitted    => $diff,
        savings_pct           => $pct,
        last_full_bytes       => $last_full,
        last_diff_bytes       => $last_diff,
        last_frame_full_est   => $last_full,
        last_frame_diff_bytes => $last_diff,
        last_frame_savings_pct=> $last_pct,
    };
}

1;
