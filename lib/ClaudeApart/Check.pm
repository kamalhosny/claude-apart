package ClaudeApart::Check;
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname basename);
use File::Path ();
use File::Temp ();
use JSON::PP ();
use POSIX ();
use Time::HiRes ();
use ClaudeApart::Config;
use ClaudeApart::Identity;
use ClaudeApart::Settings;

# `claude-apart check`: a self-test of the guard and identity rules, run
# against the live config. It changes nothing: no profile, settings or config
# file is written and herdr is never called. The only thing it creates is one
# scratch folder (for the launcher links and for check (g)), removed on exit,
# also after a failure or a TERM/INT/HUP.
#
# Synthetic hook and wrapper runs get an explicit environment, so the result
# is the same inside a Claude session or a Herdr pane.

my $ROOT = dirname(dirname(dirname(abs_path(__FILE__))));
my $PERL = $^X;
my $CAPART = "$ROOT/libexec/claude-apart/capart.pl";
my $WRAPPER = "$ROOT/libexec/claude-apart/wrapper.sh";
my $MAXLIST = 4;      # failures named per line

my ($TMP, $OWNER, $CHILD, $FAILED);

END {
    kill 'KILL', $CHILD if $CHILD;
    File::Path::remove_tree($TMP) if defined $TMP && $OWNER && $OWNER == $$ && -d $TMP;
}

# Variables that would make a result depend on where check runs.
sub _clean_env {
    my %e = %ENV;
    delete $e{$_} for grep { /^HERDR_/ || /^ANTHROPIC_/ } keys %e;
    delete @e{qw(CLAUDE_CODE_CHILD_SESSION CLAUDECODE CLAUDE_CONFIG_DIR CLAUDE_APART_PROFILE
                 CLAUDE_APART_REAL_CLAUDE CLAUDE_APART_HOOK_BUDGET CLAUDE_CODE_OAUTH_TOKEN
                 CDPATH OLDPWD)};
    return %e;
}

# Runs @cmd with exactly %$env as its environment and $stdin on stdin.
# Returns (exit code, stdout and stderr together). 20 s limit.
sub _run {
    my ($env, $stdin, @cmd) = @_;
    my ($in, $inf) = File::Temp::tempfile('in.XXXXXX', DIR => $TMP);
    print {$in} $stdin if defined $stdin;
    close $in;
    my $outf = "$inf.out";
    my $pid = fork;
    return (255, "cannot fork") unless defined $pid;
    if (!$pid) {
        open STDIN, '<', $inf or POSIX::_exit(127);
        open STDOUT, '>', $outf or POSIX::_exit(127);
        open STDERR, '>&', \*STDOUT or POSIX::_exit(127);
        %ENV = %$env;
        no warnings 'exec';
        exec { $cmd[0] } @cmd;
        POSIX::_exit(127);
    }
    $CHILD = $pid;
    my ($timed, $st) = (0);
    my $until = Time::HiRes::time() + 20;    # polling, no timer signal
    while (1) {
        my $got = waitpid($pid, POSIX::WNOHANG());
        if ($got == $pid) { $st = $?; last }
        if ($got < 0) { $st = 255 << 8; last }
        if (Time::HiRes::time() > $until) { $timed = 1; kill('KILL', $pid); waitpid($pid, 0); $st = $?; last }
        Time::HiRes::sleep(0.01);
    }
    $CHILD = undef;
    my $out = '';
    if (open my $fh, '<', $outf) { local $/; $out = <$fh>; close $fh }
    unlink $inf, $outf;
    return (255, "timed out") if $timed;
    return (($st & 127) ? 128 + ($st & 127) : $st >> 8, defined $out ? $out : '');
}

sub _hook {
    my ($home_env, $profile, $event, $payload) = @_;
    return _run({ $home_env ? %$home_env : _clean_env() }, JSON::PP->new->utf8->encode($payload),
                $PERL, "-I$ROOT/lib", $CAPART, 'hook', $event, '--profile', $profile);
}

sub _pre {
    my ($profile, $cwd, $tool, $input) = @_;
    return _hook(undef, $profile, 'pre-tool',
        { hook_event_name => 'PreToolUse', cwd => $cwd, tool_name => $tool, tool_input => $input });
}

