package Shop::TUI::View::Account;

use strict;
use warnings;
use Shop::TUI::Input ();

sub new {
    my ($class, %args) = @_;
    return bless {
        edit_mode => 0,     # 0=view, 1=edit profile
        field_idx => 0,     # 0=username, 1=email
        username  => '',
        email     => '',
        addresses => [],
        addr_idx  => 0,
    }, $class;
}

sub on_enter {
    my ($self, $app) = @_;
    $self->{edit_mode} = 0;
    $self->refresh($app);
}

sub refresh {
    my ($self, $app) = @_;
    my $u = $app->{user} || {};
    $self->{username} = $u->{username} // '';
    $self->{email}    = $u->{email}    // '';
    if ($app->{db}) {
        my $addrs = eval { $app->{db}->list_addresses($app->user_fp()) };
        $self->{addresses} = ref($addrs) eq 'ARRAY' ? $addrs : [];
        $self->{addr_idx}  = 0 if $self->{addr_idx} >= scalar(@{ $self->{addresses} });
    }
}

sub is_capturing_text {
    return $_[0]->{edit_mode} ? 1 : 0;
}

sub help_text {
    my ($self) = @_;
    if ($self->{edit_mode}) {
        return "EDIT PROFILE: [Tab] Switch Field | [Enter] Save | [Esc] Cancel";
    }
    return "[e] Edit Profile | [Up/Down] Select Address | [d] Delete Address | [1] Shop";
}

sub handle_key {
    my ($self, $app, $ev) = @_;
    my $type = $ev->{type} // '';
    my $ch   = $ev->{char} // '';
    my $nav  = Shop::TUI::Input::nav($ev);

    if ($self->{edit_mode}) {
        if ($type eq 'ESC') {
            $self->{edit_mode} = 0;
            $self->refresh($app);
            return 1;
        }
        if ($type eq 'TAB' || $type eq 'UP' || $type eq 'DOWN') {
            $self->{field_idx} = $self->{field_idx} ? 0 : 1;
            return 1;
        }
        if ($type eq 'BACKSPACE') {
            my $k = $self->{field_idx} ? 'email' : 'username';
            chop($self->{$k}) if length($self->{$k});
            return 1;
        }
        if ($type eq 'CHAR') {
            my $k = $self->{field_idx} ? 'email' : 'username';
            $self->{$k} .= $ch if length($self->{$k}) < 48;
            return 1;
        }
        if ($type eq 'ENTER') {
            $self->{edit_mode} = 0;
            $app->{user}{username} = $self->{username} if length($self->{username});
            $app->{user}{email}    = $self->{email};
            if ($app->{db}) {
                eval {
                    $app->{db}->upsert_user({
                        fingerprint => $app->user_fp(),
                        username    => $app->{user}{username},
                        email       => $app->{user}{email},
                        pubkey_type => $app->{user}{pubkey_type} // 'none',
                        is_admin    => $app->is_admin() ? 1 : 0,
                    });
                };
            }
            $app->set_toast("Profile saved.", 'ok');
            return 1;
        }
        return 0;
    }

    my $n = scalar(@{ $self->{addresses} });
    if ($nav eq 'DOWN' && $n > 0 && $self->{addr_idx} < $n - 1) { $self->{addr_idx}++; return 1; }
    if ($nav eq 'UP'   && $n > 0 && $self->{addr_idx} > 0)      { $self->{addr_idx}--; return 1; }
    if ($type eq 'CHAR' && lc($ch) eq 'e') {
        $self->{edit_mode} = 1;
        $self->{field_idx} = 0;
        return 1;
    }
    if ($type eq 'CHAR' && lc($ch) eq 'd' && $n > 0) {
        my $a = $self->{addresses}[$self->{addr_idx}];
        if ($app->{db} && defined $a->{id}) {
            eval { $app->{db}->delete_address($a->{id}, $app->user_fp()) };
            $self->refresh($app);
            $app->set_toast("Address deleted.", 'ok');
        }
        return 1;
    }
    return 0;
}

sub draw {
    my ($self, $app, $scr, $x, $y, $w, $h) = @_;
    my $pal = $app->{palette};
    my $u   = $app->{user} || {};

    $scr->box($x, $y, $w, $h, $pal->{border}, "Account & SSH Identity", $pal->{title});
    my $iw = $w - 4;
    my $py = $y + 2;

    $scr->write_str($x + 2, $py++, "SSH Fingerprint : " . ($u->{fingerprint} // 'guest'), $pal->{title}, $iw);
    $scr->write_str($x + 2, $py++, "Key Type        : " . ($u->{pubkey_type} // 'none') . ($app->is_admin() ? "  [ADMIN]" : ""), $pal->{dim}, $iw);
    $py++;

    if ($self->{edit_mode}) {
        $scr->write_str($x + 2, $py, "Username        : ", $pal->{dim}, 18);
        $scr->write_str($x + 20, $py++, $self->{username} . ($self->{field_idx} == 0 ? "_" : ""), $self->{field_idx} == 0 ? $pal->{input} : $pal->{normal}, $iw - 18);
        $scr->write_str($x + 2, $py, "Email           : ", $pal->{dim}, 18);
        $scr->write_str($x + 20, $py++, $self->{email} . ($self->{field_idx} == 1 ? "_" : ""), $self->{field_idx} == 1 ? $pal->{input} : $pal->{normal}, $iw - 18);
    } else {
        $scr->write_str($x + 2, $py++, "Username        : " . ($u->{username} // 'guest'), $pal->{normal}, $iw);
        $scr->write_str($x + 2, $py++, "Email           : " . ($u->{email}    // '(not set)'), $pal->{normal}, $iw);
    }
    $py++;

    $scr->hline($x + 2, $py++, $iw, '-', $pal->{border});
    $scr->write_str($x + 2, $py++, "Saved Shipping Addresses (" . scalar(@{ $self->{addresses} }) . "):", $pal->{title}, $iw);
    if (!@{ $self->{addresses} }) {
        $scr->write_str($x + 2, $py++, "No saved addresses. Add one during Checkout.", $pal->{dim}, $iw);
    } else {
        for (my $i = 0; $i < @{ $self->{addresses} } && $py < $y + $h - 2; $i++) {
            my $a = $self->{addresses}[$i];
            my $lbl = sprintf("[%s] %s - %s, %s %s", $a->{label} // 'Addr', $a->{recipient} // '', $a->{line1} // '', $a->{city} // '', $a->{state} // '');
            $scr->write_str($x + 2, $py++, $lbl, ($i == $self->{addr_idx}) ? $pal->{sel} : $pal->{normal}, $iw);
        }
    }
}

1;
