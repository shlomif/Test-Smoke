package Test::Smoke::App::RunSmoke;
use warnings;
use strict;
use Carp;

use base 'Test::Smoke::App::Base';

use Config;
use File::Spec::Functions;
use Test::Smoke::BuildCFG;
use Test::Smoke::Policy;
use Test::Smoke::Smoker;
use Test::Smoke::SourceTree qw/ST_MISSING ST_UNDECLARED/;
use Test::Smoke::Util qw/
    calc_timeout
    get_local_patches
    get_patch
    set_local_patch
    skip_config
/;
use Test::Smoke::Util::Execute;

=head1 NAME

Test::Smoke::App::RunSmoke - The tsrunsmoke.pl application.

=head1 DESCRIPTION

This applet takes care of running the "smoke-mantra" for all
build-configurations.

=head2 $smoker->run();

reimplemention of the old C<Test::Smoke::run_smoke()>.

=cut

sub run {
    my $self = shift;

    $self->log_info("[%s] chdir(%s)", $0, $self->option('ddir'));
    chdir $self->option('ddir') or
        die sprintf("Cannot chdir(%): %s", $self->option('ddir'), $!);

    my $timeout = 0;
    if ($Config{d_alarm} && $self->option('killtime')) {
        $timeout = calc_timeout($self->option('killtime'));
        $self->log_info(
            "Setup alarm: %s", scalar localtime(time + $timeout)
        );
    }
    $timeout and local $SIG{ALRM} = sub {
        warn "This smoke is aborted (@{[$self->option('killtime')]})\n";
        exit;
    };
    $Config{d_alarm} and alarm $timeout;

   $self->run_smoke();
}

=head2  $smoker->run_smoke();

=cut

sub run_smoke {
    my $self = shift;

    my $BuildCFG = $self->create_buildcfg(@_);

    my $mode = $self->option('continue') ? ">>" : ">";
    my $logfile = catfile($self->option('ddir'), $self->option('outfile'));
    open my $log, $mode, $logfile or die "Cannot create($logfile): $!";

    my $Policy = Test::Smoke::Policy->new(
        updir(),
        $self->option('verbose'),
        $BuildCFG->policy_targets
    );

    my $smoker = $self->{_smoker} = Test::Smoke::Smoker->new(
        $log,
        {
            $self->options,
            v => $self->option('verbose')
        }
    );
    $smoker->mark_in;

    if ($self->option('verbose') && $self->option('defaultenv')) {
        $smoker->tty( "Running smoke tests without \$ENV{PERLIO}\n" );
    }

    my $harness_msg;
    if ( $self->option('harnessonly') ) {
        $harness_msg = "Running test suite only with 'harness'";
        if ($self->option('harness3opts')) {
            $harness_msg .= " with HARNESS_OPTIONS="
                          . $self->option('harness3opts');
        }
    }
    if ($self->option('verbose') && $harness_msg) {
        $smoker->tty( "$harness_msg.\n" );
    }

    if (! chdir($self->option('ddir'))) {
        die sprintf("Cannot chdir(%s): %s", $self->option('ddir'), $!);
    }

    my $patch = get_patch($self->option('ddir'));
    if (!$self->option('continue')) {
        $smoker->make_distclean();
        $smoker->ttylog("Smoking patch $patch->[0] $patch->[1]\n");
        $smoker->ttylog("Smoking branch $patch->[2]\n") if $patch->[2];
        $self->do_manifest_check();
        $self->add_smoke_patchlevel($patch->[0]);
    }

    foreach my $this_cfg ( $BuildCFG->configurations ) {
        $smoker->mark_out; $smoker->mark_in;
        if ( skip_config( $this_cfg ) ) {
            $smoker->ttylog( "Skipping: '$this_cfg'\n" );
            next;
        }

        $smoker->ttylog( join "\n",
                              "", "Configuration: $this_cfg", "-" x 78, "" );
        $smoker->smoke( $this_cfg, $Policy );
    }

    $smoker->ttylog( "Finished smoking $patch->[0] $patch->[1] $patch->[2]\n" );
    $smoker->mark_out;

    close $log or $self->log_warn("Error on closing logfile: $!");
}

