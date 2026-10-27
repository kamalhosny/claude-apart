package ClaudeApart::Settings;
use strict;
use warnings;
use Cwd qw(abs_path);
use Fcntl ();
use File::Basename qw(dirname basename);
use JSON::PP ();
use ClaudeApart::Config;
use ClaudeApart::Paths;

# Writes the guard into a profile's <dir>/settings.json: permission deny rules,
# three hooks and the status line (plus the theme, if the profile sets one).
# <dir>/.claude-apart-state.json records exactly what was added, so uninstall
# can take out only that and put the originals back.
#
# JSON is written with sorted keys and indentation (JSON::PP canonical +
# pretty), so the same content always gives the same bytes. Key order of the
# user's file is not kept. Writes go to <file>.tmp.<pid>, then rename.

my $STATE = '.claude-apart-state.json';
my $BAK   = '.claude-apart.bak';
my @EVENTS = (['PreToolUse', 'pre-tool', 1], ['UserPromptSubmit', 'prompt', 1], ['SessionStart', 'session-start', 0]);

sub _json { return JSON::PP->new->utf8->canonical->pretty }

sub _shq { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'" }

# Where the code lives: lib/ClaudeApart/Settings.pm -> <root>.
sub _root {
    my $f = abs_path(__FILE__);
    return dirname(dirname(dirname($f)));
}

# The perl the hooks run with: /usr/bin/perl when it is there (F12: a perl
# from a version manager, first on PATH, can change or vanish and then every
# hook fails closed), else the first perl on PATH. `sync` re-pins.
our $SYSTEM_PERL = '/usr/bin/perl';
sub _perl {
    return $SYSTEM_PERL if -f $SYSTEM_PERL && -x _;
    for my $d (split /:/, (defined $ENV{PATH} ? $ENV{PATH} : '')) {
        next unless length $d && $d =~ m{^/};
        return "$d/perl" if -f "$d/perl" && -x _;
    }
    return '/usr/bin/perl';
}

# Hint for a state file we cannot read.
sub _state_hint { my $f = shift; return "delete $f and run again (claude-apart then finds its own entries by their command)" }

sub _read_json {
    my ($file, $what, $hint) = @_;
    open my $fh, '<', $file or die "cannot read $file: $!\n";
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $d = eval { _json()->decode($raw) };
    die "$what is not valid JSON ($file); not touching it" . ($hint ? "; $hint" : '') . "\n" unless defined $d;
    die "$what is not a JSON object ($file); not touching it" . ($hint ? "; $hint" : '') . "\n" unless ref $d eq 'HASH';
    return $d;
}

# tmp file + rename. $mode (if given) is set on the tmp file before any data
# goes in; without it the new file is private (0600).
sub _write_atomic {
    my ($file, $bytes, $mode) = @_;
    my $tmp = "$file.tmp.$$";
    # a stale link of that name is removed (unlink does not follow it); O_EXCL still
    # refuses anything that appears in between
    unlink $tmp if -l $tmp;
    sysopen(my $fh, $tmp, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), 0600) or die "cannot write $tmp: $!\n";
    if (defined $mode) { chmod $mode, $tmp or do { unlink $tmp; die "cannot chmod $tmp: $!\n" } }
    print $fh $bytes or do { unlink $tmp; die "write failed: $!\n" };
    close $fh or do { unlink $tmp; die "write failed: $!\n" };
    rename $tmp, $file or do { my $e = $!; unlink $tmp; die "cannot rename to $file: $e\n" };
}

# Settings keep their mode; state and backup files are private (0600).
sub _write_json {
    my ($file, $d, $private) = @_;
    my $mode = $private ? 0600 : (-e $file ? ((stat $file)[2] & 07777) : undef);
    _write_atomic($file, _json()->encode($d), $mode);
}

# Never follow a symlink out of the profile: the path must not be a link and
# must resolve under the profile's own (canonical) folder.
sub _guard_path {
    my ($path, $dir) = @_;
    my $cd = ClaudeApart::Paths::canon($dir);
    my $cp = ClaudeApart::Paths::canon($path);
    return unless -l $path || index($cp, "$cd/") != 0;
    die "$path is a symlink or points outside this profile's folder; replace it with a regular file. Nothing was changed.\n";
}

# Deny rules for one root: bare form and /** form (file roots: bare only).
# A ".*" family gets the bare file and a "<path>.*" glob. Roots whose real path
# differs from the literal one are covered under both spellings. An existing
# path decides file or directory; the name (.json) only when it does not exist.
sub _rules {
    my ($tool, @roots) = @_;
    my (@out, %seen);
    my $add = sub { push @out, $_[0] unless $seen{ $_[0] }++ };
    for my $r (@roots) {
        my $fam = $r =~ s/\.\*\z//;
        my %sp = map { $_ => 1 } ($r, ClaudeApart::Paths::canon($r));
        for my $p (sort keys %sp) {
            $add->("$tool(/$p)");
            if ($fam) { $add->("$tool(/$p.*)") }
            else {
                my $file = -d $p ? 0 : -e $p ? 1 : $p =~ /\.json\z/;
                $add->("$tool(/$p/**)") unless $file;
            }
        }
    }
    return @out;
}

