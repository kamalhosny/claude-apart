#!/usr/bin/env perl
# Hook supervisor. This runs first, before anything else is compiled.
# Claude Code treats a hook that times out (or exits with any code but 2) as
# ALLOW, and Perl delays signals while a long C call (a big glob) runs, so the
# hook forks: the child does the work; this parent only waits, with an alarm.
# At the budget it kills the child and blocks. Any child exit other than 0 or
# 2 (die, crash, signal) also blocks. A SIGALRM arriving early blocks too.
# The budget is 5 s. CLAUDE_APART_HOOK_BUDGET (tests) may lower it, but it is
# kept within 0.05..5 s: below 1 µs Time::HiRes::alarm would set no timer at
# all. A value that is not a plain number is ignored.
# This alarm is the only one in the hook processes.
# The child starts its own process group, so a kill at the budget also stops
# what it started (herdr lookups). If the group kill fails (the child had no
# time to make its group yet), the child itself is killed.
BEGIN {
    if (@ARGV && $ARGV[0] eq 'hook') {
        my $fail = sub { syswrite STDERR, "claude-apart: guard error \xe2\x80\x94 blocked to be safe.\n"; CORE::exit(2) };
        $SIG{ALRM} = $fail;
        my $budget = 5;
        my $want = $ENV{CLAUDE_APART_HOOK_BUDGET};
        if (defined $want && $want =~ /\A[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/) {
            $budget = $want < 0.05 ? 0.05 : $want > 5 ? 5 : $want + 0;
        }
        my $pid = fork;
        $fail->() unless defined $pid;
        setpgrp(0, 0) unless $pid;
        if ($pid) {
            require Time::HiRes;
            $SIG{ALRM} = sub { kill('KILL', -$pid) or kill('KILL', $pid); $fail->() };
            Time::HiRes::alarm($budget);
            my $got = waitpid($pid, 0);
            my $st = $?;
            Time::HiRes::alarm(0);
            $fail->() unless $got == $pid;
            my $code = ($st & 127) ? -1 : ($st >> 8);
            CORE::exit($code) if $code == 0 || $code == 2;
            $fail->();
        }
    }
}
use strict;
use warnings;
use FindBin ();
use lib "$FindBin::Bin/../../lib";
use ClaudeApart::Config;
use ClaudeApart::Identity;
use ClaudeApart::Herdr;

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
            TMPDIR => ClaudeApart::Config::tmp_dir($p->{name}),
        );
        print "CA_$_=" . ($_ eq "ADOPTED" ? $v{$_} : shq($v{$_})) . "\n" for qw(NAME DIR ADOPTED TAG EMOJI COLOUR EMAIL ORG CAN_READ THEME TMPDIR);
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

sub session_profile {
    my ($cfg) = @_;
    my $env = $ENV{CLAUDE_APART_PROFILE};
    my $own = session_dir_profile($cfg);
    return undef unless defined $own;
    return undef if defined $env && length $env && $env ne $own;
    return $own;
}

sub session_dir_profile {
    my ($cfg) = @_;
    my $cd = $ENV{CLAUDE_CONFIG_DIR};
    if (defined $cd && length $cd) {
        $cd =~ s{(?<=.)/+\z}{};
        for my $n (ClaudeApart::Config::profile_names($cfg)) {
            my $p = ClaudeApart::Config::profile($cfg, $n);
            return $n if !$p->{adopted} && $p->{abs_dir} eq $cd;
        }
        return undef;
    }
    for my $n (ClaudeApart::Config::profile_names($cfg)) {
        return $n if ClaudeApart::Config::profile($cfg, $n)->{adopted};
    }
    return undef;
}

