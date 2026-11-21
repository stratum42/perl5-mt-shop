use strict;
use warnings;
use File::Basename qw(dirname);
use ExtUtils::MakeMaker;

sub pkg_config {
    my ($flag, @pkgs) = @_;
    my $cmd = join(' ', 'pkg-config', $flag, @pkgs);
    my $out = `$cmd 2>/dev/null`;
    chomp $out if defined $out;
    return ($? == 0 && defined $out) ? $out : '';
}

my $sodium_inc  = pkg_config('--cflags', 'libsodium') || '-I/opt/homebrew/opt/libsodium/include';
my $sodium_libs = pkg_config('--libs',   'libsodium') || '-L/opt/homebrew/opt/libsodium/lib -lsodium';

my $ssl_inc     = pkg_config('--cflags', 'openssl')   || '-I/opt/homebrew/opt/openssl@3/include';
my $ssl_libs    = pkg_config('--libs',   'openssl')   || '-L/opt/homebrew/opt/openssl@3/lib -lcrypto';

my @extra;
my $perl_dir = dirname($^X);
if (-f "$perl_dir/perl.h") {
    push @extra, PERL_SRC => $perl_dir;
}

WriteMakefile(
    NAME         => 'Shop::SSH::Crypto',
    VERSION_FROM => 'lib/Shop/SSH/Crypto.pm',
    DEFINE       => '-DPERL_XS_THREADSAFE=1',
    INC          => "$sodium_inc $ssl_inc",
    LIBS         => ["$sodium_libs $ssl_libs -lz"],
    CCFLAGS      => '-Wall -Wextra -Wno-unused-parameter -O2',
    @extra,
);