sub _paths {
    my ($cfg, $name) = @_;
    my $p = ClaudeApart::Config::profile($cfg, $name) or die "unknown profile: $name\n";
    my $dir = $p->{abs_dir};
    my ($file, $sfile) = ("$dir/settings.json", "$dir/$STATE");
    _guard_path($_, $dir) for $file, $sfile, "$file$BAK";
    return ($p, $file, $sfile);
}

# Our entries are recognised by their command shape, whatever path or perl.
sub _hook_re {
    my $n = _shq(shift);
    return qr/capart\.pl' hook (?:pre-tool|prompt|session-start) --profile \Q$n\E(?: \|\| exit 2)?\z/;
}

# (1, chain) when the status line is ours, else (0).
sub _status_shape {
    my ($sl, $name) = @_;
    return (0) unless ref $sl eq 'HASH' && defined $sl->{command} && !ref $sl->{command};
    my $n = _shq($name);
    return (0) unless $sl->{command} =~ /capart\.pl' statusline --profile \Q$n\E(?: --chain '((?:[^']|'\\'')*)')?\z/;
    my $c = $1;
    $c =~ s/'\\''/'/g if defined $c;
    return (1, $c);
}

# The status line command of the badge, with the chained command if any.
sub badge_command {
    my ($name, $chain) = @_;
    my $base = join ' ', _shq(_perl()), _shq("-I" . _root() . "/lib"), _shq(_root() . "/libexec/claude-apart/capart.pl");
    return "$base statusline --profile " . _shq($name) . (defined $chain && length $chain ? ' --chain ' . _shq($chain) : '');
}

sub _check_types {
    my ($d, $file) = @_;
    my $bad = sub { die "settings.json: $_[0] has the wrong type ($file); not touching it\n" };
    $bad->('permissions') if exists $d->{permissions} && ref $d->{permissions} ne 'HASH';
    $bad->('permissions.deny') if ref $d->{permissions} eq 'HASH' && exists $d->{permissions}{deny} && ref $d->{permissions}{deny} ne 'ARRAY';
    $bad->('hooks') if exists $d->{hooks} && ref $d->{hooks} ne 'HASH';
    if (ref $d->{hooks} eq 'HASH') {
        for my $ev (sort keys %{ $d->{hooks} }) { $bad->("hooks.$ev") if ref $d->{hooks}{$ev} ne 'ARRAY' }
    }
}

sub _read_state {
    my ($sfile) = @_;
    my $st = _read_json($sfile, 'claude-apart state file', _state_hint($sfile));
    for my $k (qw(deny created)) {
        die "claude-apart state file has the wrong type ($sfile); " . _state_hint($sfile) . "\n"
            if exists $st->{$k} && ref $st->{$k} ne ($k eq 'deny' ? 'ARRAY' : 'HASH');
    }
    return $st;
}

sub install {
    my ($cfg, $name) = @_;
    my ($p, $file, $sfile) = _paths($cfg, $name);
    my $dir = $p->{abs_dir};
    # Read and check everything first: a bad file stops us before any change.
    my $have = -e $file;
    my $d = $have ? _read_json($file, 'settings.json') : {};
    my $st = -e $sfile ? _read_state($sfile) : undef;
    _check_types($d, $file);
    _undo($d, $st, $name);

    my %new = (version => 1, deny => [], hooks => {}, created => {});
    # Deny rules: read-type on the unreadable roots, edit-type on every foreign root.
    my ($read, $write) = ClaudeApart::Config::foreign_paths($cfg, $name);
    my @rules = (_rules('Read', @$read), _rules('Edit', @$write));
    $new{created}{permissions} = 1 unless exists $d->{permissions};
    $new{created}{deny} = 1 unless $d->{permissions} && exists $d->{permissions}{deny};
    my $deny = ($d->{permissions}{deny} ||= []);
    my %has = map { $_ => 1 } grep { !ref $_ } @$deny;
    for my $r (@rules) {
        next if $has{$r}++;
        push @$deny, $r;
        push @{ $new{deny} }, $r;
    }

    # Hooks, one entry per event.
    my ($root, $perl) = (_root(), _perl());
    my $base = join ' ', _shq($perl), _shq("-I$root/lib"), _shq("$root/libexec/claude-apart/capart.pl");
    for my $e (@EVENTS) {
        my ($ev, $sub, $closed) = @$e;
        my $cmd = "$base hook $sub --profile " . _shq($name) . ($closed ? ' || exit 2' : '');
        push @{ $d->{hooks}{$ev} }, { matcher => '*', hooks => [ { type => 'command', command => $cmd, timeout => 10 } ] };
        $new{hooks}{$ev} = $cmd;
    }

    # Status line: keep the user's own one behind --chain. _undo already put
    # back the original, so anything still ours here is from another profile.
    my $orig = $d->{statusLine};
    my $ours = ref $orig eq 'HASH' && defined $orig->{command} && !ref $orig->{command} && $orig->{command} =~ /capart\.pl' statusline /;
    my $cmd = badge_command($name, ref $orig eq 'HASH' && !$ours && defined $orig->{command} && !ref $orig->{command} && length $orig->{command} ? $orig->{command} : undef);
    $new{statusLine_original} = $ours ? undef : $orig;
    $new{statusLine_set} = { type => 'command', command => $cmd };
    $d->{statusLine} = $new{statusLine_set};

    # Theme.
    if (length $p->{theme}) {
        $new{theme_original} = $d->{theme} if exists $d->{theme};
        $new{theme_set} = $p->{theme};
        $d->{theme} = $p->{theme};
    }

    # Changes start here: backup once, then the state file, then settings (a
    # state that lists too much undoes nothing; too little would leave residue).
    -d $dir or do { require File::Path; File::Path::make_path($dir); -d $dir or die "cannot create $dir: $!\n" };
    if ($have && !-e "$file$BAK") {
        open my $in, '<', $file or die "cannot read $file: $!\n";
        binmode $in; local $/;
        my $raw = <$in>; close $in;
        _write_atomic("$file$BAK", $raw, 0600);
    }
    _write_json($sfile, \%new, 1);
    _write_json($file, $d);
    return 1;
}

# Takes out what we added; $d is changed in place. Hooks and the status line
# are recognised by command shape (so a lost or stale state file still works);
# deny rules and the theme come from the state file only.
sub _undo {
    my ($d, $st, $name) = @_;
    my $deny = ref $d->{permissions} eq 'HASH' && ref $d->{permissions}{deny} eq 'ARRAY' ? $d->{permissions}{deny} : undef;
    if ($deny && $st) {
        my %gone = map { $_ => 1 } @{ $st->{deny} || [] };
        @$deny = grep { ref $_ || !$gone{$_} } @$deny;
        my $c = $st->{created} || {};
        delete $d->{permissions}{deny} if !@$deny && $c->{deny};
        delete $d->{permissions} if !%{ $d->{permissions} } && $c->{permissions};
    }
    if (ref $d->{hooks} eq 'HASH') {
        my $re = _hook_re($name);
        my $removed = 0;
        for my $ev (keys %{ $d->{hooks} }) {
            my $list = $d->{hooks}{$ev};
            next unless ref $list eq 'ARRAY';
            my ($touched, @keep) = (0);
            for my $g (@$list) {
                if (ref $g eq 'HASH' && ref $g->{hooks} eq 'ARRAY') {
                    my @h = grep { !(ref $_ eq 'HASH' && defined $_->{command} && !ref $_->{command} && $_->{command} =~ $re) } @{ $g->{hooks} };
                    if (@h != @{ $g->{hooks} }) {
                        $touched = 1;
                        next unless @h;
                        $g->{hooks} = \@h;
                    }
                }
                push @keep, $g;
            }
            next unless $touched;
            $removed = 1;
            @$list = @keep;
            delete $d->{hooks}{$ev} unless @$list;
        }
        delete $d->{hooks} if $removed && !%{ $d->{hooks} };
    }
    my ($ours, $chain) = _status_shape($d->{statusLine}, $name);
    if ($ours) {
        my $orig = $st ? $st->{statusLine_original}
                 : defined $chain ? { type => 'command', command => $chain } : undef;
        if (defined $orig) { $d->{statusLine} = $orig } else { delete $d->{statusLine} }
    }
    if ($st && exists $st->{theme_set} && defined $d->{theme} && $d->{theme} eq $st->{theme_set}) {
        if (exists $st->{theme_original}) { $d->{theme} = $st->{theme_original} } else { delete $d->{theme} }
    }
}

# Guarded read-modify-write for `copy`: $cb->($settings, $state_or_undef) edits
# both in place. The same checks as install (no symlinks, nothing outside the
# profile folder, bad JSON stops us). The state file is written first, then
# settings, and only the file that changed.
sub modify {
    my ($cfg, $name, $cb) = @_;
    my ($p, $file, $sfile) = _paths($cfg, $name);
    my $d = -e $file ? _read_json($file, 'settings.json') : {};
    my $st = -e $sfile ? _read_state($sfile) : undef;
    _check_types($d, $file);
    my ($b, $sb) = (_json()->encode($d), $st ? _json()->encode($st) : '');
    $cb->($d, $st);
    _write_json($sfile, $st, 1) if $st && _json()->encode($st) ne $sb;
    _write_json($file, $d) if _json()->encode($d) ne $b;
    return 1;
}

sub uninstall {
    my ($cfg, $name) = @_;
    my ($p, $file, $sfile) = _paths($cfg, $name);
    my $st = -e $sfile ? _read_state($sfile) : undef;
    if (-e $file) {
        # With no state file, only a settings file that parses is cleaned
        # (by command shape); anything else is left alone.
        my $d = $st ? _read_json($file, 'settings.json') : eval { _read_json($file, 'settings.json') };
        if ($d) {
            _check_types($d, $file);
            my $before = _json()->encode($d);
            _undo($d, $st, $name);
            _write_json($file, $d) if _json()->encode($d) ne $before;
        }
    }
    if ($st) { unlink $sfile or die "cannot remove $sfile: $!\n" }
    return 1;
}

1;