# rc 0 = name printed, 5 = refused (inside a session), 6 = nothing resolvable,
# 7 = inside Herdr, the workspace label could not be read (R52)
sub cmd_resolve {
    my (@a) = @_;
    my $explicit;
    while (@a) {
        my $f = shift @a;
        if ($f eq "--explicit" && @a) { $explicit = shift @a } else { return usage() }
    }
    my $cfg = ClaudeApart::Config::load(ClaudeApart::Config::config_path());
    die "unknown profile: $explicit\n" if defined $explicit && !ClaudeApart::Config::profile($cfg, $explicit);
    my $pick;
    if (($ENV{CLAUDE_CODE_CHILD_SESSION} || "") eq "1") {
        my $own = session_profile($cfg);
        unless (defined $own) { print STDERR "claude-apart: cannot tell which profile this session uses.\n"; return 6 }
        if (defined $explicit && $explicit ne $own) {
            print STDERR "claude-apart: cannot start another profile from inside a session.\n";
            return 5;
        }
        $pick = $own;
    } elsif (defined $explicit) {
        $pick = $explicit;
    } elsif (defined $ENV{CLAUDE_APART_PROFILE} && length $ENV{CLAUDE_APART_PROFILE}) {
        $pick = $ENV{CLAUDE_APART_PROFILE};
        unless (ClaudeApart::Config::profile($cfg, $pick)) { print STDERR "claude-apart: unknown profile in CLAUDE_APART_PROFILE.\n"; return 6 }
    } else {
        if (($ENV{HERDR_ENV} || "") eq "1" && length($ENV{HERDR_WORKSPACE_ID} || "")) {
            # R52: a failed lookup refuses; a label with no profile means the default.
            my $label = ClaudeApart::Herdr::workspace_label($ENV{HERDR_WORKSPACE_ID});
            unless (defined $label) {
                print STDERR "claude-apart: could not read this Herdr workspace's label; start a profile explicitly with claude-<name>.\n";
                return 7;
            }
            $pick = ClaudeApart::Herdr::profile_for_label($cfg, $label);
        }
        $pick = ClaudeApart::Config::default_profile($cfg) unless defined $pick;
        unless (defined $pick) { print STDERR "claude-apart: no profile to use (set a default).\n"; return 6 }
    }
    print "$pick\n";
    return 0;
}

sub cmd_identity_check {
    my (@a) = @_;
    return usage() unless @a == 1;
    my ($st, $email) = ClaudeApart::Identity::check($a[0]);
    print "$email\n" if length $email;
    return $st eq "ok" ? 0 : $st eq "missing" ? 3 : 4;
}

sub cmd_statusline {
    my (@a) = @_;
    my ($profile, $chain);
    while (@a) {
        my $f = shift @a;
        if ($f eq "--profile" && @a) { $profile = shift @a }
        elsif ($f eq "--chain" && @a) { $chain = shift @a }
        else { return usage() }
    }
    return usage() unless defined $profile;
    my $in = do { local $/; <STDIN> };
    require ClaudeApart::Statusline;
    print ClaudeApart::Statusline::render($profile, $chain, defined $in ? $in : "");
    return 0;
}

sub cmd_settings {
    my ($sub, @a) = @_;
    my $profile;
    return usage() unless defined $sub && ($sub eq 'install' || $sub eq 'uninstall');
    while (@a) {
        my $f = shift @a;
        if ($f eq '--profile' && @a) { $profile = shift @a } else { return usage() }
    }
    return usage() unless defined $profile;
    require ClaudeApart::Settings;
    my $cfg = ClaudeApart::Config::load(ClaudeApart::Config::config_path());
    $sub eq 'install' ? ClaudeApart::Settings::install($cfg, $profile) : ClaudeApart::Settings::uninstall($cfg, $profile);
    print $sub eq "install" ? "installed\n" : "uninstalled\n";
    return 0;
}

