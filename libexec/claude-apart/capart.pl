#!/usr/bin/env perl
use strict;
use warnings;
use FindBin ();
use lib "$FindBin::Bin/../../lib";
use ClaudeApart::Config;

sub usage { print STDERR "usage: capart.pl config <profiles|shell|default|set|set-profile|add-profile|remove-profile> ...\n"; return 2 }

sub shq { my $s = defined $_[0] ? $_[0] : ''; $s =~ s/'/'\\''/g; return "'$s'" }

sub cmd_config {
    my ($sub, @a) = @_;
    return usage() unless defined $sub;
    my $path = ClaudeApart::Config::config_path();
    if ($sub eq 'add-profile') {
        return usage() unless @a == 1;
        my $cfg = -e $path ? ClaudeApart::Config::load($path) : ClaudeApart::Config::empty();
        ClaudeApart::Config::add_profile($cfg, $a[0]);
        ClaudeApart::Config::save($cfg, $path);
        return 0;
    }
    my $cfg = ClaudeApart::Config::load($path);
    if ($sub eq 'profiles') {
        print "$_\n" for ClaudeApart::Config::profile_names($cfg);
    } elsif ($sub eq 'default') {
        my $d = ClaudeApart::Config::default_profile($cfg);
        print "$d\n" if defined $d;
    } elsif ($sub eq 'shell') {
        return usage() unless @a == 1;
        my $p = ClaudeApart::Config::profile($cfg, $a[0]) or die "unknown profile: $a[0]\n";
        my %v = (
            NAME => $p->{name}, DIR => $p->{abs_dir}, ADOPTED => $p->{adopted} ? 1 : 0,
            TAG => $p->{tag}, EMOJI => $p->{emoji}, COLOUR => $p->{colour_code},
            EMAIL => $p->{email}, ORG => $p->{org},
            CAN_READ => join(' ', @{ $p->{can_read} }), THEME => $p->{theme},
        );
        print "CA_$_=" . ($_ eq "ADOPTED" ? $v{$_} : shq($v{$_})) . "\n" for qw(NAME DIR ADOPTED TAG EMOJI COLOUR EMAIL ORG CAN_READ THEME);
    } elsif ($sub eq 'set') {
        return usage() unless @a == 2;
        ClaudeApart::Config::set_top($cfg, $a[0], $a[1]);
        ClaudeApart::Config::save($cfg, $path);
    } elsif ($sub eq 'set-profile') {
        return usage() unless @a == 3;
        ClaudeApart::Config::set_profile($cfg, @a);
        ClaudeApart::Config::save($cfg, $path);
    } elsif ($sub eq 'remove-profile') {
        return usage() unless @a == 1;
        ClaudeApart::Config::remove_profile($cfg, $a[0]);
        ClaudeApart::Config::save($cfg, $path);
    } else {
        return usage();
    }
    return 0;
}

my $cmd = shift @ARGV;
unless (defined $cmd) { exit usage() }
my $rc;
if ($cmd eq 'config') {
    $rc = eval { cmd_config(@ARGV) };
    if ($@) { my $e = $@; $e =~ s/ at \S+ line \d+\.?\n?\z//; chomp $e; print STDERR "claude-apart: $e\n"; exit 1 }
    exit $rc;
}
print STDERR "capart.pl: unknown subcommand '$cmd'\n";
exit usage();