# A real block: rc 2 with the guard's block text. A crash also gives rc 2, with
# the guard-error text, and must not count.
sub _blocked { my ($rc, $out) = @_; return $rc == 2 && index($out, 'this touches another profile') >= 0 }

# Shell spellings of a path for the probe commands.
sub _sq { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'" }
sub _dq { my $s = shift; $s =~ s/([\\"\$`])/\\$1/g; return $s }    # inside "..."
sub _bs { my $s = shift; $s =~ s/([^\w.\/\-])/\\$1/g; return $s }  # unquoted

# Where Claude Code reads managed settings from. CLAUDE_APART_TEST_MANAGED_SETTINGS
# replaces the path; it is for tests only.
sub _managed_file {
    my $t = $ENV{CLAUDE_APART_TEST_MANAGED_SETTINGS};
    return $t if defined $t && length $t;
    return $^O eq 'darwin' ? '/Library/Application Support/ClaudeCode/managed-settings.json' : '/etc/claude-code/managed-settings.json';
}

my %INSTALLED;    # profile -> { event -> installed command }, filled by check (a)
my ($SCRATCH_EMAIL, $SCRATCH_ORG) = ('user@example.invalid', 'example');    # F15: check (g) identities

sub _say {
    my ($ok, $profile, $text) = @_;
    $FAILED = 1 unless $ok;
    binmode STDOUT, ':utf8';
    print +($ok ? "\x{2713}" : "\x{2717}") . " $profile: $text\n";
}

# One line: ok, or the first few failures named.
sub _report {
    my ($profile, $okmsg, $failmsg, @fails) = @_;
    return _say(1, $profile, $okmsg) unless @fails;
    my @show = @fails > $MAXLIST ? (@fails[0 .. $MAXLIST - 1], (@fails - $MAXLIST) . ' more') : @fails;
    _say(0, $profile, "$failmsg: " . join('; ', @show));
}

# A root as listed by foreign_paths -> (bare path, is it a file/family?).
sub _target {
    my ($r) = @_;
    my $fam = $r =~ s/\.\*\z//;
    my $file = $fam || (-e $r && !-d $r) || $r =~ /\.json\z/;
    return ($r, $file ? 1 : 0);
}

sub _read_json {
    my ($f) = @_;
    open my $fh, '<', $f or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $d = eval { JSON::PP->new->utf8->decode($raw) };
    return ref $d eq 'HASH' ? $d : undef;
}

# (a) the settings hold what the state file says was installed, and the deny
# rules the current config asks for.
sub _check_settings {
    my ($cfg, $name, $p, $read, $write) = @_;
    my $dir = $p->{abs_dir};
    my $d = _read_json("$dir/settings.json");
    my $st = _read_json("$dir/.claude-apart-state.json");
    return _say(0, $name, 'settings or state file missing or unreadable; run: claude-apart sync')
        unless $d && $st;
    my @bad;
    my %deny = map { $_ => 1 } grep { !ref $_ } @{ ref $d->{permissions} eq 'HASH' && ref $d->{permissions}{deny} eq 'ARRAY' ? $d->{permissions}{deny} : [] };
    my @want = (ClaudeApart::Settings::_rules('Read', @$read), ClaudeApart::Settings::_rules('Edit', @$write));
    my @gone = grep { !$deny{$_} } @want;
    push @bad, scalar(@gone) . ' deny rule(s) missing (' . $gone[0] . ')' if @gone;
    for my $ev (qw(PreToolUse UserPromptSubmit SessionStart)) {
        my $cmd = ref $st->{hooks} eq 'HASH' ? $st->{hooks}{$ev} : undef;
        my $has = 0;
        if (defined $cmd && ref $d->{hooks} eq 'HASH' && ref $d->{hooks}{$ev} eq 'ARRAY') {
            # the whole entry as install writes it, not only the command
            for my $e (@{ $d->{hooks}{$ev} }) {
                next unless ref $e eq 'HASH' && ref $e->{hooks} eq 'ARRAY' && defined $e->{matcher} && $e->{matcher} eq '*';
                for my $h (@{ $e->{hooks} }) {
                    next unless ref $h eq 'HASH' && defined $h->{command} && $h->{command} eq $cmd;
                    next unless defined $h->{type} && $h->{type} eq 'command' && defined $h->{timeout} && $h->{timeout} eq '10';
                    $has = 1;
                    $INSTALLED{$name}{$ev} = $cmd;
                }
            }
        }
        push @bad, "$ev hook missing, disabled or changed" unless $has;
    }
    my $sl = ref $st->{statusLine_set} eq 'HASH' ? $st->{statusLine_set}{command} : undef;
    push @bad, 'status line changed'
        unless defined $sl && ref $d->{statusLine} eq 'HASH' && defined $d->{statusLine}{command} && $d->{statusLine}{command} eq $sl;
    for my $k (qw(disableAllHooks allowManagedHooksOnly)) {
        push @bad, "$k is on in settings.json" if $d->{$k};
    }
    my $m = _read_json(_managed_file());
    for my $k (qw(disableAllHooks allowManagedHooksOnly)) {
        push @bad, "$k is on in the managed settings" if $m && $m->{$k};
    }
    push @bad, 'theme changed' if length $p->{theme} && (!defined $d->{theme} || $d->{theme} ne $p->{theme});
    _report($name, 'settings hold the guard entries', 'settings differ from the installed state (run: claude-apart sync)', @bad);
}

# (b) read-denied roots: every synthetic read is blocked (rc 2).
sub _check_reads {
    my ($name, $read) = @_;
    my $home = $ENV{HOME};
    my (@fails, $n);
    $n = 0;
    for my $r (@$read) {
        my ($root, $file) = _target($r);
        my $x = $file ? $root : "$root/x";
        my @probes = (
            ['Read', { file_path => $x }, $home, 'Read'],
            ['Bash', { command => 'cat ' . _sq($x) }, $home, 'cat'],
            ['Bash', { command => 'grep -r x ' . _sq($root) }, $home, 'grep -r'],
            ['Bash', { command => 'ls ' . _sq($root) }, $home, 'ls'],
            ['Bash', { command => "python3 -c \"print(open('$x').read())\"" }, $home, 'python3 open()'],
        );
        if (index($x, "$home/") == 0) {
            my $rel = substr($x, length($home) + 1);
            my $q = _dq($rel);
            push @probes, ['Bash', { command => "cat \"\$HOME/$q\"" }, '/', '$HOME spelling'],
                          ['Bash', { command => "cat \"\${HOME}/$q\"" }, '/', '${HOME} spelling'],
                          ['Bash', { command => 'cat ~/' . _bs($rel) }, '/', '~ spelling'];
        }
        push @probes, ['Bash', { command => 'cat ' . _sq(basename($root) . ($file ? '' : '/x')) }, dirname($root), 'relative cat'];
        for my $pr (@probes) {
            $n++;
            my ($rc, $out) = _pre($name, $pr->[2], $pr->[0], $pr->[1]);
            push @fails, "$pr->[3] on $root not blocked (rc $rc)" unless _blocked($rc, $out);
        }
    }
    _report($name, "read probes blocked (" . scalar(@$read) . " roots, $n calls)", 'read probes not blocked', @fails);
}

# (c) write-denied roots: a Write into each is blocked.
sub _check_writes {
    my ($name, $write) = @_;
    my @fails;
    for my $r (@$write) {
        my ($root, $file) = _target($r);
        my ($rc, $out) = _pre($name, $ENV{HOME}, 'Write', { file_path => $file ? $root : "$root/x", content => 'x' });
        push @fails, "Write into $root not blocked (rc $rc)" unless _blocked($rc, $out);
    }
    _report($name, 'writes blocked (' . scalar(@$write) . ' roots)', 'writes not blocked', @fails);
}

# (d) the profile's own folder is readable.
sub _check_own {
    my ($name, $p) = @_;
    my ($rc) = _pre($name, $ENV{HOME}, 'Read', { file_path => "$p->{abs_dir}/x" });
    _say($rc == 0, $name, $rc == 0 ? 'own folder readable' : "own folder not readable (rc $rc)");
}

# The INSTALLED PreToolUse command, run as Claude Code runs it (through sh),
# must block a deny case with the guard's block text. A stale or missing
# command fails here: its `|| exit 2` suffix gives rc 2 but another text.
sub _check_installed {
    my ($name, $read, $write) = @_;
    my $cmd = $INSTALLED{$name} && $INSTALLED{$name}{PreToolUse};
    return _say(0, $name, 'no installed PreToolUse command to run') unless defined $cmd;
    my ($tool, $input);
    if (@$read) { my ($r, $f) = _target($read->[0]); ($tool, $input) = ('Read', { file_path => $f ? $r : "$r/x" }) }
    elsif (@$write) { my ($r, $f) = _target($write->[0]); ($tool, $input) = ('Write', { file_path => $f ? $r : "$r/x", content => 'x' }) }
    else { return _say(1, $name, 'installed PreToolUse command: no deny case to try') }
    my ($rc, $out) = _run({ _clean_env() }, JSON::PP->new->utf8->encode(
        { hook_event_name => 'PreToolUse', cwd => $ENV{HOME}, tool_name => $tool, tool_input => $input }),
        '/bin/sh', '-c', $cmd);
    my $ok = _blocked($rc, $out);
    _say($ok, $name, $ok ? 'installed PreToolUse command blocks a deny case'
        : "installed PreToolUse command does not block a deny case (rc $rc; run: claude-apart sync)");
}

# (e) a session of this profile cannot start another profile's launcher.
sub _check_launchers {
    my ($cfg, $name, $p) = @_;
    my @others = grep { $_ ne $name } ClaudeApart::Config::profile_names($cfg);
    return _say(1, $name, 'no other launchers to refuse') unless @others;
    my (@fails, @ok);
    mkdir "$TMP/links";
    for my $o (@others) {
        symlink $WRAPPER, "$TMP/links/claude-$o";
        my %e = (_clean_env(), CLAUDE_CODE_CHILD_SESSION => 1, CLAUDE_APART_PROFILE => $name,
                 CLAUDE_APART_REAL_CLAUDE => '/usr/bin/false');
        $e{CLAUDE_CONFIG_DIR} = $p->{abs_dir} unless $p->{adopted};
        my ($rc, $out) = _run(\%e, '', "$TMP/links/claude-$o");
        if ($rc != 0 && $out =~ /cannot start another profile/) { push @ok, $o }
        else { push @fails, "claude-$o not refused (rc $rc)" }
    }
    _report($name, 'wrapper refuses other profiles\' launchers', 'wrapper did not refuse', @fails);
}

# (f) the profile's own login matches the recorded identity.
sub _check_identity {
    my ($name) = @_;
    my ($st) = ClaudeApart::Identity::check($name);
    _say($st eq 'ok', $name, $st eq 'ok' ? 'login matches the recorded account' : "login check says $st (run: claude-apart login $name)");
}

# (g) in a scratch HOME with a copy of the profile list: a wrong and a missing
# identity file are refused by the wrapper (the real claude is /usr/bin/false),
# and a wrong or missing one blocks `hook prompt`.
sub _check_scratch {
    my ($cfg) = @_;
    my $home = "$TMP/g/home";
    File::Path::make_path($home);
    my $copy = ClaudeApart::Config::empty();
    $copy->{default} = $cfg->{default};
    my %dir;
    for my $n (ClaudeApart::Config::profile_names($cfg)) {
        my $src = ClaudeApart::Config::profile($cfg, $n);
        my %raw = %{ $cfg->{profiles}{$n} };
        delete $raw{protect};
        $raw{dir} = $dir{$n} = $src->{adopted} ? '~/.claude' : "~/.claude-$n";
        # F15: placeholder identities; the real emails and orgs never reach the scratch files
        @raw{qw(email org)} = ($SCRATCH_EMAIL, $SCRATCH_ORG);
        push @{ $copy->{order} }, $n;
        $copy->{profiles}{$n} = \%raw;
    }
    my $cfgfile = "$home/.config/claude-apart/config";
    my $made = eval { ClaudeApart::Config::save($copy, $cfgfile); 1 };
    unless ($made) { _say(0, 'all', 'scratch config could not be written'); return }
    File::Path::make_path("$TMP/g/prefix", "$TMP/g/links", "$TMP/g/state");
    my %env = (_clean_env(), HOME => $home, XDG_CONFIG_HOME => "$home/.config", XDG_STATE_HOME => "$TMP/g/state",
               CLAUDE_APART_HOME => "$TMP/g/prefix", CLAUDE_APART_REAL_CLAUDE => '/usr/bin/false');
    my $msg = 'not logged in to the account recorded';
    for my $n (ClaudeApart::Config::profile_names($cfg)) {
        my $p = ClaudeApart::Config::profile($cfg, $n);
        my $adopted = $p->{adopted};
        my $abs = $adopted ? "$home/.claude" : "$home/.claude-$n";
        my $idfile = $adopted ? "$home/.claude.json" : "$abs/.claude.json";
        File::Path::make_path($abs);
        symlink $WRAPPER, "$TMP/g/links/claude-$n";
        my @fails;
        my $wrapper = sub { my ($rc, $out) = _run(\%env, '', "$TMP/g/links/claude-$n"); return ($rc != 0 && index($out, $msg) >= 0) };
        my $prompt = sub {
            my ($rc, $out) = _hook(\%env, $n, 'prompt', { hook_event_name => 'UserPromptSubmit', cwd => $home, prompt => 'hi' });
            return $rc == 2 && index($out, $msg) >= 0;
        };
        # the installed UserPromptSubmit command itself, pointed at the scratch HOME
        my $icmd = $INSTALLED{$n} && $INSTALLED{$n}{UserPromptSubmit};
        my $installed = sub {
            return _run(\%env, JSON::PP->new->utf8->encode({ hook_event_name => 'UserPromptSubmit', cwd => $home, prompt => 'hi' }),
                '/bin/sh', '-c', $icmd);
        };
        my $write = sub { open my $fh, '>', $idfile or die "cannot write scratch file\n"; print $fh $_[0]; close $fh };
        # wrong identity
        $write->('{"oauthAccount":{"emailAddress":"wrong@example.com","organizationUuid":"org-wrong"}}');
        push @fails, 'wrong identity not refused by the wrapper' unless $wrapper->();
        push @fails, 'wrong identity not blocked by hook prompt' unless $prompt->();
        if (defined $icmd) {
            my ($rc, $out) = $installed->();
            push @fails, "installed prompt command did not block a wrong identity (rc $rc)" unless $rc == 2 && index($out, $msg) >= 0;
        } else { push @fails, 'no installed prompt command to run' }
        # missing identity
        unlink $idfile;
        push @fails, 'missing identity not refused by the wrapper' unless $wrapper->();
        push @fails, 'missing identity not blocked by hook prompt' unless $prompt->();
        # control: the right (placeholder) identity is not refused
        {
            $write->(JSON::PP->new->utf8->encode({ oauthAccount => { emailAddress => $SCRATCH_EMAIL, organizationUuid => $SCRATCH_ORG } }));
            push @fails, 'matching identity was refused (control)' if $wrapper->();
            push @fails, 'matching identity blocked by hook prompt (control)' if $prompt->();
            if (defined $icmd) {
                my ($rc) = $installed->();
                push @fails, "installed prompt command blocked a matching identity (rc $rc)" unless $rc == 0;
            }
            unlink $idfile;
        }
        _report($n, 'wrong and missing identity refused (scratch copy)', 'identity rules', @fails);
    }
}

# Entry point. Returns the exit code (0 all good, 1 any failure).
sub run {
    my ($base) = @_;
    $base = '/var/tmp' unless defined $base && -d $base;
    $OWNER = $$;
    $SIG{$_} = sub { exit 130 } for qw(INT TERM HUP);
    $TMP = File::Temp::tempdir('capart-check.XXXXXX', DIR => $base);
    $TMP = abs_path($TMP);
    $FAILED = 0;
    my $cfg = ClaudeApart::Config::load(ClaudeApart::Config::config_path());
    for my $name (ClaudeApart::Config::profile_names($cfg)) {
        my $p = ClaudeApart::Config::profile($cfg, $name);
        my ($read, $write) = ClaudeApart::Config::foreign_paths($cfg, $name);
        _check_settings($cfg, $name, $p, $read, $write);
        _check_installed($name, $read, $write);
        _check_reads($name, $read);
        _check_writes($name, $write);
        _check_own($name, $p);
        _check_launchers($cfg, $name, $p);
        _check_identity($name);
    }
    _check_scratch($cfg);
    return $FAILED ? 1 : 0;
}

1;
