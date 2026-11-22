#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use File::Spec;
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use Cwd qw(abs_path getcwd);
use Config;
use IO::Socket::INET;

my $GITHUB_BASE        = 'https://github.com/stratum42';
my $LIBSODIUM_REPO     = 'https://github.com/jedisct1/libsodium.git';
my $OPENSSL_REPO       = 'https://github.com/openssl/openssl.git';
my $OPENSSL_TAG        = 'openssl-3.5.0';
my $ZLIB_REPO          = 'https://github.com/madler/zlib.git';

my %opt = (
    prefix           => undef,
    db               => undef,
    pgo              => undef,
    native           => undef,
    jobs             => undef,
    port             => 2222,
    ops_port         => 8088,
    cluster          => 0,
    admin_key        => undef,
    deps_from_source => 0,
    rebuild          => 0,
    skip_tests       => 0,
    yes              => 0,
    dry_run          => 0,
    help             => 0,
);

GetOptions(
    'prefix=s'          => \$opt{prefix},
    'db=s'              => \$opt{db},
    'pgo!'              => \$opt{pgo},
    'native!'           => \$opt{native},
    'jobs=i'            => \$opt{jobs},
    'port=i'            => \$opt{port},
    'ops-port=i'        => \$opt{ops_port},
    'cluster!'          => \$opt{cluster},
    'admin-key=s'       => \$opt{admin_key},
    'deps-from-source!' => \$opt{deps_from_source},
    'rebuild!'          => \$opt{rebuild},
    'skip-tests!'       => \$opt{skip_tests},
    'yes|y'             => \$opt{yes},
    'dry-run'           => \$opt{dry_run},
    'help|h'            => \$opt{help},
) or die "Run with --help for usage.\n";

if ($opt{help}) {
    print_usage();
    exit 0;
}

if (defined $opt{db} && $opt{db} !~ /\A(?:sqlite|db2|informix|both)\z/) {
    die "Invalid --db value '$opt{db}'. Expected one of: sqlite, db2, informix, both.\n";
}
if (defined $opt{jobs} && $opt{jobs} < 1) {
    die "Invalid --jobs value '$opt{jobs}'. Expected a positive integer.\n";
}
if ($opt{port} < 1 || $opt{port} > 65535) {
    die "Invalid --port value '$opt{port}'. Expected 1..65535.\n";
}
if ($opt{ops_port} < 1 || $opt{ops_port} > 65535) {
    die "Invalid --ops-port value '$opt{ops_port}'. Expected 1..65535.\n";
}

# =========================================================================
# Helpers
# =========================================================================

sub print_usage {
    print <<'USAGE';
Usage: perl install.pl [options]

Install, build, configure, and validate perl5-mt-shop on macOS or Linux.
Runs on stock system Perl using core modules only.

Options:
  --prefix <dir>          Base directory for stack repos, deps, and localperl
                          (default: parent dir of perl5-mt-shop, or
                          $HOME/perl5-mt-stack when run standalone)
  --db <backend>          Database backend: sqlite, db2, informix, or both
                          (prompts interactively if omitted on a TTY)
  --pgo / --no-pgo        Enable or disable PGO build for perl5-mt
                          (default: ON when PGO tooling is available)
  --native / --no-native  Enable or disable -Dusenative CPU tuning
                          (default: ON with --pgo)
  --deps-from-source      Build libsodium, OpenSSL 3.5+ (ML-KEM-768), and zlib
                          from official GitHub source into <prefix>/deps
  --jobs <N>              Parallel build jobs (default: detected CPU count)
  --port <N>              SSH storefront port (default: 2222)
  --ops-port <N>          HTTP ops and webhook port (default: 8088)
  --cluster               Enable multi-node SSH cluster mode (requires KeyDB)
  --admin-key <path>      SSH public key to grant admin access
                          (default: auto-detect ~/.ssh/id_ed25519.pub or id_rsa.pub)
  --rebuild               Rebuild perl5-mt even if already built
  --skip-tests            Skip Step 5 validation test suite
  --yes, -y               Non-interactive mode using defaults (auto-installs deps)
  --dry-run               Print detected plan and commands without making changes
  --help, -h              Show this help message
USAGE
}