# new <name> [label] [--cwd DIR]: opens a Herdr workspace labelled for a profile
# and prints its id. rc 1 on any refusal or herdr failure.
sub cmd_new {
    my (@a) = @_;
    my (@pos, $cwd);
    while (@a) {
        my $f = shift @a;
        if ($f eq "--cwd" && @a) { $cwd = shift @a } elsif ($f !~ /^-/) { push @pos, $f } else { return usage() }
    }
    return usage() unless @pos == 1 || @pos == 2;
    my ($name, $label) = @pos;
    my $cfg = ClaudeApart::Config::load(ClaudeApart::Config::config_path());
    my $p = ClaudeApart::Config::profile($cfg, $name) or die "unknown profile: $name\n";
    # R59: inside a session only the session's own profile.
    if (($ENV{CLAUDE_CODE_CHILD_SESSION} || "") eq "1") {
        my $own = session_profile($cfg);
        unless (defined $own && $own eq $name) {
            print STDERR "claude-apart: inside Claude you can only open a workspace for this session's own profile.\n";
            return 1;
        }
    }
    my $have = (($ENV{HERDR_ENV} || "") eq "1") ? 1 : 0;
    for my $d (split /:/, ($ENV{PATH} || "")) { $have = 1 if length $d && -f "$d/herdr" && -x _ }
    unless ($have) { print STDERR "claude-apart: Herdr is not available (not inside Herdr, and no herdr on PATH).\n"; return 1 }
    require Cwd;
    my $dir = defined $cwd ? Cwd::abs_path($cwd) : Cwd::getcwd();
    die "not a folder: $cwd\n" unless defined $dir && -d $dir;
    my $title = "$p->{emoji} $p->{tag} \xc2\xb7 " . (defined $label && length $label ? $label : $name);
    my $id = ClaudeApart::Herdr::workspace_create($title, $dir);
    unless (defined $id) { print STDERR "claude-apart: Herdr could not open the workspace.\n"; return 1 }
    print "$id\n";
    return 0;
}

my $cmd = shift @ARGV;
unless (defined $cmd) { exit usage() }
if ($cmd eq 'hook') {
    # Hooks fail closed: anything that goes wrong, even loading the code, blocks.
    my $hrc = eval { require ClaudeApart::Hooks; ClaudeApart::Hooks::main(@ARGV) };
    unless (defined $hrc) { print STDERR "claude-apart: guard error \xe2\x80\x94 blocked to be safe.\n"; exit 2 }
    exit $hrc;
}
my $rc;
if ($cmd eq 'config') {
    $rc = eval { cmd_config(@ARGV) };
    if ($@) { my $e = $@; $e =~ s/ at \S+ line \d+\.?\n?\z//; chomp $e; print STDERR "claude-apart: $e\n"; exit 1 }
    exit $rc;
}
if ($cmd eq "resolve" || $cmd eq "identity-check") {
    $rc = eval { $cmd eq "resolve" ? cmd_resolve(@ARGV) : cmd_identity_check(@ARGV) };
    if ($@) { my $e = $@; $e =~ s/ at \S+ line \d+\.?\n?\z//; chomp $e; print STDERR "claude-apart: $e\n"; exit 1 }
    exit $rc;
}
if ($cmd eq "settings") {
    $rc = eval { cmd_settings(@ARGV) };
    if ($@) { my $e = $@; $e =~ s/ at \S+ line \d+\.?\n?\z//; chomp $e; print STDERR "claude-apart: $e\n"; exit 1 }
    exit $rc;
}
if ($cmd eq "new" || $cmd eq "check") {
    $rc = eval {
        if ($cmd eq "new") { cmd_new(@ARGV) }
        else {
            my $base;
            if (@ARGV == 2 && $ARGV[0] eq "--tmp-base") { $base = $ARGV[1] } elsif (@ARGV) { return usage() }
            require ClaudeApart::Check;
            ClaudeApart::Check::run($base);
        }
    };
    if ($@) { my $e = $@; $e =~ s/ at \S+ line \d+\.?\n?\z//; chomp $e; print STDERR "claude-apart: $e\n"; exit 1 }
    exit $rc;
}
if ($cmd eq "statusline") {
    $rc = eval { cmd_statusline(@ARGV) };
    if ($@) { my $e = $@; $e =~ s/ at \S+ line \d+\.?\n?\z//; chomp $e; print STDERR "claude-apart: $e\n"; exit 1 }
    exit $rc;
}
print STDERR "capart.pl: unknown subcommand '$cmd'\n";
exit usage();
