package ClaudeApart::Settings;
use strict;
use warnings;
use Cwd qw(abs_path);
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

# `command -v perl`, or /usr/bin/perl.
sub _perl {
    for my $d (split /:/, (defined $ENV{PATH} ? $ENV{PATH} : '')) {
        next unless length $d && $d =~ m{^/};
        return "$d/perl" if -f "$d/perl" && -x _;
    }
    return '/usr/bin/perl';
}

sub _read_json {
    my ($file, $what) = @_;
    open my $fh, '<', $file or die "cannot read $file: $!\n";
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $d = eval { _json()->decode($raw) };
    die "$what is not valid JSON ($file); not touching it\n" unless defined $d;
    die "$what is not a JSON object ($file); not touching it\n" unless ref $d eq 'HASH';
    return $d;
}

sub _write_json {
    my ($file, $d) = @_;
    my $target = -l $file ? abs_path($file) : $file;
    $target = $file unless defined $target;
    my $tmp = "$target.tmp.$$";
    open my $fh, '>', $tmp or die "cannot write $tmp: $!\n";
    print $fh _json()->encode($d) or do { unlink $tmp; die "write failed: $!\n" };
    close $fh or do { unlink $tmp; die "write failed: $!\n" };
    rename $tmp, $target or do { my $e = $!; unlink $tmp; die "cannot rename to $target: $e\n" };
}

# Deny rules for one root: bare form and /** form (file roots: bare only).
# A ".*" family gets the bare file and a "<path>.*" glob. Roots whose real path
# differs from the literal one are covered under both spellings.
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
            elsif (!(-f $p || $p =~ /\.json\z/)) { $add->("$tool(/$p/**)") }
        }
    }
    return @out;
}

sub _paths {
    my ($cfg, $name) = @_;
    my $p = ClaudeApart::Config::profile($cfg, $name) or die "unknown profile: $name\n";
    my $dir = $p->{abs_dir};
    return ($p, "$dir/settings.json", "$dir/$STATE");
}

