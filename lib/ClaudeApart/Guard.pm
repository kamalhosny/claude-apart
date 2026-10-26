package ClaudeApart::Guard;
use strict;
use warnings;
use ClaudeApart::Config;
use ClaudeApart::Paths;

# PreToolUse verdicts. verdict() returns undef (allow) or 'block'.
# "read" roots: foreign paths this profile may not read.
# "write" roots: foreign paths this profile may not write (a superset).
# "wonly" roots: write-denied but readable (granted profiles).

my %READ_TOOL  = map { $_ => 1 } qw(Read Grep Glob LS);
my %WRITE_TOOL = map { $_ => 1 } qw(Write Edit MultiEdit NotebookEdit);
my %SHELL_TOOL = map { $_ => 1 } qw(Bash PowerShell);

my %WRITE_WORD = map { $_ => 1 }
    qw(tee cp mv rm rsync ln install touch mkdir rmdir dd truncate chmod chown);
my @RECURSIVE_WORDS = qw(rg ag ack find fd tree du tar zip rsync);
my $MAX_BASES = 512;

# Rules for a shell command, in order. Each gets ($ctx, $sh) and returns true
# to block. Later tasks add rules here.
our @SHELL_RULES = (\&_rule_read_denied, \&_rule_write_denied, \&_rule_recursive_ancestor);

sub verdict {
    my ($cfg, $profile, $tool, $input, $cwd) = @_;
    die "bad tool name\n" unless defined $tool && !ref $tool && length $tool;
    my $ctx = _context($cfg, $profile, $cwd);
    $input = {} unless defined $input;
    return _file_read($ctx, $tool, $input) if $READ_TOOL{$tool};
    return _file_write($ctx, $input) if $WRITE_TOOL{$tool};
    return _shell($ctx, $input) if $SHELL_TOOL{$tool};
    return _other($ctx, $input);
}

sub _context {
    my ($cfg, $profile, $cwd) = @_;
    die "bad cwd\n" unless defined $cwd && !ref $cwd && substr($cwd, 0, 1) eq '/';
    my ($rd, $wd) = ClaudeApart::Config::foreign_paths($cfg, $profile);
    my %r = map { $_ => 1 } @$rd;
    return {
        cwd   => $cwd,
        read  => ClaudeApart::Paths::root_set(@$rd),
        write => ClaudeApart::Paths::root_set(@$wd),
        wonly => ClaudeApart::Paths::root_set(grep { !$r{$_} } @$wd),
    };
}

# A string field of the tool input, or undef. Anything else is an error.
sub _field {
    my ($in, $k) = @_;
    die "tool input is not an object\n" unless ref $in eq 'HASH';
    my $v = $in->{$k};
    return undef unless defined $v;
    die "tool input field $k is not a string\n" if ref $v;
    return length $v ? "$v" : undef;
}

sub _is_absolute {
    my ($p, $cwd) = @_;
    return substr(ClaudeApart::Paths::expand($p, $cwd), 0, 1) eq '/';
}

# ---- file tools -------------------------------------------------------------

sub _file_read {
    my ($ctx, $tool, $in) = @_;
    my $cwd     = $ctx->{cwd};
    my @paths   = grep { defined } map { _field($in, $_) } qw(file_path path);
    my $pattern = _field($in, 'pattern');
    my (@inside, @anc);    # must not be under a root / must not hold a root
    push @inside, ClaudeApart::Paths::spellings($_, $cwd) for @paths;
    my $abs_pattern = defined $pattern && _is_absolute($pattern, $cwd);
    if (defined $pattern && ($abs_pattern || $tool eq 'Glob')) {
        my $base = @paths ? ClaudeApart::Paths::canon($paths[0], $cwd) : $cwd;
        my $full = ClaudeApart::Paths::absolute($pattern, $base);
        push @inside, ClaudeApart::Paths::spellings_abs($full);
        if ($tool eq 'Glob') {
            my @dir = ClaudeApart::Paths::spellings_abs(ClaudeApart::Paths::glob_dir($full));
            push @inside, @dir;
            push @anc, @dir;
        }
    }
    return 'block' if ClaudeApart::Paths::set_holds($ctx->{read}, @inside);
    return undef if $tool eq 'Read';
    # Ancestor rule: Grep/Glob/LS must not search a folder that holds a root.
    if (@paths) {
        push @anc, ClaudeApart::Paths::spellings($_, $cwd) for @paths;
    } elsif (!($tool eq 'Glob' && $abs_pattern)) {
        push @anc, ClaudeApart::Paths::spellings($cwd, '/');
    }
    return ClaudeApart::Paths::set_inside($ctx->{read}, @anc) ? 'block' : undef;
}

sub _file_write {
    my ($ctx, $in) = @_;
    my @s = map { ClaudeApart::Paths::spellings($_, $ctx->{cwd}) }
            grep { defined } map { _field($in, $_) } qw(file_path notebook_path);
    return ClaudeApart::Paths::set_holds($ctx->{write}, @s) ? 'block' : undef;
}

# ---- other tools (MCP, WebFetch, Task, …) -------------------------------------

sub _strings {
    my ($d, $out) = @_;
    if (ref $d eq 'HASH') { for my $k (keys %$d) { push @$out, $k; _strings($d->{$k}, $out) } }
    elsif (ref $d eq 'ARRAY') { _strings($_, $out) for @$d }
    elsif (defined $d && !ref $d) { push @$out, "$d" }
    return $out;
}

