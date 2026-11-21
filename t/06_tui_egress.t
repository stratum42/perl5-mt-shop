#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Shop::TUI::Screen;
use Shop::TUI::Input;
use Shop::TUI::App;

# --- 1. Screen double-buffered ANSI diff & egress savings ---
my $scr = Shop::TUI::Screen->new(cols => 80, rows => 24);
my $st_hdr  = Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BWHITE, bg => Shop::TUI::Screen::BG_BLUE, bold => 1);
my $st_sel  = Shop::TUI::Screen::pack_style(rev => 1, bold => 1);
my $st_ok   = Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_GREEN);
my $st_low  = Shop::TUI::Screen::pack_style(fg => Shop::TUI::Screen::FG_BYELLOW, bold => 1);

sub draw_mock_catalog {
    my ($s, $sel_row, $stock_val, $ticker) = @_;
    $s->clear();
    $s->clear_rect(0, 0, $s->cols, 1, $st_hdr);
    $s->write_str(1, 0, "PERL5-MT SHOP  [1]Shop  [2]Cart(0)  [3]Orders", $st_hdr);
    $s->box(0, 2, 46, 18, 0, "Catalog");
    $s->box(47, 2, 33, 18, 0, "Preview");
    for my $i (0 .. 9) {
        my $st = ($i == $sel_row) ? $st_sel : 0;
        my $qty = ($i == 2) ? $stock_val : (10 + $i);
        $s->write_str(2, 4 + $i, sprintf("SKU-%03d  Item %-14d  \$%5.2f  [%2d]", $i, $i, 19.99 + $i, $qty), $st, 42);
    }
    $s->write_str(49, 4, "Selected Item #$sel_row", $st_ok, 28);
    $s->write_str(49, 6, "  +-------+  ", 0, 28);
    $s->write_str(49, 7, "  |  MT5  |  ", 0, 28);
    $s->write_str(49, 8, "  +-------+  ", 0, 28);
    $s->write_str(1, 23, $ticker, $st_low, 78);
}