sub _is_ours { my $c = shift; return defined $c && !ref $c && $c =~ /capart\.pl' statusline /; }

sub install {
    my ($cfg, $name) = @_;
    my ($p, $file, $sfile) = _paths($cfg, $name);
    my $dir = $p->{abs_dir};
    # Read everything first: a bad file stops us before any change.
    my $have = -e $file;
    my $d = $have ? _read_json($file, 'settings.json') : {};
    my $st = -e $sfile ? _read_json($sfile, 'claude-apart state file') : undef;
    _undo($d, $st) if $st;
    for my $k (qw(permissions hooks)) {
        die "settings.json: '$k' is not an object ($file); not touching it\n" if exists $d->{$k} && ref $d->{$k} ne 'HASH';
    }
    die "settings.json: permissions.deny is not a list ($file); not touching it\n"
        if $d->{permissions} && exists $d->{permissions}{deny} && ref $d->{permissions}{deny} ne 'ARRAY';
    for my $e (@EVENTS) {
        die "settings.json: hooks.$e->[0] is not a list ($file); not touching it\n"
            if $d->{hooks} && exists $d->{hooks}{ $e->[0] } && ref $d->{hooks}{ $e->[0] } ne 'ARRAY';
    }

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
    $new{created}{hooks} = 1 unless exists $d->{hooks};
    for my $e (@EVENTS) {
        my ($ev, $sub, $closed) = @$e;
        my $cmd = "$base hook $sub --profile " . _shq($name) . ($closed ? ' || exit 2' : '');
        $new{created}{events}{$ev} = 1 unless exists $d->{hooks}{$ev};
        push @{ $d->{hooks}{$ev} }, { matcher => '*', hooks => [ { type => 'command', command => $cmd, timeout => 10 } ] };
        $new{hooks}{$ev} = $cmd;
    }

    # Status line: keep the user's own one behind --chain.
    my $orig = $d->{statusLine};
    my $cmd = "$base statusline --profile " . _shq($name);
    my $ours = ref $orig eq 'HASH' && _is_ours($orig->{command});
    $cmd .= ' --chain ' . _shq($orig->{command})
        if ref $orig eq 'HASH' && !$ours && defined $orig->{command} && !ref $orig->{command} && length $orig->{command};
    $new{statusLine_original} = $ours ? undef : $orig;
    $new{statusLine_set} = { type => 'command', command => $cmd };
    $d->{statusLine} = $new{statusLine_set};

    # Theme.
    if (length $p->{theme}) {
        $new{theme_original} = $d->{theme} if exists $d->{theme};
        $new{theme_set} = $p->{theme};
        $d->{theme} = $p->{theme};
    }

    # Changes start here: backup once, settings, then the state file.
    if ($have && !-e "$file$BAK") {
        open my $in, '<', $file or die "cannot read $file: $!\n";
        binmode $in; local $/;
        my $raw = <$in>; close $in;
        my $tmp = "$file$BAK.tmp.$$";
        open my $out, '>', $tmp or die "cannot write $tmp: $!\n";
        binmode $out;
        print $out $raw; close $out or die "write failed: $!\n";
        rename $tmp, "$file$BAK" or do { my $e = $!; unlink $tmp; die "cannot write backup: $e\n" };
    }
    -d $dir or do { require File::Path; File::Path::make_path($dir); -d $dir or die "cannot create $dir: $!\n" };
    _write_json($file, $d);
    _write_json($sfile, \%new);
    return 1;
}

# Takes out what the state file lists; $d is changed in place.
sub _undo {
    my ($d, $st) = @_;
    my $deny = $d->{permissions} && ref $d->{permissions}{deny} eq 'ARRAY' ? $d->{permissions}{deny} : undef;
    if ($deny) {
        my %gone = map { $_ => 1 } @{ $st->{deny} || [] };
        @$deny = grep { ref $_ || !$gone{$_} } @$deny;
        delete $d->{permissions}{deny} if !@$deny && $st->{created}{deny};
        delete $d->{permissions} if ref $d->{permissions} eq 'HASH' && !%{ $d->{permissions} } && $st->{created}{permissions};
    }
    for my $ev (keys %{ $st->{hooks} || {} }) {
        my $list = $d->{hooks} && ref $d->{hooks}{$ev} eq 'ARRAY' ? $d->{hooks}{$ev} : next;
        my $cmd = $st->{hooks}{$ev};
        @$list = grep {
            my $g = $_;
            !(ref $g eq 'HASH' && ref $g->{hooks} eq 'ARRAY' && @{ $g->{hooks} } == 1
              && ref $g->{hooks}[0] eq 'HASH' && defined $g->{hooks}[0]{command} && $g->{hooks}[0]{command} eq $cmd)
        } @$list;
        delete $d->{hooks}{$ev} if !@$list && $st->{created}{events}{$ev};
    }
    delete $d->{hooks} if ref $d->{hooks} eq 'HASH' && !%{ $d->{hooks} } && $st->{created}{hooks};
    # Status line and theme go back only if they are still the values we wrote.
    my $set = $st->{statusLine_set};
    if ($set && ref $d->{statusLine} eq 'HASH' && defined $d->{statusLine}{command} && $d->{statusLine}{command} eq $set->{command}) {
        if (defined $st->{statusLine_original}) { $d->{statusLine} = $st->{statusLine_original} } else { delete $d->{statusLine} }
    }
    if (exists $st->{theme_set} && defined $d->{theme} && $d->{theme} eq $st->{theme_set}) {
        if (exists $st->{theme_original}) { $d->{theme} = $st->{theme_original} } else { delete $d->{theme} }
    }
}

sub uninstall {
    my ($cfg, $name) = @_;
    my ($p, $file, $sfile) = _paths($cfg, $name);
    return 1 unless -e $sfile;
    my $st = _read_json($sfile, 'claude-apart state file');
    if (-e $file) {
        my $d = _read_json($file, 'settings.json');
        _undo($d, $st);
        _write_json($file, $d);
    }
    unlink $sfile or die "cannot remove $sfile: $!\n";
    return 1;
}

1;
