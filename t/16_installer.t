#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use File::Spec;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $root      = abs_path(File::Spec->catdir(dirname(__FILE__), '..'));
my $installer = File::Spec->catfile($root, 'install.pl');
my $config    = File::Spec->catfile($root, 'config', 'shop.json');
my $launcher  = File::Spec->catfile($root, 'bin', 'start-shop');

my $stock_perl = -x '/usr/bin/perl' ? '/usr/bin/perl' : $^X;

sub run_capture {
    my ($env_ref, @cmd) = @_;
    my $pid = open(my $fh, '-|');
    die "fork failed: $!" if !defined $pid;
    if ($pid == 0) {
        for my $k (keys %$env_ref) {
            if (defined $env_ref->{$k}) {
                $ENV{$k} = $env_ref->{$k};
            } else {
                delete $ENV{$k};
            }
        }
        open(STDERR, '>&', \*STDOUT);
        exec(@cmd);
        exit 127;
    }
    local $/;
    my $out = <$fh>;
    $out = '' if !defined $out;
    close($fh);
    my $rc = $? >> 8;
    return ($rc, $out);
}

# Snapshot state before dry-run tests to assert zero mutations
ok(-f $installer, 'install.pl exists');
ok(-x $installer, 'install.pl is executable');

my $config_before = do {
    open(my $fh, '<:raw', $config) or die "Cannot read $config: $!";
    local $/;
    <$fh>;
};
my $config_mtime_before  = (stat($config))[9];
my $launcher_existed     = -e $launcher ? 1 : 0;
my $fresh_prefix         = File::Spec->catdir(File::Spec->tmpdir(), "perl5-mt-shop-dryrun-$$-" . time());
ok(!-e $fresh_prefix, 'temp dry-run prefix does not exist before test');

# 1. Stock system Perl syntax check
{
    my ($rc, $out) = run_capture({}, $stock_perl, '-c', $installer);
    is($rc, 0, "stock Perl ($stock_perl) -c install.pl exits 0");
    like($out, qr/syntax OK/, 'stock Perl reports syntax OK');
}

# 2. --help check
{
    my ($rc, $out) = run_capture({}, $stock_perl, $installer, '--help');
    is($rc, 0, '--help exits 0');
    like($out, qr/--prefix/,           '--help documents --prefix');
    like($out, qr/--db/,               '--help documents --db');
    like($out, qr/--pgo/,              '--help documents --pgo');
    like($out, qr/--deps-from-source/, '--help documents --deps-from-source');
    like($out, qr/--dry-run/,          '--help documents --dry-run');
}