=head2 $smoker->check_for_harness3()

Determine the version of L<Test::Harness> shipped with this perl and set
B<hasharness3> accordingly.

=cut

sub check_for_harness3 {
    my $self = shift;

    my $chk = Test::Smoke::Util::Execute->new(
        command => $^X,
        verbose => $self->option('verbose')
    );
    my $version = $chk->run(
        sprintf('-I"%s/lib"', $self->option('ddir')),
        "-MTest::Harness",
        "-e",
        'print Test::Harness->VERSION'
    );
    $self->log_info("Found: Test::Harness version %s.", $version);

    return $self->{_hasharness3} = $version >= 3;
}

=head2 $smoker->create_buildcfg()

Returns an appropriate L<Test::Smoke::BuildCFG> instance.

=cut

sub create_buildcfg {
    my $self = shift;

    my @df_buildopts = @_ ? grep /^-[DUA]/ => @_ : ();
    # We *always* want -Dusedevel!
    push @df_buildopts, '-Dusedevel'
        unless grep /^-Dusedevel$/ => @df_buildopts;

    Test::Smoke::BuildCFG->config(dfopts => join(" ", @df_buildopts));

    my $patch = Test::Smoke::Util::get_patch($self->option('ddir'));

    $self->check_for_harness3();

    my $logfile = catfile($self->option('ddir'), $self->option('outfile'));

    if ($self->option('continue')) {
        return Test::Smoke::BuildCFG->continue(
            $logfile,
            $self->option('cfg'),
            v => $self->option('verbose')
        );
    }
    return Test::Smoke::BuildCFG->new(
        $self->option('cfg'),
        v => $self->option('verbose')
    );
}

=head2 $smoker->do_manifest_check()

Calls Test::Smoke::SourceTree->check_MANIFEST().

=cut

sub do_manifest_check {
    my $self = shift;

    my $tree = Test::Smoke::SourceTree->new($self->option('ddir'));

    my $mani_check = $tree->check_MANIFEST(
        $self->option('outfile'),
        $self->option('rptfile'),
        'patchlevel.bak',
    );
    foreach my $file ( sort keys %$mani_check ) {
        if ( $mani_check->{ $file } == ST_MISSING ) {
            $self->smoker->log("MANIFEST declared '$file' but it is missing\n");
        }
        elsif ( $mani_check->{ $file } == ST_UNDECLARED ) {
            $self->smoker->log( "MANIFEST did not declare '$file'\n" );
        }
    }
}

=head2 $smoker->add_smoke_patchlevel()

Calls L<Test::Smoke::Util::set_local_patch()> to add a patch-string.

=cut

sub add_smoke_patchlevel {
    my $self = shift;
    my ($patch) = @_;

    my @smokereg = grep
        /^SMOKE[a-fA-F0-9]+$/
    , get_local_patches($self->option('ddir'), $self->option('verbose'));
    if (!@smokereg) {
        $self->log_info("Adding 'SMOKE$patch' to the registered patches.");
        set_local_patch($self->option('ddir'), "SMOKE$patch");
    }
}

1;

=head1 COPYRIGHT

(c) 2002-2013, Abe Timmerman <abeltje@cpan.org> All rights reserved.

With contributions from Jarkko Hietaniemi, Merijn Brand, Campo
Weijerman, Alan Burlison, Allen Smith, Alain Barbet, Dominic Dunlop,
Rich Rauenzahn, David Cantrell.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See:

=over 4

=item * L<http://www.perl.com/perl/misc/Artistic.html>

=item * L<http://www.gnu.org/copyleft/gpl.html>

=back

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=cut