sub shell_quote {
    my ($s) = @_;
    return "''" if !defined $s || $s eq '';
    return $s if $s =~ m{\A[A-Za-z0-9_./:=+\@-]+\z};
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub fmt_cmd {
    my (@cmd) = @_;
    return join(' ', map { shell_quote($_) } @cmd);
}

sub which_bin {
    my ($name) = @_;
    return $name if $name =~ m{/} && -x $name;
    my @dirs = File::Spec->path();
    for my $d (@dirs) {
        my $p = File::Spec->catfile($d, $name);
        return $p if -x $p && !-d $p;
    }
    return undef;
}

sub capture_cmd {
    my (@cmd) = @_;
    my $pid = open(my $fh, '-|');
    return (1, '') if !defined $pid;
    if ($pid == 0) {
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

sub run_cmd {
    my ($cmd_ref, %opts) = @_;
    my $cwd = $opts{cwd};
    my $env = $opts{env} || {};
    my $prefix_env = '';
    if (%$env) {
        $prefix_env = join(' ', map { "$_=".shell_quote($env->{$_}) } sort keys %$env) . ' ';
    }
    my $display = $prefix_env . fmt_cmd(@$cmd_ref);
    $display = "(cd " . shell_quote($cwd) . " && $display)" if defined $cwd;

    if ($opt{dry_run}) {
        print "  [dry-run] $display\n";
        return 0;
    }

    print "  \$ $display\n";
    my $orig_cwd;
    if (defined $cwd) {
        $orig_cwd = getcwd();
        chdir($cwd) or die "Failed to chdir to $cwd: $!\n";
    }
    local %ENV = (%ENV, %$env);
    my $status = system(@$cmd_ref);
    if (defined $orig_cwd) {
        chdir($orig_cwd);
    }
    if ($status != 0) {
        my $code = $status == -1 ? 127 : ($status >> 8);
        return $code if $opts{allow_fail};
        die "Command failed (exit $code): $display\n";
    }
    return 0;
}

sub run_shell {
    my ($shell_cmd, %opts) = @_;
    return run_cmd([ 'sh', '-c', $shell_cmd ], %opts);
}

sub prompt_choice {
    my ($question, $default, $valid_ref) = @_;
    while (1) {
        print "$question [$default]: ";
        my $line = <STDIN>;
        return $default if !defined $line;
        $line =~ s/\A\s+|\s+\z//g;
        return $default if $line eq '';
        my $lc = lc($line);
        if (grep { $_ eq $lc } @$valid_ref) {
            return $lc;
        }
        print "  Please choose one of: " . join(', ', @$valid_ref) . "\n";
    }
}

sub prompt_yesno {
    my ($question, $default_bool) = @_;
    my $hint = $default_bool ? 'Y/n' : 'y/N';
    while (1) {
        print "$question [$hint]: ";
        my $line = <STDIN>;
        return $default_bool if !defined $line;
        $line =~ s/\A\s+|\s+\z//g;
        return $default_bool if $line eq '';
        return 1 if $line =~ /\Ay(?:es)?\z/i;
        return 0 if $line =~ /\Ano?\z/i;
        print "  Please answer y or n.\n";
    }
}

sub is_port_busy {
    my ($host, $port) = @_;
    if (defined $ENV{SHOP_INSTALL_KEYDB_PORT_BUSY} && $port == 6379) {
        return $ENV{SHOP_INSTALL_KEYDB_PORT_BUSY} ? 1 : 0;
    }
    my $client = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 1,
    );
    if ($client) {
        close($client);
        return 1;
    }
    my $probe = IO::Socket::INET->new(
        LocalAddr => $host,
        LocalPort => $port,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    );
    if ($probe) {
        close($probe);
        return 0;
    }
    return 1;
}

sub version_ge {
    my ($ver, $req_maj, $req_min) = @_;
    return 0 if !defined $ver;
    if ($ver =~ /(\d+)\.(\d+)/) {
        my ($maj, $min) = (int($1), int($2));
        return 1 if $maj > $req_maj;
        return 1 if $maj == $req_maj && $min >= $req_min;
    }
    return 0;
}

sub prepend_env_path {
    my ($key, $dir) = @_;
    my $cur = $ENV{$key} || '';
    my @parts = grep { $_ ne '' && $_ ne $dir } split(/:/, $cur);
    $ENV{$key} = join(':', $dir, @parts);
}

# =========================================================================
# Step 1: Host Environment Detection & Dependency Preflight
# =========================================================================

sub detect_os {
    my $raw = lc($ENV{SHOP_INSTALL_OS} || $^O || 'unknown');
    return 'darwin' if $raw =~ /darwin|macos/;
    return 'linux'  if $raw =~ /linux/;
    return 'aix'    if $raw =~ /aix/;
    return $raw;
}

sub detect_arch {
    my ($rc, $out) = capture_cmd('uname', '-m');
    my $m = ($rc == 0) ? $out : ($Config{archname} || 'unknown');
    $m =~ s/\A\s+|\s+\z//g;
    return 'arm64'   if $m =~ /\A(?:arm64|aarch64)\z/i;
    return 'x86_64'  if $m =~ /\A(?:x86_64|amd64)\z/i;
    return 'ppc64le' if $m =~ /\Appc64le\z/i;
    return 's390x'   if $m =~ /\As390x\z/i;
    return $m || 'unknown';
}

sub detect_cpus {
    my ($os) = @_;
    if ($os eq 'darwin') {
        my ($rc, $out) = capture_cmd('sysctl', '-n', 'hw.ncpu');
        if ($rc == 0 && $out =~ /(\d+)/) {
            return int($1);
        }
    }
    if ($os eq 'linux') {
        my ($rc, $out) = capture_cmd('nproc');
        if ($rc == 0 && $out =~ /(\d+)/) {
            return int($1);
        }
        if (open(my $fh, '<', '/proc/cpuinfo')) {
            my $n = 0;
            while (<$fh>) {
                $n++ if /\Aprocessor\s*:/;
            }
            close($fh);
            return $n if $n > 0;
        }
    }
    if ($os eq 'aix') {
        my ($rc, $out) = capture_cmd('lsdev', '-Cc', 'processor');
        if ($rc == 0) {
            my @lines = grep { /\S/ } split(/\n/, $out);
            return scalar(@lines) if @lines > 0;
        }
    }
    return 4;
}

sub detect_pkg_manager {
    my ($os) = @_;
    if (defined $ENV{SHOP_INSTALL_PKG_MGR} && $ENV{SHOP_INSTALL_PKG_MGR} ne '') {
        return lc($ENV{SHOP_INSTALL_PKG_MGR});
    }
    if ($os eq 'darwin') {
        return 'brew' if which_bin('brew');
        return 'none';
    }
    for my $pm ('apt-get', 'dnf', 'yum', 'pacman', 'apk') {
        return $pm if which_bin($pm);
    }
    return 'none';
}

sub pkg_manager_install_cmd {
    my ($pm, $missing_ref) = @_;
    my %map;
    if ($pm eq 'brew') {
        %map = (
            cc          => 'llvm',
            git         => 'git',
            make        => 'make',
            'pkg-config'=> 'pkg-config',
            'ssh-keygen'=> 'openssh',
            sqlite3     => 'sqlite',
            libsodium   => 'libsodium',
            openssl     => 'openssl@3',
            zlib        => 'zlib',
        );
    } elsif ($pm eq 'apt-get') {
        %map = (
            cc          => 'build-essential',
            git         => 'git',
            make        => 'make',
            'pkg-config'=> 'pkg-config',
            'ssh-keygen'=> 'openssh-client',
            sqlite3     => 'sqlite3',
            libsodium   => 'libsodium-dev',
            openssl     => 'libssl-dev',
            zlib        => 'zlib1g-dev',
        );
    } elsif ($pm eq 'dnf' || $pm eq 'yum') {
        %map = (
            cc          => 'gcc',
            git         => 'git',
            make        => 'make',
            'pkg-config'=> 'pkgconf-pkg-config',
            'ssh-keygen'=> 'openssh-clients',
            sqlite3     => 'sqlite',
            libsodium   => 'libsodium-devel',
            openssl     => 'openssl-devel',
            zlib        => 'zlib-devel',
        );
    } elsif ($pm eq 'pacman') {
        %map = (
            cc          => 'base-devel',
            git         => 'git',
            make        => 'make',
            'pkg-config'=> 'pkgconf',
            'ssh-keygen'=> 'openssh',
            sqlite3     => 'sqlite',
            libsodium   => 'libsodium',
            openssl     => 'openssl',
            zlib        => 'zlib',
        );
    } elsif ($pm eq 'apk') {
        %map = (
            cc          => 'build-base',
            git         => 'git',
            make        => 'make',
            'pkg-config'=> 'pkgconf',
            'ssh-keygen'=> 'openssh-client',
            sqlite3     => 'sqlite',
            libsodium   => 'libsodium-dev',
            openssl     => 'openssl-dev',
            zlib        => 'zlib-dev',
        );
    } else {
        return undef;
    }

    my %seen;
    my @pkgs;
    for my $k (@$missing_ref) {
        my $p = $map{$k};
        next if !defined $p || $seen{$p}++;
        push @pkgs, $p;
    }
    return undef if !@pkgs;

    my $sudo = ($> == 0) ? '' : 'sudo ';
    my $pkg_str = join(' ', @pkgs);
    return "brew install $pkg_str"                                         if $pm eq 'brew';
    return "${sudo}apt-get update && ${sudo}apt-get install -y $pkg_str"   if $pm eq 'apt-get';
    return "${sudo}dnf install -y $pkg_str"                                if $pm eq 'dnf';
    return "${sudo}yum install -y $pkg_str"                                if $pm eq 'yum';
    return "${sudo}pacman -Sy --noconfirm $pkg_str"                        if $pm eq 'pacman';
    return "${sudo}apk add --no-cache $pkg_str"                            if $pm eq 'apk';
    return undef;
}

sub detect_compiler {
    my ($os) = @_;
    my @candidates = grep { defined $_ && $_ ne '' } ($ENV{CC}, 'cc', 'clang', 'gcc');
    my $cc_path;
    for my $c (@candidates) {
        $cc_path = which_bin($c);
        last if defined $cc_path;
    }
    return { found => 0, path => undef, family => 'none', gcc_major => 0, version => '', pgo_available => 0, pgo_tool => 'none' }
        if !defined $cc_path;

    my ($rc, $out) = capture_cmd($cc_path, '--version');
    my $first = (split(/\n/, $out))[0] || '';
    my $family = 'cc';
    my $gcc_major = 0;

    if ($out =~ /clang/i) {
        $family = 'clang';
    } elsif ($out =~ /\bgcc\b/i || basename($cc_path) =~ /\Agcc/i) {
        $family = 'gcc';
        if ($first =~ /\b(\d+)\.\d+(?:\.\d+)?\b/) {
            $gcc_major = int($1);
        }
    }

    my $pgo_available = 0;
    my $pgo_tool = 'none';
    if (defined $ENV{SHOP_INSTALL_PGO_AVAILABLE}) {
        $pgo_available = $ENV{SHOP_INSTALL_PGO_AVAILABLE} ? 1 : 0;
        $pgo_tool = $pgo_available ? 'simulated PGO tooling' : 'none';
    } elsif ($family eq 'clang' || $os eq 'darwin') {
        if (my $lp = which_bin('llvm-profdata')) {
            $pgo_available = 1;
            $pgo_tool = $lp;
        } elsif ($os eq 'darwin' || $^O eq 'darwin') {
            my ($xrc, $xout) = capture_cmd('xcrun', '-f', 'llvm-profdata');
            $xout =~ s/\A\s+|\s+\z//g;
            if ($xrc == 0 && $xout ne '') {
                $pgo_available = 1;
                $pgo_tool = "xcrun llvm-profdata ($xout)";
            }
        }
    } elsif ($family eq 'gcc') {
        $pgo_available = 1;
        $pgo_tool = 'gcc (-fprofile-generate/-fprofile-use)';
    }

    return {
        found         => 1,
        path          => $cc_path,
        family        => $family,
        gcc_major     => $gcc_major,
        version       => $first,
        pgo_available => $pgo_available,
        pgo_tool      => $pgo_tool,
    };
}

sub augment_pkg_config_path {
    my ($os, $deps_prefix) = @_;
    my @extra;
    if (defined $deps_prefix) {
        my $dp = File::Spec->catdir($deps_prefix, 'lib', 'pkgconfig');
        push @extra, $dp if -d $dp;
    }
    if ($os eq 'darwin') {
        for my $base ('/opt/homebrew', '/usr/local') {
            for my $pkg ('openssl@3', 'openssl', 'libsodium', 'zlib') {
                my $dir = "$base/opt/$pkg/lib/pkgconfig";
                push @extra, $dir if -d $dir;
            }
        }
    }
    return if !@extra;
    my $cur = $ENV{PKG_CONFIG_PATH} || '';
    my %seen = map { $_ => 1 } grep { $_ ne '' } split(/:/, $cur);
    my @add = grep { !$seen{$_}++ } @extra;
    return if !@add;
    $ENV{PKG_CONFIG_PATH} = $cur ne '' ? join(':', @add, $cur) : join(':', @add);
}

sub check_pkg_lib {
    my ($pkg_config, $lib) = @_;
    return (0, 'pkg-config missing') if !defined $pkg_config;
    my ($rc, $out) = capture_cmd($pkg_config, '--modversion', $lib);
    $out =~ s/\A\s+|\s+\z//g;
    return ($rc == 0 ? 1 : 0, $rc == 0 ? $out : 'missing');
}

sub detect_docker {
    my $docker = which_bin('docker');
    return (0, 0, undef, '') if !defined $docker;
    my ($rc, $out) = capture_cmd($docker, 'compose', 'version');
    $out =~ s/\A\s+|\s+\z//g;
    return (1, $rc == 0 ? 1 : 0, $docker, $out);
}

sub build_clib_from_source {
    my ($lib, $deps_prefix, $deps_src, $jobs, $native) = @_;
    my $cflags = $native ? '-O2 -g -march=native' : '-O2 -g';

    if (!$opt{dry_run}) {
        make_path($deps_src)    if !-d $deps_src;
        make_path($deps_prefix) if !-d $deps_prefix;
    }

    if ($lib eq 'zlib') {
        my $dir = File::Spec->catdir($deps_src, 'zlib');
        if (!-d $dir) {
            run_cmd([ 'git', 'clone', '--depth', '1', $ZLIB_REPO, $dir ]);
        }
        run_cmd([ './configure', "--prefix=$deps_prefix" ], cwd => $dir, env => { CFLAGS => $cflags });
        run_cmd([ 'make', "-j$jobs" ], cwd => $dir);
        run_cmd([ 'make', 'install' ], cwd => $dir);
    } elsif ($lib eq 'libsodium') {
        my $dir = File::Spec->catdir($deps_src, 'libsodium');
        if (!-d $dir) {
            run_cmd([ 'git', 'clone', '--depth', '1', $LIBSODIUM_REPO, $dir ]);
        }
        if (!-f File::Spec->catfile($dir, 'configure')) {
            run_cmd([ './autogen.sh', '-s' ], cwd => $dir);
        }
        run_cmd([ './configure', "--prefix=$deps_prefix" ], cwd => $dir, env => { CFLAGS => $cflags });
        run_cmd([ 'make', "-j$jobs" ], cwd => $dir);
        run_cmd([ 'make', 'install' ], cwd => $dir);
    } elsif ($lib eq 'openssl') {
        my $dir = File::Spec->catdir($deps_src, 'openssl');
        if (!-d $dir) {
            run_cmd([ 'git', 'clone', '--depth', '1', '--branch', $OPENSSL_TAG, $OPENSSL_REPO, $dir ]);
        }
        my @cfg = ('./Configure', "--prefix=$deps_prefix", '--libdir=lib', 'no-tests');
        push @cfg, '-march=native' if $native;
        run_cmd(\@cfg, cwd => $dir);
        run_cmd([ 'make', "-j$jobs" ], cwd => $dir);
        run_cmd([ 'make', 'install_sw' ], cwd => $dir);
    }
}

# =========================================================================
# Main Flow
# =========================================================================

my $os      = detect_os();
my $arch    = detect_arch();
my $cpus    = detect_cpus($os);
my $jobs    = defined $opt{jobs} ? $opt{jobs} : $cpus;
my $pkg_mgr = detect_pkg_manager($os);

my $script_path = abs_path($0) || File::Spec->rel2abs($0);
my $script_dir  = dirname($script_path);
my $in_shop_repo = (-f File::Spec->catfile($script_dir, 'bin', 'shop-server')
                 && -f File::Spec->catfile($script_dir, 'config', 'shop.json')) ? 1 : 0;

my $prefix;
if (defined $opt{prefix} && $opt{prefix} ne '') {
    $prefix = File::Spec->rel2abs($opt{prefix});
} elsif ($in_shop_repo) {
    $prefix = dirname($script_dir);
} else {
    my $home = $ENV{HOME} || '.';
    $prefix = File::Spec->catdir($home, 'perl5-mt-stack');
}

my $deps_prefix = File::Spec->catdir($prefix, 'deps');
my $deps_src    = File::Spec->catdir($deps_prefix, 'src');

augment_pkg_config_path($os, $deps_prefix);

my %sim_missing = map { lc($_) => 1 }
    grep { $_ ne '' } split(/,/, $ENV{SHOP_INSTALL_SIMULATE_MISSING} || '');

my $cc_info    = detect_compiler($os);
$cc_info->{found} = 0 if $sim_missing{cc};

my $git_bin    = $sim_missing{git}          ? undef : which_bin('git');
my $make_bin   = $sim_missing{make}         ? undef : which_bin('make');
my $pkg_bin    = $sim_missing{'pkg-config'} ? undef : which_bin('pkg-config');
my $sqlite_bin = $sim_missing{sqlite3}      ? undef : which_bin('sqlite3');
my $keygen_bin = $sim_missing{'ssh-keygen'} ? undef : which_bin('ssh-keygen');
my ($has_docker, $has_compose, $docker_bin, $compose_ver) = detect_docker();

my ($has_sodium,  $sodium_ver)  = $sim_missing{libsodium} ? (0, 'missing') : check_pkg_lib($pkg_bin, 'libsodium');
my ($has_openssl, $openssl_ver) = $sim_missing{openssl}   ? (0, 'missing') : check_pkg_lib($pkg_bin, 'openssl');
my ($has_zlib,    $zlib_ver)    = $sim_missing{zlib}      ? (0, 'missing') : check_pkg_lib($pkg_bin, 'zlib');
my $openssl_has_mlkem = ($has_openssl && version_ge($openssl_ver, 3, 5)) ? 1 : 0;

print "perl5-mt-shop installer\n";
print "=======================\n\n";
print "Step 1: Host Environment & Dependency Preflight\n";
print "  OS / Arch       : $os / $arch\n";
print "  CPU cores       : $cpus (build jobs: $jobs)\n";
print "  Package manager : $pkg_mgr\n";
print "  C compiler      : " . ($cc_info->{found} ? "$cc_info->{path} ($cc_info->{family}" . ($cc_info->{gcc_major} ? " $cc_info->{gcc_major}" : '') . ")" : "MISSING") . "\n";
print "  PGO tooling     : " . ($cc_info->{pgo_available} ? "available ($cc_info->{pgo_tool})" : "not found (will fall back to -O2 -g)") . "\n";
print "  git             : " . ($git_bin    ? $git_bin    : "MISSING") . "\n";
print "  make            : " . ($make_bin   ? $make_bin   : "MISSING") . "\n";
print "  pkg-config      : " . ($pkg_bin    ? $pkg_bin    : "MISSING") . "\n";
print "  ssh-keygen      : " . ($keygen_bin ? $keygen_bin : "MISSING") . "\n";
print "  sqlite3         : " . ($sqlite_bin ? $sqlite_bin : "MISSING") . "\n";
print "  docker          : " . ($has_docker ? ($has_compose ? "$docker_bin ($compose_ver)" : "$docker_bin (compose plugin missing)") : "not found") . "\n";
print "  libsodium       : " . ($has_sodium  ? $sodium_ver  : "MISSING") . "\n";
print "  openssl         : " . ($has_openssl ? $openssl_ver . ($openssl_has_mlkem ? ' (ML-KEM-768 ready)' : ' (< 3.5; pass --deps-from-source for ML-KEM-768)') : "MISSING") . "\n";
print "  zlib            : " . ($has_zlib    ? $zlib_ver    : "MISSING") . "\n";
print "\n";

# Resolve interactive choices if on a TTY and not --yes / --dry-run
my $interactive = (!$opt{yes} && !$opt{dry_run} && -t STDIN && -t STDOUT) ? 1 : 0;

if (!defined $opt{db}) {
    if ($interactive) {
        $opt{db} = prompt_choice(
            'Select database backend (sqlite, db2, informix, both)',
            'sqlite',
            [qw(sqlite db2 informix both)]
        );
    } else {
        $opt{db} = 'sqlite';
    }
}

if (!defined $opt{pgo}) {
    if ($interactive) {
        my $rec = $cc_info->{pgo_available} ? 1 : 0;
        my $label = $rec
            ? 'Enable PGO build for perl5-mt (recommended)'
            : 'Enable PGO build for perl5-mt (tooling not detected; will fall back to -O2 -g)';
        $opt{pgo} = prompt_yesno($label, $rec);
    } else {
        $opt{pgo} = $cc_info->{pgo_available} ? 1 : 0;
    }
}

my $effective_pgo = $opt{pgo} ? 1 : 0;
if ($effective_pgo && !$cc_info->{pgo_available}) {
    print "  Note: PGO requested, but PGO tooling was not detected; falling back to -O2 -g.\n\n";
    $effective_pgo = 0;
}

if (!defined $opt{native}) {
    if ($interactive) {
        $opt{native} = prompt_yesno('Enable -Dusenative CPU tuning for perl5-mt', $effective_pgo ? 1 : 0);
    } else {
        $opt{native} = $effective_pgo ? 1 : 0;
    }
}
my $effective_native = $opt{native} ? 1 : 0;

# Auto-install missing system tools and C libraries
my @missing_tools;
push @missing_tools, 'cc'         if !$cc_info->{found};
push @missing_tools, 'git'        if !$git_bin;
push @missing_tools, 'make'       if !$make_bin;
push @missing_tools, 'pkg-config' if !$pkg_bin;
push @missing_tools, 'ssh-keygen' if !$keygen_bin;
push @missing_tools, 'sqlite3'    if !$sqlite_bin && $opt{db} eq 'sqlite';

my @missing_clibs;
push @missing_clibs, 'libsodium' if !$has_sodium;
push @missing_clibs, 'openssl'   if !$has_openssl;
push @missing_clibs, 'zlib'      if !$has_zlib;

my @clibs_from_source;
if ($opt{deps_from_source}) {
    @clibs_from_source = ('zlib', 'libsodium', 'openssl');
}

my @pkg_install_targets = $opt{deps_from_source}
    ? @missing_tools
    : (@missing_tools, @missing_clibs);

if (@pkg_install_targets && $pkg_mgr ne 'none') {
    my $pm_cmd = pkg_manager_install_cmd($pkg_mgr, \@pkg_install_targets);
    if (defined $pm_cmd) {
        print "Step 1b: Auto-Install Missing System Dependencies ($pkg_mgr)\n";
        print "  Missing         : " . join(', ', @pkg_install_targets) . "\n";
        if ($opt{dry_run}) {
            print "  [dry-run] $pm_cmd\n\n";
        } else {
            my $do_install = $opt{yes} ? 1 : ($interactive ? prompt_yesno("Run '$pm_cmd' now?", 1) : 1);
            if ($do_install) {
                my $rc = run_shell($pm_cmd, allow_fail => 1);
                if ($rc == 0) {
                    augment_pkg_config_path($os, $deps_prefix);
                    $cc_info    = detect_compiler($os);
                    $git_bin    = which_bin('git');
                    $make_bin   = which_bin('make');
                    $pkg_bin    = which_bin('pkg-config');
                    $sqlite_bin = which_bin('sqlite3');
                    $keygen_bin = which_bin('ssh-keygen');
                    ($has_sodium,  $sodium_ver)  = check_pkg_lib($pkg_bin, 'libsodium');
                    ($has_openssl, $openssl_ver) = check_pkg_lib($pkg_bin, 'openssl');
                    ($has_zlib,    $zlib_ver)    = check_pkg_lib($pkg_bin, 'zlib');
                    @missing_clibs = ();
                    push @missing_clibs, 'libsodium' if !$has_sodium;
                    push @missing_clibs, 'openssl'   if !$has_openssl;
                    push @missing_clibs, 'zlib'      if !$has_zlib;
                } else {
                    print "  Warning: package manager install exited with code $rc.\n";
                }
            }
        }
        print "\n";
    }
} elsif (@missing_clibs && $pkg_mgr eq 'none') {
    # Automatic fallback to building missing C libs from official GitHub source
    @clibs_from_source = @missing_clibs;
}

# Build C libraries from official GitHub source if requested or fallback triggered
my $using_source_deps = 0;
if (@clibs_from_source) {
    $using_source_deps = 1;
    print "Step 1c: Build C Libraries from Official GitHub Source ($deps_prefix)\n";
    print "  Libraries       : " . join(', ', @clibs_from_source) . "\n";
    print "  Sources         : zlib=$ZLIB_REPO, libsodium=$LIBSODIUM_REPO, openssl=$OPENSSL_REPO ($OPENSSL_TAG)\n";
    for my $lib (@clibs_from_source) {
        build_clib_from_source($lib, $deps_prefix, $deps_src, $jobs, $effective_native);
    }
    my $deps_pc  = File::Spec->catdir($deps_prefix, 'lib', 'pkgconfig');
    my $deps_lib = File::Spec->catdir($deps_prefix, 'lib');
    prepend_env_path('PKG_CONFIG_PATH', $deps_pc);
    prepend_env_path('LD_RUN_PATH', $deps_lib);
    print "  Exported        : PKG_CONFIG_PATH=$deps_pc, LD_RUN_PATH=$deps_lib\n\n";
    if (!$opt{dry_run}) {
        ($has_sodium,  $sodium_ver)  = check_pkg_lib($pkg_bin, 'libsodium');
        ($has_openssl, $openssl_ver) = check_pkg_lib($pkg_bin, 'openssl');
        ($has_zlib,    $zlib_ver)    = check_pkg_lib($pkg_bin, 'zlib');
    }
} elsif (-d File::Spec->catdir($deps_prefix, 'lib', 'pkgconfig')) {
    $using_source_deps = 1;
    prepend_env_path('PKG_CONFIG_PATH', File::Spec->catdir($deps_prefix, 'lib', 'pkgconfig'));
    prepend_env_path('LD_RUN_PATH', File::Spec->catdir($deps_prefix, 'lib'));
}

# Final preflight check before cloning/building
my @still_missing;
push @still_missing, 'C compiler (cc/clang/gcc)' if !$cc_info->{found};
push @still_missing, 'git'                       if !$git_bin;
push @still_missing, 'make'                      if !$make_bin;
push @still_missing, 'pkg-config'                if !$pkg_bin;
push @still_missing, 'ssh-keygen'                if !$keygen_bin;
if (!$using_source_deps) {
    push @still_missing, 'libsodium' if !$has_sodium;
    push @still_missing, 'openssl'   if !$has_openssl;
    push @still_missing, 'zlib'      if !$has_zlib;
}

my $needs_docker = ($opt{db} ne 'sqlite' || $opt{cluster}) ? 1 : 0;
if ($needs_docker && (!$has_docker || !$has_compose)) {
    push @still_missing, 'docker + docker compose';
}

if (@still_missing && !$opt{dry_run}) {
    print "Missing required dependencies after preflight: " . join(', ', @still_missing) . "\n";
    if ($needs_docker && (!$has_docker || !$has_compose)) {
        print "Install Docker with Compose for --db $opt{db}" . ($opt{cluster} ? ' / --cluster' : '') . ".\n";
    }
    exit 1;
}

# =========================================================================
# Step 2: Resolve Paths & Clone Missing Dependencies from GitHub (stratum42)
# =========================================================================

my $perl5_mt_root = $ENV{PERL5_MT_ROOT}
    ? File::Spec->rel2abs($ENV{PERL5_MT_ROOT})
    : File::Spec->catdir($prefix, 'perl5-mt');

my $mojo_mt_root = $ENV{MOJOLICIOUS_MT_ROOT}
    ? File::Spec->rel2abs($ENV{MOJOLICIOUS_MT_ROOT})
    : File::Spec->catdir($prefix, 'mojolicious-mt');

my $shop_root = ($in_shop_repo && !defined $opt{prefix})
    ? $script_dir
    : File::Spec->catdir($prefix, 'perl5-mt-shop');

my $localperl_prefix = File::Spec->catdir($prefix, 'localperl');

print "Step 2: Repositories & Dependencies ($GITHUB_BASE)\n";
print "  Prefix          : $prefix\n";
print "  perl5-mt        : $perl5_mt_root ($GITHUB_BASE/perl5-mt.git)\n";
print "  mojolicious-mt  : $mojo_mt_root ($GITHUB_BASE/mojolicious-mt.git)\n";
print "  perl5-mt-shop   : $shop_root ($GITHUB_BASE/perl5-mt-shop.git)\n";

if (!-d $prefix) {
    if ($opt{dry_run}) {
        print "  [dry-run] mkdir -p " . shell_quote($prefix) . "\n";
    } else {
        make_path($prefix);
    }
}

my @repos = (
    { name => 'perl5-mt',       dir => $perl5_mt_root, url => "$GITHUB_BASE/perl5-mt.git" },
    { name => 'mojolicious-mt', dir => $mojo_mt_root,  url => "$GITHUB_BASE/mojolicious-mt.git" },
    { name => 'perl5-mt-shop',  dir => $shop_root,     url => "$GITHUB_BASE/perl5-mt-shop.git" },
);

for my $r (@repos) {
    if (-d $r->{dir} && (-d File::Spec->catdir($r->{dir}, '.git') || -f File::Spec->catfile($r->{dir}, 'Makefile') || -f File::Spec->catfile($r->{dir}, 'Configure'))) {
        print "  [found] $r->{name} at $r->{dir}\n";
    } else {
        print "  [clone] $r->{name} from $r->{url}\n";
        run_cmd([ 'git', 'clone', $r->{url}, $r->{dir} ]);
    }
}
print "\n";

# =========================================================================
# Step 3: Build perl5-mt (PGO + native), mojolicious-mt XS, and shop XS
# =========================================================================

my $perl_bin = File::Spec->catfile($perl5_mt_root, 'perl');
my $perl_lib = File::Spec->catfile($perl5_mt_root, 'lib');

my @configure_cmd = ('./Configure', '-des', '-Dusethreads');
if ($os eq 'linux') {
    push @configure_cmd, '-Ud_thread_local';
}
push @configure_cmd, "-Dprefix=$localperl_prefix";
if ($os eq 'linux') {
    push @configure_cmd, "-Accflags=-std=gnu17";
}
if ($effective_pgo) {
    push @configure_cmd, '-Dusepgo';
} else {
    push @configure_cmd, "-Doptimize=-O2 -g";
}
if ($effective_native) {
    push @configure_cmd, '-Dusenative';
}

my @perl_make_cmd = ('make', "-j$jobs");
push @perl_make_cmd, 'pgo' if $effective_pgo;

print "Step 3: Build perl5-mt, mojolicious-mt XS, and perl5-mt-shop XS\n";
print "  PGO enabled     : " . ($effective_pgo ? 'yes' : 'no (-O2 -g)') . "\n";
print "  Native tuning   : " . ($effective_native ? 'yes (-Dusenative)' : 'no') . "\n";
print "  Configure flags : " . fmt_cmd(@configure_cmd) . "\n";

if (!-x $perl_bin || $opt{rebuild}) {
    run_cmd(\@configure_cmd, cwd => $perl5_mt_root);
    run_cmd(\@perl_make_cmd, cwd => $perl5_mt_root);
} else {
    print "  [skip] perl5-mt binary already built at $perl_bin (pass --rebuild to force)\n";
}

# Build mojolicious-mt XS modules (Mojo::MT::Accel and Mojo::MT::KeyDB::XS)
for my $xs_sub ('xs', 'xs-keydb') {
    my $xs_dir = File::Spec->catdir($mojo_mt_root, $xs_sub);
    if (-f File::Spec->catfile($xs_dir, 'Makefile.PL') || $opt{dry_run}) {
        run_cmd(
            [ $perl_bin, "-I$perl_lib", 'Makefile.PL' ],
            cwd => $xs_dir,
            env => { PERL5LIB => $perl_lib },
        );
        run_cmd(
            [ 'make', "-j$jobs" ],
            cwd => $xs_dir,
            env => { PERL5LIB => $perl_lib },
        );
    }
}

# Build perl5-mt-shop XS crypto/zlib extension and generate SSH host key
my %crypto_env;
if ($using_source_deps) {
    $crypto_env{PKG_CONFIG_PATH} = $ENV{PKG_CONFIG_PATH};
    $crypto_env{LD_RUN_PATH}     = $ENV{LD_RUN_PATH};
}
run_cmd(
    [
        'make',
        '-C', $shop_root,
        "PERL5_MT_ROOT=$perl5_mt_root",
        "MOJOLICIOUS_MT_ROOT=$mojo_mt_root",
        "PERL=$perl_bin",
        'crypto',
        'hostkey',
    ],
    env => \%crypto_env,
);
print "\n";

# =========================================================================
# Step 4: Database, Docker, Admin Key, Config, and Launcher
# =========================================================================

my $keydb_busy = is_port_busy('127.0.0.1', 6379);
my $keydb_port = $keydb_busy ? 6380 : 6379;

my @docker_services;
if ($opt{db} eq 'db2') {
    @docker_services = qw(db2 db2-gateway keydb);
} elsif ($opt{db} eq 'informix') {
    @docker_services = qw(informix informix-gateway keydb);
} elsif ($opt{db} eq 'both') {
    @docker_services = qw(db2 db2-gateway informix informix-gateway keydb);
} elsif ($opt{cluster}) {
    @docker_services = qw(keydb);
}

my $driver_for_config = ($opt{db} eq 'both') ? 'db2' : $opt{db};

# Detect admin SSH public key fingerprint
my $admin_key_path = $opt{admin_key};
if (!defined $admin_key_path) {
    my $home = $ENV{HOME} || '';
    if ($home ne '') {
        for my $cand ('id_ed25519.pub', 'id_rsa.pub') {
            my $p = File::Spec->catfile($home, '.ssh', $cand);
            if (-f $p) {
                $admin_key_path = $p;
                last;
            }
        }
    }
}

my $admin_fp;
if (defined $admin_key_path && -f $admin_key_path && defined $keygen_bin) {
    my ($rc, $out) = capture_cmd($keygen_bin, '-lf', $admin_key_path);
    if ($rc == 0 && $out =~ /(SHA256:[A-Za-z0-9+\/=]+)/) {
        $admin_fp = $1;
    }
}

print "Step 4: Database, Docker, and Configuration\n";
print "  DB backend      : $opt{db} (config driver: $driver_for_config)\n";
print "  SSH port        : $opt{port}\n";
print "  Ops HTTP port   : $opt{ops_port}\n";
print "  Cluster mode    : " . ($opt{cluster} ? 'enabled' : 'disabled') . "\n";
print "  KeyDB port      : $keydb_port" . ($keydb_busy ? " (127.0.0.1:6379 in use, switched to 6380)" : " (default)") . "\n";
if (defined $admin_fp) {
    print "  Admin key       : $admin_key_path ($admin_fp)\n";
} elsif (defined $admin_key_path) {
    print "  Admin key       : $admin_key_path (could not extract fingerprint)\n";
} else {
    print "  Admin key       : none detected (pass --admin-key <path> to add one)\n";
}

if (@docker_services) {
    print "  Docker services : " . join(' ', @docker_services) . "\n";
    my $compose_file = File::Spec->catfile($shop_root, 'docker', 'docker-compose.yml');
    run_cmd(
        [ 'docker', 'compose', '-f', $compose_file, 'up', '-d', '--build', @docker_services ],
        env => { KEYDB_PORT => $keydb_port },
    );

    if (!$opt{dry_run}) {
        wait_for_docker_services($compose_file, \@docker_services, $keydb_port);
    } else {
        print "  [dry-run] wait for Docker service healthchecks: " . join(', ', @docker_services) . "\n";
    }

    if ($opt{db} eq 'db2' || $opt{db} eq 'both') {
        run_cmd([ File::Spec->catfile($shop_root, 'docker', 'init-db2.sh') ], cwd => $shop_root);
    }
    if ($opt{db} eq 'informix' || $opt{db} eq 'both') {
        run_cmd([ File::Spec->catfile($shop_root, 'docker', 'init-informix.sh') ], cwd => $shop_root);
    }
} else {
    print "  Docker services : none (local SQLite mode)\n";
}

my $config_path   = File::Spec->catfile($shop_root, 'config', 'shop.json');
my $launcher_path = File::Spec->catfile($shop_root, 'bin', 'start-shop');

if ($opt{dry_run}) {
    print "  [dry-run] update $config_path (driver=$driver_for_config, ssh.port=$opt{port}, ops.port=$opt{ops_port}, keydb.port=$keydb_port, cluster.enabled="
        . ($opt{cluster} ? 'true' : 'false')
        . (defined $admin_fp ? ", admin_fingerprints+=$admin_fp" : '')
        . ")\n";
    print "  [dry-run] write executable launcher $launcher_path\n";
} else {
    update_shop_config($config_path, {
        driver     => $driver_for_config,
        ssh_port   => $opt{port},
        ops_port   => $opt{ops_port},
        keydb_port => $keydb_port,
        cluster    => $opt{cluster} ? 1 : 0,
        admin_fp   => $admin_fp,
    });
    write_launcher($launcher_path, {
        shop_root         => $shop_root,
        perl5_mt_root     => $perl5_mt_root,
        mojo_mt_root      => $mojo_mt_root,
        perl_bin          => $perl_bin,
        driver            => $driver_for_config,
        keydb_port        => $keydb_port,
        using_source_deps => $using_source_deps,
        deps_prefix       => $deps_prefix,
    });
    print "  [ok] updated $config_path\n";
    print "  [ok] wrote executable launcher $launcher_path\n";
}
print "\n";

# =========================================================================
# Step 5: Full Installation Validation
# =========================================================================

print "Step 5: Validation\n";
if ($opt{skip_tests}) {
    print "  [skip] test suite skipped (--skip-tests)\n";
} else {
    my %test_env = ( KEYDB_PORT => $keydb_port );
    if ($opt{db} eq 'db2' || $opt{db} eq 'informix' || $opt{db} eq 'both') {
        $test_env{SHOP_TEST_DOCKER} = 1;
    }
    if ($using_source_deps) {
        $test_env{PKG_CONFIG_PATH} = $ENV{PKG_CONFIG_PATH};
        $test_env{LD_RUN_PATH}     = $ENV{LD_RUN_PATH};
    }
    run_cmd(
        [
            'make',
            '-C', $shop_root,
            "PERL5_MT_ROOT=$perl5_mt_root",
            "MOJOLICIOUS_MT_ROOT=$mojo_mt_root",
            "PERL=$perl_bin",
            'test',
        ],
        env => \%test_env,
    );
}

print "\n";
print "Summary\n";
print "-------\n";
print "  Mode            : " . ($opt{dry_run} ? 'dry-run (no files or containers modified)' : 'installed') . "\n";
print "  Shop root       : $shop_root\n";
print "  DB driver       : $driver_for_config" . ($opt{db} eq 'both' ? ' (db2 + informix containers ready)' : '') . "\n";
print "  KeyDB port      : $keydb_port\n";
print "  Start server    : ./bin/start-shop\n";
print "  Connect via SSH : ssh -C -p $opt{port} localhost\n";
print "  Ops healthz     : http://127.0.0.1:$opt{ops_port}/healthz\n";
print "  Ops metrics     : http://127.0.0.1:$opt{ops_port}/metrics\n";
exit 0;

# =========================================================================
# Subroutines for Step 4 mutations (never called in --dry-run)
# =========================================================================

sub wait_for_docker_services {
    my ($compose_file, $services_ref, $kport) = @_;
    my $max_wait = 300;
    my $start = time();
    my %need = map { $_ => 1 } @$services_ref;

    print "  Waiting for Docker services to become healthy (up to ${max_wait}s)...\n";
    while (time() - $start < $max_wait) {
        my $all_ok = 1;
        if ($need{'keydb'}) {
            my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $kport, Proto => 'tcp', Timeout => 2);
            if ($s) { close($s); } else { $all_ok = 0; }
        }
        if ($need{'db2-gateway'}) {
            my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => 50050, Proto => 'tcp', Timeout => 2);
            if ($s) { close($s); } else { $all_ok = 0; }
        }
        if ($need{'informix-gateway'}) {
            my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => 50051, Proto => 'tcp', Timeout => 2);
            if ($s) { close($s); } else { $all_ok = 0; }
        }
        if ($all_ok) {
            print "  [ok] Docker services are accepting connections.\n";
            return 1;
        }
        sleep 3;
    }
    die "Timed out waiting for Docker services to become healthy.\n";
}

