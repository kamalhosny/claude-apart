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
    return 1 if $sub =~ /\A(?:set|set-fields|set-profile|add-profile|remove-profile)\z/ && session_no_write();
    if ($sub eq 'add-profile') {
        return usage() unless @a >= 1;
        my ($name, @kv) = @a;
        my %f;
        for my $kv (@kv) { $kv =~ /\A(\w+)=(.*)\z/ or return usage(); $f{$1} = $2 }
        my $cfg = -e $path ? ClaudeApart::Config::load($path) : ClaudeApart::Config::empty();
        ClaudeApart::Config::add_profile($cfg, $name, %f);
        ClaudeApart::Config::save($cfg, $path);
        return 0;
    }
    my $cfg = ClaudeApart::Config::load($path);
    if ($sub eq 'profiles') {
        # R63: inside a session only the session's own profile is listed
        print "$_\n" for session_visible($cfg, ClaudeApart::Config::profile_names($cfg));
    } elsif ($sub eq 'default') {
        my $d = ClaudeApart::Config::default_profile($cfg);
        print "$d\n" if defined $d;
    } elsif ($sub eq 'shell') {
        return usage() unless @a == 1;
        session_allow($cfg, $a[0]) or return 1;
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
    } elsif ($sub eq 'owned') {
        return usage() unless @a == 1;
        session_allow($cfg, $a[0]) or return 1;
        print "$_\n" for ClaudeApart::Config::owned_paths($cfg, $a[0]);
    } elsif ($sub eq 'set-fields') {
        return usage() unless @a;
        my @specs;
        for my $s (@a) { $s =~ /\A([a-z][a-z0-9-]*)\.(\w+)=(.*)\z/ or return usage(); push @specs, [$1, $2, $3] }
        ClaudeApart::Config::set_fields($cfg, @specs);
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

# R63: inside a Claude session these commands show only the session's own profile.
sub in_session { return (($ENV{CLAUDE_CODE_CHILD_SESSION} || "") eq "1") ? 1 : 0 }

sub session_allow {
    my ($cfg, $name) = @_;
    return 1 unless in_session();
    my $own = session_profile($cfg);
    return 1 if defined $own && $own eq $name;
    print STDERR "claude-apart: inside Claude only this session's own profile can be read.\n";
    return 0;
}

# R65: nothing that writes the config or a profile's settings runs inside a session.
sub session_no_write {
    return 0 unless in_session();
    print STDERR "claude-apart: this changes profile setup, so it cannot run inside Claude.\n";
    return 1;
}

sub session_visible {
    my ($cfg, @names) = @_;
    return @names unless in_session();
    my $own = session_profile($cfg);
    return grep { defined $own && $_ eq $own } @names;
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
    session_allow(ClaudeApart::Config::load(ClaudeApart::Config::config_path()), $a[0]) or return 1;
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
    return 1 if session_no_write();
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

# identity-read <name>: the account the profile is logged in to: email, org
# uuid and org name, one per line. rc 3 when there is none.
sub cmd_identity_read {
    my (@a) = @_;
    return usage() unless @a == 1;
    session_allow(ClaudeApart::Config::load(ClaudeApart::Config::config_path()), $a[0]) or return 1;
    my $id = ClaudeApart::Identity::read($a[0]);
    return 3 unless $id;
    print "$id->{email}\n$id->{org}\n$id->{org_name}\n";
    return 0;
}

# identity-dup <name> <email> <org>: prints the name of ANOTHER profile whose
# recorded identity (email and org) is this one; rc 0 when found, 1 if not.
sub cmd_identity_dup {
    my (@a) = @_;
    return usage() unless @a == 3;
    # R63: a yes/no answer for a guessed account is a leak, so never inside a session
    if (in_session()) { print STDERR "claude-apart: not available inside Claude.\n"; return 1 }
    my ($name, $email, $org) = @a;
    my $cfg = ClaudeApart::Config::load(ClaudeApart::Config::config_path());
    for my $n (ClaudeApart::Config::profile_names($cfg)) {
        next if $n eq $name;
        my $p = ClaudeApart::Config::profile($cfg, $n);
        next unless length $p->{email} && length $p->{org};
        if (lc $p->{email} eq lc $email && $p->{org} eq $org) { print "$n\n"; return 0 }
    }
    return 1;
}

# status: one line per profile. Inside a session only the session's own profile.
sub cmd_status {
    my (@a) = @_;
    return usage() if @a;
    my $cfg = ClaudeApart::Config::load(ClaudeApart::Config::config_path());
    my @names = ClaudeApart::Config::profile_names($cfg);
    if (($ENV{CLAUDE_CODE_CHILD_SESSION} || "") eq "1") {
        my $own = session_profile($cfg);
        unless (defined $own) { print STDERR "claude-apart: cannot tell which profile this session uses.\n"; return 6 }
        @names = ($own);
    }
    for my $n (@names) {
        my $p = ClaudeApart::Config::profile($cfg, $n);
        my $id = ClaudeApart::Identity::read($n);
        my $st = "$p->{abs_dir}/.claude-apart-state.json";
        my $guard = 0;
        if (open my $fh, "<", $st) {
            local $/;
            require JSON::PP;
            my $d = eval { JSON::PP->new->utf8->decode(scalar <$fh>) };
            $guard = 1 if ref $d eq "HASH" && ref $d->{hooks} eq "HASH" && defined $d->{hooks}{PreToolUse};
        }
        printf "%s %s %s  %s  %s  %s  %s  guard:%s\n",
            length $p->{emoji} ? $p->{emoji} : "-", $p->{tag}, $n, $p->{dir},
            length $p->{email} ? $p->{email} : "-",
            $id ? $id->{email} : "not logged in",
            @{ $p->{can_read} } ? join(",", @{ $p->{can_read} }) : "-",
            $guard ? "yes" : "no";
    }
    return 0;
}

# profile-remove <name>: writes the config WITHOUT the profile first (and drops
# grants for it), then cleans the profile's settings using the old config. If
# that cleanup fails the config is already changed: rc 3, and the leftover hooks
# name an unknown profile, so they fail closed.
sub cmd_profile_remove {
    my (@a) = @_;
    return usage() unless @a == 1;
    return 1 if session_no_write();
    my $path = ClaudeApart::Config::config_path();
    my $old = ClaudeApart::Config::load($path);
    die "unknown profile: $a[0]\n" unless ClaudeApart::Config::profile($old, $a[0]);
    my $cfg = ClaudeApart::Config::load($path);
    ClaudeApart::Config::remove_profile($cfg, $a[0]);
    ClaudeApart::Config::save($cfg, $path);
    require ClaudeApart::Settings;
    unless (eval { ClaudeApart::Settings::uninstall($old, $a[0]); 1 }) {
        my $e = $@; $e =~ s/ at \S+ line \d+\.?\n?\z//; chomp $e;
        print STDERR "claude-apart: could not clean the settings of $a[0]: $e\n";
        return 3;
    }
    return 0;
}

# path-rel <A> <B> (absolute paths): same | inside (A in B) | contains (A holds
# B) | none. Symlinks, ".." and letter case on macOS are handled by the guard's
# path code (device + inode).
sub cmd_path_rel {
    my (@a) = @_;
    return usage() unless @a == 2 && $a[0] =~ m{^/} && $a[1] =~ m{^/};
    require ClaudeApart::Paths;
    my $in = ClaudeApart::Paths::under($a[0], $a[1]);
    my $has = ClaudeApart::Paths::under($a[1], $a[0]);
    print(($in && $has) ? "same\n" : $in ? "inside\n" : $has ? "contains\n" : "none\n");
    return 0;
}

# canon <path>: the path with symlinks resolved.
sub cmd_canon {
    my (@a) = @_;
    return usage() unless @a == 1 && $a[0] =~ m{^/};
    require ClaudeApart::Paths;
    print ClaudeApart::Paths::canon($a[0], '/'), "\n";
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
if ($cmd =~ /\A(?:resolve|identity-check|identity-read|identity-dup|status|profile-remove|path-rel|canon)\z/) {
    my %h = (resolve => \&cmd_resolve, "identity-check" => \&cmd_identity_check, "identity-read" => \&cmd_identity_read,
             "identity-dup" => \&cmd_identity_dup, status => \&cmd_status,
             "profile-remove" => \&cmd_profile_remove, "path-rel" => \&cmd_path_rel, canon => \&cmd_canon);
    $rc = eval { $h{$cmd}->(@ARGV) };
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