# Initial frame
draw_mock_catalog($scr, 0, 12, "Ready");
my $f1 = $scr->render();
ok(length($f1) > 0, "initial frame emitted (" . length($f1) . " bytes)");
like($f1, qr/\A\e\[\?2026h/, "wrapped in synchronized output start (\\e[?2026h)");
like($f1, qr/\e\[\?2026l\z/, "wrapped in synchronized output end (\\e[?2026l)");
cmp_ok($scr->last_full_bytes, '>', 0, "last_full_bytes populated after render");
is($scr->last_diff_bytes, length($f1), "last_diff_bytes matches emitted diff length");

# Identical frame -> 0 bytes emitted
draw_mock_catalog($scr, 0, 12, "Ready");
my $f_idle = $scr->render();
is($f_idle, '', "unchanged frame emits 0 bytes");
is($scr->last_full_bytes, 0, "last_full_bytes is 0 on skipped idle frame");
is($scr->last_diff_bytes, 0, "last_diff_bytes is 0 on skipped idle frame");

# Incremental updates: 15 cursor moves + live stock ticks
my $inc_full_total = 0;
my $inc_diff_total = 0;
for my $step (1 .. 15) {
    my $sel = $step % 10;
    my $stk = 12 - ($step % 5);
    draw_mock_catalog($scr, $sel, $stk, "Live stock tick #$step");
    my $diff = $scr->render();
    my $m = $scr->metrics();
    $inc_full_total += $m->{last_full_bytes};
    $inc_diff_total += $m->{last_diff_bytes};
    ok(length($diff) > 0, "incremental step $step emitted " . length($diff) . " B vs full est $m->{last_full_bytes} B");
}

my $inc_savings = 100.0 * (1.0 - ($inc_diff_total / $inc_full_total));
diag(sprintf("Incremental ANSI diff egress: %d B vs %d B naive full-frame (%.2f%% reduction)",
    $inc_diff_total, $inc_full_total, $inc_savings));
cmp_ok($inc_savings, '>', 85.0, sprintf("ANSI diff savings %.2f%% > 85%%", $inc_savings));

# Erase-to-EOL (\e[K) check when a long line shortens
$scr->write_str(0, 22, "X" x 70, 0);
my $f_long = $scr->render();
$scr->write_str(0, 22, "Short" . (" " x 65), 0);
my $f_short = $scr->render();
like($f_short, qr/\e\[K/, "erase-to-EOL (\\e[K) emitted when trailing cells clear to blank");
cmp_ok(length($f_short), '<', 40, "shortened line diff is tiny (" . length($f_short) . " B)");

# Resize handling (window-change reflow)
ok($scr->resize(100, 30), "resize 80x24 -> 100x30 returns true");
is($scr->cols, 100, "cols updated to 100");
is($scr->rows, 30,  "rows updated to 30");
ok(!$scr->resize(100, 30), "no-op resize returns false");
draw_mock_catalog($scr, 1, 10, "Resized to 100x30");
my $f_resize = $scr->render();
like($f_resize, qr/\e\[2J/, "resize triggers clean full redraw");

# SGR mouse reporting init/cleanup sequences
like(Shop::TUI::Screen::init_sequence(),    qr/\e\[\?1000h\e\[\?1006h/, "init_sequence enables SGR mouse reporting");
like(Shop::TUI::Screen::cleanup_sequence(), qr/\e\[\?1006l\e\[\?1000l/, "cleanup_sequence disables SGR mouse reporting");

# --- 2. Color depth probing & RGB degradation (truecolor / 256 / 16) ---
is(Shop::TUI::Screen::detect_color_depth('xterm-256color', 'truecolor'), 'truecolor', "COLORTERM=truecolor -> truecolor");
is(Shop::TUI::Screen::detect_color_depth('xterm-256color', '24bit'),     'truecolor', "COLORTERM=24bit -> truecolor");
is(Shop::TUI::Screen::detect_color_depth('xterm-256color', ''),          '256',       "TERM=xterm-256color -> 256");
is(Shop::TUI::Screen::detect_color_depth('vt100', ''),                   '16',        "TERM=vt100 -> 16");

my $rgb_st = Shop::TUI::Screen::pack_style(fg_rgb => [255, 100, 50], bg_rgb => [10, 20, 30], bold => 1);

my $s_tc = Shop::TUI::Screen->new(cols => 40, rows => 10, env => { TERM => 'xterm-256color', COLORTERM => 'truecolor' });
is($s_tc->color_depth, 'truecolor', "Screen auto-detected truecolor from env");
$s_tc->write_str(0, 0, "PQ-SSH", $rgb_st);
my $out_tc = $s_tc->render();
like($out_tc, qr/38;2;255;100;50/, "truecolor emits 24-bit fg SGR");
like($out_tc, qr/48;2;10;20;30/,   "truecolor emits 24-bit bg SGR");

my $s_256 = Shop::TUI::Screen->new(cols => 40, rows => 10, env => { TERM => 'xterm-256color' });
is($s_256->color_depth, '256', "Screen auto-detected 256-color from env");
$s_256->write_str(0, 0, "PQ-SSH", $rgb_st);
my $out_256 = $s_256->render();
like($out_256,   qr/38;5;\d+/, "256-color degrades RGB fg to 38;5;N");
like($out_256,   qr/48;5;\d+/, "256-color degrades RGB bg to 48;5;N");
unlike($out_256, qr/38;2;/,    "256-color never emits 24-bit SGR");

my $s_16 = Shop::TUI::Screen->new(cols => 40, rows => 10, env => { TERM => 'vt100' });
is($s_16->color_depth, '16', "Screen auto-detected 16-color from env");
$s_16->write_str(0, 0, "PQ-SSH", $rgb_st);
my $out_16 = $s_16->render();
unlike($out_16, qr/38;2;|38;5;|48;2;|48;5;/, "16-color degrades RGB cleanly to ANSI-16 SGR");
like($out_16,   qr/\e\[[0-9;]*mPQ-SSH/,      "16-color emits valid SGR + text");

# --- 3. Unicode display-width & clipping ---
is(Shop::TUI::Screen::display_width("Hello"),       5, "ASCII display_width is 5");
is(Shop::TUI::Screen::display_width("╭───╮"),       5, "Box-drawing display_width is 5 (not 15 UTF-8 bytes)");
is(Shop::TUI::Screen::display_width("日本語"),       6, "CJK display_width is 6 (3 wide chars)");
is(Shop::TUI::Screen::display_width("🚀OK"),         4, "Emoji + ASCII display_width is 4");
is(Shop::TUI::Screen::clip_to_width("日本語ABC", 5), "日本", "clip_to_width stops cleanly before splitting wide char");

my $s_uni = Shop::TUI::Screen->new(cols => 20, rows => 8);
$s_uni->box(0, 0, 12, 5, 0, "╭Title╮");
$s_uni->write_str(1, 2, "日本語TEST", 0, 5); # max_w=5 -> fits 2 wide chars (width 4), doesn't overwrite border at col 11
my $out_uni = $s_uni->render();
ok(length($out_uni) > 0, "Unicode box + clipped wide string rendered cleanly");
is(chr($s_uni->{curr_ch}[2 * 20 + 11]), '│', "right box border intact after clipped wide write_str");
is(MT::Array::is_packed($s_uni->{curr_ch}), 'IV', "Screen cell buffer stays packed IV MT::Array");

# UAX #29 extended grapheme clusters (\X): combining marks, ZWJ emojis, flags, skin tones
my $combining = "Cafe\x{0301}";                    # decomposed e + combining acute -> width 4
my $zwj_fam   = "\x{1F468}\x{200D}\x{1F469}\x{200D}\x{1F467}\x{200D}\x{1F466}"; # ZWJ family -> width 2
my $us_flag   = "\x{1F1FA}\x{1F1F8}";               # regional indicator flag -> width 2
my $thumbs    = "\x{1F44D}\x{1F3FD}";               # skin-tone modifier emoji -> width 2
is(Shop::TUI::Screen::display_width($combining), 4, "Combining mark grapheme Cafe\\x{0301} has width 4");
is(Shop::TUI::Screen::display_width($zwj_fam),   2, "ZWJ family emoji grapheme has width 2");
is(Shop::TUI::Screen::display_width($us_flag),   2, "Regional indicator flag has width 2");
is(Shop::TUI::Screen::display_width($thumbs),    2, "Skin-tone modifier emoji has width 2");
is(Shop::TUI::Screen::clip_to_width($combining . "!", 4), $combining, "clip_to_width preserves combining mark intact");
is(Shop::TUI::Screen::clip_to_width($zwj_fam . "X", 2),   $zwj_fam,   "clip_to_width never splits ZWJ emoji");

my $s_gr = Shop::TUI::Screen->new(cols => 24, rows => 4);
$s_gr->write_str(0, 0, "ASCII ONLY");
ok(!defined($s_gr->{_g_by_id}), "ASCII-only screen allocates 0 grapheme side-table memory");
$s_gr->write_str(0, 1, "$combining $zwj_fam $us_flag");
my $gr_out = $s_gr->render();
my $expected_zwj_utf8 = $zwj_fam; utf8::encode($expected_zwj_utf8);
my $expected_comb_utf8 = $combining; utf8::encode($expected_comb_utf8);
ok(index($gr_out, $expected_comb_utf8) >= 0, "Rendered ANSI contains intact decomposed combining grapheme");
ok(index($gr_out, $expected_zwj_utf8) >= 0,  "Rendered ANSI contains intact ZWJ family emoji");
is(MT::Array::is_packed($s_gr->{curr_ch}), 'IV', "Grapheme screen still uses packed IV MT::Array");

# --- 4. Input parser tests (arrows, vim, partial CSI, ctrl keys, SGR mouse) ---
my $inp = Shop::TUI::Input->new();
my @evs = $inp->parse("\e[A\e[B\e[C\e[D\r\n\t\x7f\x03\x0cj");
is_deeply(
    [ map { $_->{type} } @evs ],
    [qw(UP DOWN RIGHT LEFT ENTER TAB BACKSPACE CTRL_C CTRL_L CHAR)],
    "parsed standard ANSI keys, ctrl keys, and CHAR"
);
is($evs[-1]{char}, 'j', "CHAR preserves 'j'");
is($evs[-1]{vim}, 'DOWN', "vim navigation hint for 'j' is DOWN");
is(Shop::TUI::Input::nav($evs[-1]), 'DOWN', "Input::nav maps 'j' to DOWN");

# Split CSI sequence across two reads
my @part1 = $inp->parse("\e[");
is(scalar(@part1), 0, "incomplete CSI buffered across reads");
my @part2 = $inp->parse("A");
is(scalar(@part2), 1, "completed CSI emits event");
is($part2[0]{type}, 'UP', "split \\e[ + A resolves to UP");

# SGR Mouse parsing: left press/release, right press, wheel up/down, split sequence
my @mevs = $inp->parse("\e[<0;15;4M\e[<0;15;4m\e[<2;1;1M\e[<64;20;10M\e[<65;20;10M");
is(scalar(@mevs), 5, "parsed 5 SGR mouse events");
is_deeply($mevs[0], { type => 'MOUSE', button => 'left',       x => 14, y => 3, press => 1 }, "SGR left press");
is_deeply($mevs[1], { type => 'MOUSE', button => 'left',       x => 14, y => 3, press => 0 }, "SGR left release");
is_deeply($mevs[2], { type => 'MOUSE', button => 'right',      x => 0,  y => 0, press => 1 }, "SGR right press");
is_deeply($mevs[3], { type => 'MOUSE', button => 'wheel_up',   x => 19, y => 9, press => 1 }, "SGR wheel_up");
is_deeply($mevs[4], { type => 'MOUSE', button => 'wheel_down', x => 19, y => 9, press => 1 }, "SGR wheel_down");

my @mp1 = $inp->parse("\e[<0;12;");
is(scalar(@mp1), 0, "incomplete SGR mouse sequence buffered");
my @mp2 = $inp->parse("8M");
is_deeply($mp2[0], { type => 'MOUSE', button => 'left', x => 11, y => 7, press => 1 }, "split SGR mouse sequence completed");

# --- 5. Admin [T] Db2 Time-Travel & OLAP sub-tab (keys, SGR mouse, Db2 & SQLite banners) ---
{
    package MockDb2AdminDB;
    sub new { my ($c, %a) = @_; bless \%a, $c }
    sub driver { $_[0]->{driver} // 'db2' }
    sub get_user { undef }
    sub upsert_user { $_[1] }
    sub list_orders {
        return [
            { id => 'ORD-1001', user_fp => 'SHA256:admin', status => 'SHIPPED', total => '149.98' },
            { id => 'ORD-1002', user_fp => 'SHA256:bob',   status => 'PAID',    total => '59.99'  },
        ];
    }
    sub gmv_summary { { order_count => 2, total_gmv => '209.97' } }
    sub db2_features {
        my ($self) = @_;
        return $self->{features} if $self->{features};
        return {
            engine      => 'IBM Db2 Community Edition',
            driver      => 'db2',
            decfloat34  => 1,
            temporal    => 1,
            final_table => 1,
            merge       => 1,
            compression => 'ADAPTIVE',
            olap_rollup => 1,
            sp_only     => 1,
        };
    }
    sub product_history {
        my ($self, $sku, $limit) = @_;
        return [
            { sku => $sku, name => "Item $sku", price => '99.99', stock => 7,  sys_start => '2026-11-21 01:50:00.000000', sys_end => '9999-12-30 00:00:00.000000' },
            { sku => $sku, name => "Item $sku", price => '89.99', stock => 10, sys_start => '2026-11-20 12:00:00.000000', sys_end => '2026-11-21 01:50:00.000000' },
        ];
    }
    sub order_history {
        my ($self, $oid) = @_;
        return [
            { id => $oid, status => 'SHIPPED', total => '149.98', payment_ref => 'pi_1', sys_start => '2026-11-21 01:45:00.000000', sys_end => '9999-12-30 00:00:00.000000' },
            { id => $oid, status => 'PAID',    total => '149.98', payment_ref => 'pi_1', sys_start => '2026-11-21 01:40:00.000000', sys_end => '2026-11-21 01:45:00.000000' },
        ];
    }
    sub category_olap {
        return [
            { category => 'Hardware',       order_count => 1, units_sold => 2, revenue => '149.98', share_pct => '71.43',  rank => 1 },
            { category => 'Apparel',        order_count => 1, units_sold => 1, revenue => '59.99',  share_pct => '28.57',  rank => 2 },
            { category => 'ALL CATEGORIES', order_count => 2, units_sold => 3, revenue => '209.97', share_pct => '100.00', rank => 0 },
        ];
    }

    package MockAdminInv;
    sub new { bless {}, shift }
    sub list_catalog {
        return [
            { sku => 'SKU-001', name => 'MT5 Server',  category => 'Hardware', price => '99.99', stock => 7 },
            { sku => 'SKU-002', name => 'Perl Hoodie', category => 'Apparel',  price => '59.99', stock => 15 },
        ];
    }
    sub get_stock { 7 }
}

my $mock_db  = MockDb2AdminDB->new();
my $mock_inv = MockAdminInv->new();
my $admin_app = Shop::TUI::App->new(
    cols      => 110,
    rows      => 28,
    db        => $mock_db,
    inventory => $mock_inv,
    config    => { admin_fingerprints => ['*'] },
    user      => { username => 'admin', fingerprint => 'SHA256:admin', is_admin => 1 },
);

$admin_app->switch_view('admin');
$admin_app->render_frame();
my $aview = $admin_app->{views}{admin};
is($aview->{tab}, 0, "Admin starts on Dashboard sub-tab");

# Press 't' to jump directly to [T] Db2 Time-Travel & OLAP
$admin_app->handle_key({ type => 'CHAR', char => 't' });
is($aview->{tab}, 3, "Key 't' switches Admin to [T] Db2 Time-Travel & OLAP sub-tab");
my $db2_frame = $admin_app->render_frame();
my $plain_db2 = $db2_frame;
$plain_db2 =~ s/\e\[[0-9;?]*[A-Za-z]//g;
like($plain_db2, qr/IBM Db2 CE/,               "Db2 banner shows IBM Db2 CE");
like($plain_db2, qr/DECFLOAT\(34\)/,           "Db2 banner shows DECFLOAT(34)");
like($plain_db2, qr/SYSTEM_TIME/,              "Db2 banner shows SYSTEM_TIME Temporal");
like($plain_db2, qr/FINAL TABLE/,              "Db2 banner shows FINAL TABLE");
like($plain_db2, qr/ROLLUP OLAP/,              "Db2 banner shows ROLLUP OLAP");
like($plain_db2, qr/SP-ONLY \(SQLi Blocked\)/, "Db2 banner shows SP-ONLY (SQLi Blocked)");
like($plain_db2, qr/SKU: SKU-001/,             "Temporal pane shows selected SKU-001");
like($plain_db2, qr/CURRENT/,                  "Temporal pane formats 9999-... sys_end as CURRENT");
like($plain_db2, qr/Order Lifecycle: #ORD-1001/, "Temporal pane shows order lifecycle history");
like($plain_db2, qr/Hardware/,                 "OLAP pane shows Hardware category");
like($plain_db2, qr/ALL CATEGORIES/,           "OLAP pane shows ROLLUP grand-total row");
like($plain_db2, qr/\$209\.97/,                "OLAP pane shows exact MT::Decimal grand total");

# Cycle SKU with 'n' and Order with 'o'
$admin_app->handle_key({ type => 'CHAR', char => 'n' });
is($aview->{db2_sku_sel}, 1, "Key 'n' advances selected SKU in Db2 temporal pane");
$admin_app->handle_key({ type => 'CHAR', char => 'o' });
is($aview->{db2_ord_sel}, 1, "Key 'o' advances selected Order in Db2 temporal pane");
$admin_app->{screen}->invalidate();
my $db2_frame2 = $admin_app->render_frame();
$db2_frame2 =~ s/\e\[[0-9;?]*[A-Za-z]//g;
like($db2_frame2, qr/SKU-002/,  "Cycled SKU-002 rendered");
like($db2_frame2, qr/ORD-1002/, "Cycled ORD-1002 rendered");

# SGR Mouse click on Dashboard tab then back on [T] Db2 tab
my ($dash_hb) = grep { $_->{idx} == 0 } @{ $aview->{_tab_hitboxes} };
my ($db2_hb)  = grep { $_->{idx} == 3 } @{ $aview->{_tab_hitboxes} };
ok($dash_hb && $db2_hb, "Admin sub-tab SGR mouse hitboxes populated");
$admin_app->handle_key({ type => 'MOUSE', button => 'left', press => 1, x => $dash_hb->{x0} + 1, y => $dash_hb->{y} });
is($aview->{tab}, 0, "SGR mouse click switches back to Dashboard");
$admin_app->handle_key({ type => 'MOUSE', button => 'left', press => 1, x => $db2_hb->{x0} + 1, y => $db2_hb->{y} });
is($aview->{tab}, 3, "SGR mouse click switches to [T] Db2 Time-Travel & OLAP");

# Verify SQLite dev-mode banner fallback
my $sqlite_mock = MockDb2AdminDB->new(
    driver   => 'sqlite',
    features => { engine => 'SQLite 3', driver => 'sqlite', decfloat34 => 0, temporal => 0, final_table => 0, merge => 0, olap_rollup => 0, sp_only => 0 },
);
my $sqlite_app = Shop::TUI::App->new(
    cols      => 110,
    rows      => 28,
    db        => $sqlite_mock,
    inventory => $mock_inv,
    config    => { admin_fingerprints => ['*'] },
    user      => { username => 'admin', fingerprint => 'SHA256:admin', is_admin => 1 },
);
$sqlite_app->switch_view('admin');
$sqlite_app->handle_key({ type => 'CHAR', char => 'T' });
my $sq_frame = $sqlite_app->render_frame();
$sq_frame =~ s/\e\[[0-9;?]*[A-Za-z]//g;
like($sq_frame, qr/SQLite \(dev mode\)/, "SQLite mode renders SQLite (dev mode) banner");

# --- 6. Admin [L] Logistics & Nexus sub-tab, Checkout Shippo/Nexus, Orders & live shipment_updated ---
{
    package MockLogisticsDB;
    sub new {
        my ($c) = @_;
        return bless {
            pos => [
                { id => 'PO-2026-001', supplier => 'ApexSilicon', warehouse_code => 'DAL1', status => 'OPEN',    total_cost => '1200.00' },
                { id => 'PO-2026-002', supplier => 'NordicKey',   warehouse_code => 'NYC1', status => 'PARTIAL', total_cost => '800.00'  },
            ],
            po_lines => {
                'PO-2026-001' => [ { id => 'POL-1', po_id => 'PO-2026-001', sku => 'SKU-001', qty_ordered => 50, qty_received => 0,  unit_cost => '24.00' } ],
                'PO-2026-002' => [ { id => 'POL-2', po_id => 'PO-2026-002', sku => 'SKU-002', qty_ordered => 20, qty_received => 10, unit_cost => '40.00' } ],
            },
            shipments => [
                { id => 'SHP-1', order_id => 'ORD-1001', warehouse_code => 'DAL1', carrier => 'USPS', service => 'Ground Advantage', rate_amount => '7.95', tracking_number => '', label_url => '', status => 'PENDING' },
            ],
            orders => [
                { id => 'ORD-1001', user_fp => 'SHA256:admin', status => 'PAID', total => '107.94', tax => '8.25', shipping => '7.95', payment_method => 'mock', payment_ref => 'pay_1', items => [ { sku => 'SKU-001', name => 'MT5 Server', qty => 1, line_total => '99.99' } ] },
            ],
            addresses => [
                { id => 1, label => 'Dallas',  recipient => 'Alice', line1 => '100 Main St', city => 'Dallas',  state => 'TX', postal_code => '75201', country => 'US' },
                { id => 2, label => 'Seattle', recipient => 'Bob',   line1 => '200 Pine St', city => 'Seattle', state => 'WA', postal_code => '98101', country => 'US' },
            ],
            nexus => [
                { state => 'TX', rate => '0.0825', threshold_sales => '500000.00', threshold_txns => 0,   registered => 1, ytd_sales => '12500.00',  ytd_txns => 40  },
                { state => 'WA', rate => '0.0650', threshold_sales => '100000.00', threshold_txns => 0,   registered => 0, ytd_sales => '105000.00', ytd_txns => 120 },
                { state => 'FL', rate => '0.0600', threshold_sales => '100000.00', threshold_txns => 0,   registered => 0, ytd_sales => '85000.00',  ytd_txns => 90  },
                { state => 'IL', rate => '0.0625', threshold_sales => '100000.00', threshold_txns => 200, registered => 0, ytd_sales => '10000.00',  ytd_txns => 12  },
            ],
        }, $c;
    }
    sub driver { 'sqlite' }
    sub get_user { undef }
    sub upsert_user { $_[1] }
    sub gmv_summary { { order_count => 1, total_gmv => '107.94' } }
    sub list_warehouses {
        return [
            { code => 'DAL1', name => 'Dallas Hub',  city => 'Dallas',  state => 'TX', postal_code => '75201', active => 1 },
            { code => 'NYC1', name => 'Newark Hub',  city => 'Newark',  state => 'NJ', postal_code => '07102', active => 1 },
            { code => 'SFO1', name => 'Oakland Hub', city => 'Oakland', state => 'CA', postal_code => '94607', active => 1 },
        ];
    }
    sub list_pos { $_[0]->{pos} }
    sub get_po_lines { $_[0]->{po_lines}{$_[1]} || [] }
    sub list_shipments { $_[0]->{shipments} }
    sub get_shipment_by_order {
        my ($self, $oid) = @_;
        my ($sh) = grep { $_->{order_id} eq $oid } @{ $self->{shipments} };
        return $sh;
    }
    sub update_shipment {
        my ($self, $id, %f) = @_;
        my ($sh) = grep { $_->{id} eq $id } @{ $self->{shipments} };
        return undef unless $sh;
        for my $k (qw(status tracking_number label_url)) {
            $sh->{$k} = $f{$k} if defined $f{$k};
        }
        return $sh;
    }
    sub list_orders { $_[0]->{orders} }
    sub get_order {
        my ($self, $oid) = @_;
        my ($o) = grep { $_->{id} eq $oid } @{ $self->{orders} };
        return $o;
    }
    sub list_addresses { $_[0]->{addresses} }
    sub get_tax_nexus {
        my ($self, $st) = @_;
        my ($r) = grep { uc($_->{state}) eq uc($st // '') } @{ $self->{nexus} };
        return $r;
    }
    sub tax_nexus_report { $_[0]->{nexus} }

    package MockLogisticsCheckout;
    sub new { my ($c, %a) = @_; bless \%a, $c }
    sub receive_po_line {
        my ($self, %a) = @_;
        push @{ $self->{calls} }, \%a;
        for my $po_id (keys %{ $self->{db}{po_lines} }) {
            for my $ln (@{ $self->{db}{po_lines}{$po_id} }) {
                if ($ln->{id} eq $a{po_line_id}) {
                    $ln->{qty_received} += $a{qty};
                    return {
                        ok           => 1,
                        po_id        => $po_id,
                        po_line_id   => $ln->{id},
                        sku          => $ln->{sku},
                        qty_received => $ln->{qty_received},
                        new_stock    => 17,
                        po_status    => 'PARTIAL',
                    };
                }
            }
        }
        return { ok => 0, error => 'not found' };
    }

    package MockCart;
    sub new { bless {}, shift }
    sub item_count { 1 }
    sub items { [ { sku => 'SKU-001', name => 'MT5 Server', qty => 1, unit_price => '100.00' } ] }
    sub totals { { subtotal => '100.00', discount => '0.00', shipping => '7.95', tax => '8.25', total => '116.20' } }
}

use Shop::Shipping::Shippo;
use Shop::Tax::Nexus;

my $log_db  = MockLogisticsDB->new();
my $log_co  = MockLogisticsCheckout->new(db => $log_db, calls => []);
my $shippo  = Shop::Shipping::Shippo->new();
my $nexus   = Shop::Tax::Nexus->new(db => $log_db);
my $log_app = Shop::TUI::App->new(
    cols      => 118,
    rows      => 28,
    db        => $log_db,
    inventory => $mock_inv,
    cart      => MockCart->new(),
    checkout  => $log_co,
    shippo    => $shippo,
    tax_nexus => $nexus,
    config    => { admin_fingerprints => ['*'] },
    user      => { username => 'admin', fingerprint => 'SHA256:admin', is_admin => 1 },
);

sub _screen_text {
    my ($scr) = @_;
    my $cols = $scr->cols();
    my $rows = $scr->rows();
    my $buf  = $scr->{curr_ch};
    my @lines;
    for my $r (0 .. $rows - 1) {
        my $s = '';
        for my $c (0 .. $cols - 1) {
            my $cp = $buf->[$r * $cols + $c] // 32;
            $s .= ($cp > 0 && $cp < 0x110000) ? chr($cp) : ' ';
        }
        push @lines, $s;
    }
    return join("\n", @lines);
}

# Admin [L] Logistics & Nexus rendering & interactions
$log_app->switch_view('admin');
$log_app->render_frame();
$log_app->handle_key({ type => 'CHAR', char => 'l' });
my $laview = $log_app->{views}{admin};
is($laview->{tab}, 4, "Key 'l' switches Admin to [L] Logistics & Nexus sub-tab");

$log_app->render_frame();
my $plain_log = _screen_text($log_app->{screen});
like($plain_log, qr/Inbound PO Queue/,   "Logistics tab renders Inbound PO Queue");
like($plain_log, qr/ApexSilicon/,        "PO Queue lists supplier ApexSilicon");
like($plain_log, qr/DAL1/,               "PO Queue & Shipments show DAL1 warehouse");
like($plain_log, qr/0\/50/,              "PO Queue shows qty_received/qty_ordered (0/50)");
like($plain_log, qr/Outbound Shipments/, "Logistics tab renders Outbound Shipments");
like($plain_log, qr/ORD-1001/,           "Outbound Shipments shows ORD-1001");
like($plain_log, qr/Tax Nexus Monitor/,  "Logistics tab renders Tax Nexus Monitor");
like($plain_log, qr/\[REGISTERED\]/,     "Nexus monitor shows REGISTERED badge");
like($plain_log, qr/\[NEXUS_REQUIRED\]/, "Nexus monitor shows NEXUS_REQUIRED badge");
like($plain_log, qr/\[APPROACHING\]/,    "Nexus monitor shows APPROACHING badge");
like($plain_log, qr/\[OK\]/,             "Nexus monitor shows OK badge");

# SGR mouse click on [L] tab
my ($log_hb) = grep { $_->{idx} == 4 } @{ $laview->{_tab_hitboxes} };
ok($log_hb, "Admin [L] Logistics & Nexus SGR mouse hitbox populated");
$log_app->handle_key({ type => 'CHAR', char => 't' });
is($laview->{tab}, 3, "Switched to Db2 tab before mouse click test");
$log_app->handle_key({ type => 'MOUSE', button => 'left', press => 1, x => $log_hb->{x0} + 1, y => $log_hb->{y} });
is($laview->{tab}, 4, "SGR mouse click switches back to [L] Logistics & Nexus");

# Press [r] to receive 10 units via Checkout::receive_po_line
$log_app->handle_key({ type => 'CHAR', char => 'r' });
is(scalar(@{ $log_co->{calls} }), 1, "Key 'r' invokes Checkout::receive_po_line");
is($log_co->{calls}[0]{po_line_id}, 'POL-1', "receive_po_line called for selected PO line POL-1");
is($log_co->{calls}[0]{qty}, 10, "receive_po_line called with qty=10");
like($log_app->{toast_msg}, qr/\[RESTOCKED\]/, "PO receive shows [RESTOCKED] toast");

# Scan SKU via [/] + SKU-002 + Enter
$log_app->handle_key({ type => 'CHAR', char => '/' });
for my $c (split //, 'SKU-002') {
    $log_app->handle_key({ type => 'CHAR', char => $c });
}
$log_app->handle_key({ type => 'ENTER' });
is(scalar(@{ $log_co->{calls} }), 2, "SKU scan + Enter invokes Checkout::receive_po_line");
is($log_co->{calls}[1]{po_line_id}, 'POL-2', "SKU scan matched PO line POL-2 for SKU-002");

# Press [p] twice: PENDING -> PICKED -> PACKED, then [b] to buy Shippo label -> LABEL_CREATED
$log_app->handle_key({ type => 'CHAR', char => 'p' });
is($log_db->{shipments}[0]{status}, 'PICKED', "Key 'p' advances shipment PENDING -> PICKED");
$log_app->handle_key({ type => 'CHAR', char => 'p' });
is($log_db->{shipments}[0]{status}, 'PACKED', "Key 'p' advances shipment PICKED -> PACKED");
$log_app->handle_key({ type => 'CHAR', char => 'b' });
is($log_db->{shipments}[0]{status}, 'LABEL_CREATED', "Key 'b' buys Shippo label -> LABEL_CREATED");
ok(length($log_db->{shipments}[0]{tracking_number} // '') > 5, "Shippo label populated tracking_number");

# Checkout: Shippo live rate selector & Tax Nexus display (TX Nexus vs WA No Nexus)
$log_app->switch_view('checkout');
$log_app->handle_key({ type => 'ENTER' }); # address -> payment (TX address)
$log_app->render_frame();
my $co_tx = _screen_text($log_app->{screen});
like($co_tx, qr/USPS Ground Advantage/,      "Checkout payment shows USPS Ground Advantage live rate");
like($co_tx, qr/Tax \(TX 8\.25% - Nexus\)/,  "Checkout payment shows TX 8.25% Nexus tax line");

# Cycle Shippo rate with [s] -> UPS Ground
$log_app->handle_key({ type => 'CHAR', char => 's' });
$log_app->render_frame();
my $co_ups = _screen_text($log_app->{screen});
like($co_ups, qr/UPS Ground/, "Key 's' cycles live Shippo rate to UPS Ground");

# Switch back to address, pick WA (unregistered) -> No Nexus
$log_app->handle_key({ type => 'ESC' });
$log_app->handle_key({ type => 'DOWN' });
$log_app->handle_key({ type => 'ENTER' });
$log_app->render_frame();
my $co_wa = _screen_text($log_app->{screen});
like($co_wa, qr/Tax \(\$0\.00 - No Nexus\)/, "Checkout payment shows \$0.00 No Nexus tax line for WA");

# Orders view + live shipment_updated EventBus push
$log_app->switch_view('orders');
$log_db->{shipments}[0]{status} = 'IN_TRANSIT';
$log_app->handle_event({
    type            => 'shipment_updated',
    order_id        => 'ORD-1001',
    tracking_number => $log_db->{shipments}[0]{tracking_number},
    status          => 'IN_TRANSIT',
});
like($log_app->{toast_msg},  qr/Shipment #ORD-1001 is now IN_TRANSIT!/, "shipment_updated push sets live toast");
like($log_app->{ticker_msg}, qr/IN_TRANSIT/,                             "shipment_updated push updates live ticker");
$log_app->render_frame();
my $ord_frame = _screen_text($log_app->{screen});
like($ord_frame, qr/\[DAL1\]/,     "Orders detail displays shipment warehouse DAL1");
like($ord_frame, qr/IN_TRANSIT/,   "Orders detail displays live shipment status IN_TRANSIT");
like($ord_frame, qr/Track #:/,     "Orders detail displays shipment tracking number");

done_testing();