sub update_shop_config {
    my ($path, $params) = @_;
    die "Config file not found: $path\n" if !-f $path;
    my $has_json_pp = eval { require JSON::PP; 1 };
    die "JSON::PP is required to update $path\n" if !$has_json_pp;

    open(my $in, '<:raw', $path) or die "Cannot read $path: $!\n";
    local $/;
    my $raw = <$in>;
    close($in);

    my $json = JSON::PP->new->utf8->pretty->canonical;
    $json->indent_length(2) if $json->can('indent_length');
    my $cfg = $json->decode($raw);

    $cfg->{db}{driver}       = $params->{driver};
    $cfg->{ssh}{port}        = int($params->{ssh_port});
    $cfg->{ops}{port}        = int($params->{ops_port});
    $cfg->{keydb}{port}      = int($params->{keydb_port});
    $cfg->{cluster}{enabled} = $params->{cluster} ? JSON::PP::true() : JSON::PP::false();

    if (defined $params->{admin_fp} && $params->{admin_fp} ne '') {
        $cfg->{admin_fingerprints} ||= [];
        if (!grep { $_ eq $params->{admin_fp} } @{ $cfg->{admin_fingerprints} }) {
            push @{ $cfg->{admin_fingerprints} }, $params->{admin_fp};
        }
    }

    my $tmp = "$path.tmp.$$";
    open(my $out, '>:raw', $tmp) or die "Cannot write $tmp: $!\n";
    print {$out} $json->encode($cfg);
    close($out) or die "Failed closing $tmp: $!\n";
    rename($tmp, $path) or die "Cannot rename $tmp to $path: $!\n";
}