# 3. --dry-run --yes --db sqlite (host detection + fresh clone URLs)
{
    my ($rc, $out) = run_capture(
        {
            PERL5_MT_ROOT       => undef,
            MOJOLICIOUS_MT_ROOT => undef,
        },
        $stock_perl, $installer,
        '--dry-run', '--yes',
        '--prefix', $fresh_prefix,
        '--db', 'sqlite',
    );
    is($rc, 0, '--dry-run --yes --db sqlite exits 0');
    like($out, qr/OS \/ Arch\s*:\s*(?:darwin|linux|aix)\s*\/\s*(?:arm64|x86_64|ppc64le|s390x|\S+)/, 'detects OS and arch');
    like($out, qr/CPU cores\s*:\s*\d+\s*\(build jobs:\s*\d+\)/, 'detects CPU cores and build jobs');
    like($out, qr/C compiler\s*:\s*\S+/, 'detects C compiler');
    like($out, qr{https://github\.com/stratum42/perl5-mt\.git},       'includes perl5-mt GitHub clone URL');
    like($out, qr{https://github\.com/stratum42/mojolicious-mt\.git}, 'includes mojolicious-mt GitHub clone URL');
    like($out, qr{https://github\.com/stratum42/perl5-mt-shop\.git},  'includes perl5-mt-shop GitHub clone URL');
    like($out, qr/Docker services\s*:\s*none \(local SQLite mode\)/,  'no Docker services for sqlite');
    unlike($out, qr/SHOP_TEST_DOCKER=1/, 'sqlite test plan does not set SHOP_TEST_DOCKER=1');
}

# 4. macOS vs Linux Configure flags (--db db2 --pgo)
{
    my ($rc_mac, $out_mac) = run_capture(
        {
            SHOP_INSTALL_OS     => 'darwin',
            PERL5_MT_ROOT       => undef,
            MOJOLICIOUS_MT_ROOT => undef,
        },
        $stock_perl, $installer,
        '--dry-run', '--yes',
        '--prefix', $fresh_prefix,
        '--db', 'db2', '--pgo',
    );
    is($rc_mac, 0, 'darwin --db db2 --pgo --dry-run exits 0');
    like($out_mac, qr{\./Configure -des -Dusethreads -Dprefix=\S+/localperl -Dusepgo -Dusenative}, 'macOS Configure uses -Dusepgo -Dusenative');
    unlike($out_mac, qr/-Ud_thread_local/, 'macOS Configure omits -Ud_thread_local');
    like($out_mac, qr/make -j\d+ pgo/, 'PGO build uses make -jN pgo');
    like($out_mac, qr/Docker services\s*:\s*db2 db2-gateway keydb/, 'db2 selects db2 + db2-gateway + keydb');
    like($out_mac, qr/init-db2\.sh/, 'db2 runs init-db2.sh');
    like($out_mac, qr/SHOP_TEST_DOCKER=1/, 'db2 validation sets SHOP_TEST_DOCKER=1');

    my ($rc_lin, $out_lin) = run_capture(
        {
            SHOP_INSTALL_OS            => 'linux',
            SHOP_INSTALL_PGO_AVAILABLE => 1,
            PERL5_MT_ROOT              => undef,
            MOJOLICIOUS_MT_ROOT        => undef,
        },
        $stock_perl, $installer,
        '--dry-run', '--yes',
        '--prefix', $fresh_prefix,
        '--db', 'db2', '--pgo',
    );
    is($rc_lin, 0, 'linux --db db2 --pgo --dry-run exits 0');
    like($out_lin, qr/-Ud_thread_local/,        'Linux Configure includes -Ud_thread_local');
    like($out_lin, qr/-Accflags=-std=gnu17/,    'Linux Configure includes -Accflags=-std=gnu17');
    like($out_lin, qr/-Dusepgo/,                'Linux Configure includes -Dusepgo');
    like($out_lin, qr/-Dusenative/,             'Linux Configure includes -Dusenative');

    # PGO fallback to -O2 -g when PGO tooling is missing
    my ($rc_fb, $out_fb) = run_capture(
        {
            SHOP_INSTALL_OS            => 'linux',
            SHOP_INSTALL_PGO_AVAILABLE => 0,
            PERL5_MT_ROOT              => undef,
            MOJOLICIOUS_MT_ROOT        => undef,
        },
        $stock_perl, $installer,
        '--dry-run', '--yes',
        '--prefix', $fresh_prefix,
        '--db', 'sqlite', '--pgo',
    );
    is($rc_fb, 0, 'missing PGO tooling fallback exits 0');
    like($out_fb, qr/falling back to -O2 -g/, 'prints PGO fallback notice');
    like($out_fb, qr/-Doptimize=-O2 -g/,      'uses -O2 -g when PGO tooling missing');
    unlike($out_fb, qr/-Dusepgo/,             'omits -Dusepgo when PGO tooling missing');
}

# 5. --db informix --no-pgo
{
    my ($rc, $out) = run_capture(
        {
            PERL5_MT_ROOT       => undef,
            MOJOLICIOUS_MT_ROOT => undef,
        },
        $stock_perl, $installer,
        '--dry-run', '--yes',
        '--prefix', $fresh_prefix,
        '--db', 'informix', '--no-pgo',
    );
    is($rc, 0, '--db informix --no-pgo --dry-run exits 0');
    like($out, qr/PGO enabled\s*:\s*no \(-O2 -g\)/, 'no-pgo disables PGO');
    unlike($out, qr/-Dusepgo/, 'no-pgo omits -Dusepgo');
    unlike($out, qr/make -j\d+ pgo/, 'no-pgo omits pgo make target');
    like($out, qr/Docker services\s*:\s*informix informix-gateway keydb/, 'informix selects informix + informix-gateway + keydb');
    like($out, qr/init-informix\.sh/, 'informix runs init-informix.sh');
    like($out, qr/SHOP_TEST_DOCKER=1/, 'informix validation sets SHOP_TEST_DOCKER=1');
}

# 6. --db both --cluster + KeyDB port conflict detection (6379 busy vs free)
{
    my ($rc_busy, $out_busy) = run_capture(
        {
            SHOP_INSTALL_KEYDB_PORT_BUSY => 1,
            PERL5_MT_ROOT                => undef,
            MOJOLICIOUS_MT_ROOT          => undef,
        },
        $stock_perl, $installer,
        '--dry-run', '--yes',
        '--prefix', $fresh_prefix,
        '--db', 'both', '--cluster',
    );
    is($rc_busy, 0, '--db both --cluster (busy 6379) exits 0');
    like($out_busy, qr/Docker services\s*:\s*db2 db2-gateway informix informix-gateway keydb/, 'both selects all DB + keydb services');
    like($out_busy, qr/init-db2\.sh/,      'both runs init-db2.sh');
    like($out_busy, qr/init-informix\.sh/, 'both runs init-informix.sh');
    like($out_busy, qr/Cluster mode\s*:\s*enabled/, 'cluster mode enabled');
    like($out_busy, qr/cluster\.enabled=true/,      'config update enables cluster');
    like($out_busy, qr/KeyDB port\s*:\s*6380/,      'switches to KeyDB port 6380 when 6379 busy');
    like($out_busy, qr/KEYDB_PORT=6380/,            'passes KEYDB_PORT=6380 to docker compose and tests');

    my ($rc_free, $out_free) = run_capture(
        {
            SHOP_INSTALL_KEYDB_PORT_BUSY => 0,
            PERL5_MT_ROOT                => undef,
            MOJOLICIOUS_MT_ROOT          => undef,
        },
        $stock_perl, $installer,
        '--dry-run', '--yes',
        '--prefix', $fresh_prefix,
        '--db', 'both', '--cluster',
    );
    is($rc_free, 0, '--db both --cluster (free 6379) exits 0');
    like($out_free, qr/KeyDB port\s*:\s*6379 \(default\)/, 'uses default KeyDB port 6379 when free');
    like($out_free, qr/KEYDB_PORT=6379/,                   'passes KEYDB_PORT=6379 when free');
}

# 7. Package-manager auto-install plan (brew, apt-get, dnf, pacman, apk)
{
    my @pm_cases = (
        [ 'darwin', 'brew',    'libsodium,openssl,zlib',            qr/brew install libsodium openssl\@3 zlib/ ],
        [ 'linux',  'apt-get', 'libsodium,openssl,zlib,pkg-config', qr/apt-get update && .*apt-get install -y .*pkg-config.*libsodium-dev.*libssl-dev.*zlib1g-dev/ ],
        [ 'linux',  'dnf',     'libsodium,openssl,zlib',            qr/dnf install -y libsodium-devel openssl-devel zlib-devel/ ],
        [ 'linux',  'pacman',  'libsodium,openssl,zlib',            qr/pacman -Sy --noconfirm libsodium openssl zlib/ ],
        [ 'linux',  'apk',     'libsodium,openssl,zlib',            qr/apk add --no-cache libsodium-dev openssl-dev zlib-dev/ ],
    );

    for my $c (@pm_cases) {
        my ($os, $pm, $sim, $re) = @$c;
        my ($rc, $out) = run_capture(
            {
                SHOP_INSTALL_OS               => $os,
                SHOP_INSTALL_PKG_MGR          => $pm,
                SHOP_INSTALL_SIMULATE_MISSING => $sim,
                PERL5_MT_ROOT                 => undef,
                MOJOLICIOUS_MT_ROOT           => undef,
            },
            $stock_perl, $installer,
            '--dry-run', '--yes',
            '--prefix', $fresh_prefix,
            '--db', 'sqlite',
        );
        is($rc, 0, "auto-install dry-run for $pm exits 0");
        like($out, $re, "auto-install plan for $pm matches expected command");
    }
}

# 8. --deps-from-source and automatic no-package-manager source fallback
{
    my ($rc_src, $out_src) = run_capture(
        {
            PERL5_MT_ROOT       => undef,
            MOJOLICIOUS_MT_ROOT => undef,
        },
        $stock_perl, $installer,
        '--dry-run', '--yes',
        '--prefix', $fresh_prefix,
        '--deps-from-source',
        '--db', 'sqlite',
    );
    is($rc_src, 0, '--deps-from-source --dry-run exits 0');
    like($out_src, qr{https://github\.com/madler/zlib\.git},       'builds zlib from official GitHub repo');
    like($out_src, qr{https://github\.com/jedisct1/libsodium\.git},'builds libsodium from official GitHub repo');
    like($out_src, qr{https://github\.com/openssl/openssl\.git},   'builds openssl from official GitHub repo');
    like($out_src, qr/--branch openssl-3\.5\.0/,                   'checks out openssl-3.5.0 for ML-KEM-768');
    like($out_src, qr{PKG_CONFIG_PATH=\Q$fresh_prefix\E/deps/lib/pkgconfig}, 'exports PKG_CONFIG_PATH for source deps');
    like($out_src, qr{LD_RUN_PATH=\Q$fresh_prefix\E/deps/lib},               'exports LD_RUN_PATH for source deps');

    my ($rc_fb, $out_fb) = run_capture(
        {
            SHOP_INSTALL_PKG_MGR          => 'none',
            SHOP_INSTALL_SIMULATE_MISSING => 'libsodium,openssl,zlib',
            PERL5_MT_ROOT                 => undef,
            MOJOLICIOUS_MT_ROOT           => undef,
        },
        $stock_perl, $installer,
        '--dry-run', '--yes',
        '--prefix', $fresh_prefix,
        '--db', 'sqlite',
    );
    is($rc_fb, 0, 'no-pkg-manager fallback --dry-run exits 0');
    like($out_fb, qr/Step 1c: Build C Libraries from Official GitHub Source/, 'falls back to source builds when no pkg manager');
    like($out_fb, qr{https://github\.com/openssl/openssl\.git},              'fallback includes OpenSSL source build');
}

# 9. Zero files mutated during --dry-run
{
    my $config_after = do {
        open(my $fh, '<:raw', $config) or die "Cannot read $config: $!";
        local $/;
        <$fh>;
    };
    my $config_mtime_after = (stat($config))[9];
    is($config_after, $config_before, 'config/shop.json content untouched by --dry-run');
    is($config_mtime_after, $config_mtime_before, 'config/shop.json mtime untouched by --dry-run');
    if (!$launcher_existed) {
        ok(!-e $launcher, 'bin/start-shop was not created by --dry-run');
    }
    ok(!-e $fresh_prefix, 'temp dry-run prefix directory was not created by --dry-run');
}

done_testing();