sub _other {
    my ($ctx, $in) = @_;
    my @s = grep { length } @{ _strings($in, []) };
    for my $s (@s) { return 'block' if ClaudeApart::Paths::text_hits($ctx->{read}, $s) }
    for my $s (@s) {
        my @p = ClaudeApart::Paths::text_paths($s, [ $ctx->{cwd} ], $ctx->{write});
        return 'block' if ClaudeApart::Paths::set_holds($ctx->{read}, @p);
    }
    return undef;
}

# ---- shell ----------------------------------------------------------------------

sub _shell {
    my ($ctx, $in) = @_;
    my $cmd = _field($in, 'command');
    return undef unless defined $cmd;
    my $sh = _parse_shell($ctx, $cmd);
    for my $rule (@SHELL_RULES) { return 'block' if $rule->($ctx, $sh) }
    return undef;
}

# What the rules need to know about a command.
sub _parse_shell {
    my ($ctx, $cmd) = @_;
    my @words = ClaudeApart::Paths::words($cmd);
    my @names = map { (my $n = $_) =~ s{.*/}{}s; $n } @words;
    my $bases = _bases($ctx->{cwd}, $cmd);
    return {
        text      => $cmd,
        words     => \@words,
        names     => { map { $_ => 1 } @names },
        bases     => $bases,
        spellings => [ ClaudeApart::Paths::text_paths($cmd, $bases, $ctx->{write}) ],
    };
}

# The session cwd plus every cd/pushd target in the command. Each target is
# resolved against the cwd, and against the chain of all earlier targets
# (as if every cd ran). A bare `cd` goes home. Shell words (quotes removed)
# and the plain split (finds cd inside quoted commands) are walked separately.
sub _bases {
    my ($cwd, $cmd) = @_;
    my @bases = ($cwd);
    my @shell = map { $_->[1] ? undef : $_->[0] } ClaudeApart::Paths::shell_words($cmd);
    my @plain = grep { length } split /[ \t\n\r\f\x0b;&|()<>`'"]+/, $cmd;
    for my $stream (\@shell, \@plain) {
        my $chain = $cwd;
        for my $i (0 .. $#$stream) {
            my $w = $stream->[$i];
            next unless defined $w && ($w eq 'cd' || $w eq 'pushd');
            my $j = $i + 1;
            $j++ while $j <= $#$stream && defined $stream->[$j] && $stream->[$j] =~ /^-./;
            my $t = ($j <= $#$stream && defined $stream->[$j]) ? $stream->[$j] : '~';
            next if $t eq '-';
            push @bases, ClaudeApart::Paths::spellings($t, $cwd), ClaudeApart::Paths::spellings($t, $chain);
            $chain = ClaudeApart::Paths::canon($t, $chain);
        }
    }
    my %have;
    @bases = grep { !$have{$_}++ } @bases;
    die "too many cd targets\n" if @bases > $MAX_BASES;
    return \@bases;
}

sub _rule_read_denied {
    my ($ctx, $sh) = @_;
    return 1 if ClaudeApart::Paths::text_hits($ctx->{read}, $sh->{text});
    return ClaudeApart::Paths::set_holds($ctx->{read}, @{ $sh->{spellings} });
}

sub _rule_write_denied {
    my ($ctx, $sh) = @_;
    return 0 unless @{ $ctx->{wonly}{abs} };
    return 0 unless ClaudeApart::Paths::text_hits($ctx->{wonly}, $sh->{text})
        || ClaudeApart::Paths::set_holds($ctx->{wonly}, @{ $sh->{spellings} });
    return _writes($sh);
}

sub _rule_recursive_ancestor {
    my ($ctx, $sh) = @_;
    return 0 unless _recursive($sh);
    return ClaudeApart::Paths::set_inside($ctx->{read}, @{ $sh->{spellings} });
}

# A write-capable construct: a redirection, a writing command, sed/perl -i.
sub _writes {
    my ($sh) = @_;
    return 1 if index($sh->{text}, '>') >= 0;
    my $n = $sh->{names};
    return 1 if grep { $WRITE_WORD{$_} } keys %$n;
    if ($n->{sed} || $n->{perl}) {
        return 1 if grep { /^-[A-Za-z]*i/ || /^--in-place/ } @{ $sh->{words} };
    }
    return 0;
}

# A command that reads a whole tree.
sub _recursive {
    my ($sh) = @_;
    my $n = $sh->{names};
    return 1 if grep { $n->{$_} } @RECURSIVE_WORDS;
    my @short = grep { /^-[^-]/ } @{ $sh->{words} };
    my %long  = map { $_ => 1 } grep { /^--/ } @{ $sh->{words} };
    my $flag  = sub { my ($re) = @_; return scalar grep { $_ =~ $re } @short };
    return 1 if (grep { $n->{$_} } qw(grep egrep fgrep zgrep))
        && ($flag->(qr/[rR]/) || $long{'--recursive'} || $long{'--dereference-recursive'});
    return 1 if $n->{ls} && ($flag->(qr/R/) || $long{'--recursive'});
    return 1 if $n->{cp} && ($flag->(qr/[rRa]/) || $long{'--recursive'} || $long{'--archive'});
    return 1 if $n->{scp} && $flag->(qr/r/);
    return 0;
}

1;
