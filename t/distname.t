#! perl -w
use strict;

use Test::More;
use Test::Smoke::SysInfo;

my @etc = glob "t/etc/*/DISTNAME";

#plan $^O eq 'linux'
#    ? (tests => scalar @etc)
#    : (skip_all => "$^O is not Linux");
plan 'no_plan'; local $^O = 'linux';

foreach my $dnf (@etc) {
    open my $dnh, "<", $dnf or die "$dnf: $!\n";
    chomp( my $dn = <$dnh> );
    close $dnh;

    (my $etc = $dnf) =~ s{/DISTNAME$}{};
    $ENV{SMOKE_USE_ETC} = $etc;

    my $si = Test::Smoke::SysInfo->new();
    is( $si->_distro, $dn, "Distname for $etc" );

    # Helper line :)
    $si->{__distro} eq $dn or print "echo '$si->{__distro}' >$etc/DISTNAME\n";
}