sub write_launcher {
    my ($path, $p) = @_;
    my $dir = dirname($path);
    make_path($dir) if !-d $dir;

    my $deps_exports = '';
    if ($p->{using_source_deps}) {
        my $pc  = File::Spec->catdir($p->{deps_prefix}, 'lib', 'pkgconfig');
        my $lib = File::Spec->catdir($p->{deps_prefix}, 'lib');
        $deps_exports = "export PKG_CONFIG_PATH=" . shell_quote($pc) . "\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}\n"
                      . "export LD_RUN_PATH=" . shell_quote($lib) . "\${LD_RUN_PATH:+:\$LD_RUN_PATH}\n";
    }

    my $content = <<"SH";
#!/bin/sh
set -eu

SHOP_ROOT=\${SHOP_ROOT:-@{[ shell_quote($p->{shop_root}) ]}}
PERL5_MT_ROOT=\${PERL5_MT_ROOT:-@{[ shell_quote($p->{perl5_mt_root}) ]}}
MOJOLICIOUS_MT_ROOT=\${MOJOLICIOUS_MT_ROOT:-@{[ shell_quote($p->{mojo_mt_root}) ]}}
PERL_BIN=\${PERL:-@{[ shell_quote($p->{perl_bin}) ]}}
export SHOP_DB_DRIVER=\${SHOP_DB_DRIVER:-@{[ shell_quote($p->{driver}) ]}}
export KEYDB_PORT=\${KEYDB_PORT:-$p->{keydb_port}}
export PERL5_MT_ROOT MOJOLICIOUS_MT_ROOT
${deps_exports}
mkdir -p "\$SHOP_ROOT/var"

exec "\$PERL_BIN" \\
  -I"\$PERL5_MT_ROOT/lib" \\
  -I"\$SHOP_ROOT/xs/Shop-SSH-Crypto/blib/arch" \\
  -I"\$SHOP_ROOT/xs/Shop-SSH-Crypto/blib/lib" \\
  -I"\$SHOP_ROOT/lib" \\
  -I"\$MOJOLICIOUS_MT_ROOT/lib" \\
  -I"\$MOJOLICIOUS_MT_ROOT/xs/blib/lib" \\
  -I"\$MOJOLICIOUS_MT_ROOT/xs/blib/arch" \\
  -I"\$MOJOLICIOUS_MT_ROOT/xs-keydb/blib/lib" \\
  -I"\$MOJOLICIOUS_MT_ROOT/xs-keydb/blib/arch" \\
  "\$SHOP_ROOT/bin/shop-server" --config "\$SHOP_ROOT/config/shop.json" "\$@"
SH

    my $tmp = "$path.tmp.$$";
    open(my $fh, '>', $tmp) or die "Cannot write $tmp: $!\n";
    print {$fh} $content;
    close($fh) or die "Failed closing $tmp: $!\n";
    chmod 0755, $tmp or die "Cannot chmod $tmp: $!\n";
    rename($tmp, $path) or die "Cannot rename $tmp to $path: $!\n";
}
