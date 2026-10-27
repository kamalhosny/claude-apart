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

# Commands allowed on a readable but write-denied root (more checks in _read_only),
# and the variables that may be set in front of them.
my %READ_ONLY = map { $_ => 1 } qw(cat head tail less more grep egrep fgrep zgrep rg ag ls tree
    wc file stat du diff cmp cut tr nl column basename dirname realpath readlink md5 md5sum
    shasum sha256sum echo printf true test [ cd pwd find sort uniq);
my %SAFE_VAR = map { $_ => 1 } qw(LANG LANGUAGE TZ COLUMNS LINES TERM NO_COLOR CLICOLOR CLICOLOR_FORCE);

# Commands that read a whole tree. CWD_DEFAULT ones search the current
# directory when given no path; PATTERN_FIRST ones take a pattern first.
my %ALWAYS_READER = map { $_ => 1 } qw(ugrep rg ag ack find fd tree du tar zip rsync);
my %CWD_DEFAULT   = map { $_ => 1 } qw(grep egrep fgrep zgrep ugrep rg ag ack find fd tree du ls);
my %PATTERN_FIRST = map { $_ => 1 } qw(grep egrep fgrep zgrep ugrep rg ag ack fd);
# Names _is_reader / _is_modifier can accept (a quick filter for _find_cmd).
my %READER_NAME   = map { $_ => 1 } keys %ALWAYS_READER, qw(grep egrep fgrep zgrep ls cp scp);
my %MODIFIER_NAME = map { $_ => 1 } qw(rm chmod chown chgrp xattr find ditto);

# Keys of other tools' inputs whose values are paths (ancestor rule).
my %PATH_KEY = map { $_ => 1 } qw(path paths dir directory root cwd file file_path filepath
    filename folder target source destination);

my $MAX_DEPTH = 3;      # quoted shell code inside quoted shell code …
my $MAX_DIRS  = 64;     # folders a command may cd to
my $CODE      = qr/[ \t\n\r\f\x0b;&|()<>`'"]/;    # a word that may hold shell code

# Rules for a shell command, in order. Each gets ($ctx, $sh) and returns true
# to block. $sh->{segments} holds the simple commands; see _analyse. Later
# tasks add rules here.
our @SHELL_RULES = (\&_rule_read_denied, \&_rule_write_denied, \&_rule_recursive_reader,
                    \&_rule_recursive_modifier);

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

sub _name {    # command name of a word: its last path component
    my ($w) = @_;
    return $w =~ m{([^/]+)\z} ? $1 : undef;
}

# ---- file tools -------------------------------------------------------------

sub _file_read {
    my ($ctx, $tool, $in) = @_;
    my $cwd     = $ctx->{cwd};
    my @paths   = grep { defined } map { _field($in, $_) } qw(file_path path);
    my $pattern = _field($in, 'pattern');
    my $abs_pattern = defined $pattern && _is_absolute($pattern, $cwd);
    for my $p (@paths, ($abs_pattern ? $pattern : ())) {    # cheap check first
        return 'block' if ClaudeApart::Paths::text_hits($ctx->{read}, $p);
    }
    my (@inside, @anc);    # must not be under a root / must not hold a root
    push @inside, ClaudeApart::Paths::spellings($_, $cwd) for @paths;
    if (defined $pattern && ($abs_pattern || $tool eq 'Glob')) {
        my @bases = @paths ? ClaudeApart::Paths::spellings($paths[0], $cwd) : ($cwd);
        for my $b (@bases) {
            my $full = ClaudeApart::Paths::absolute($pattern, $b);
            push @inside, ClaudeApart::Paths::spellings_abs($full);
            next unless $tool eq 'Glob';
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
    my @p = grep { defined } map { _field($in, $_) } qw(file_path notebook_path);
    for my $p (@p) { return 'block' if ClaudeApart::Paths::text_hits($ctx->{write}, $p) }
    my @s = map { ClaudeApart::Paths::spellings($_, $ctx->{cwd}) } @p;
    return ClaudeApart::Paths::set_holds($ctx->{write}, @s) ? 'block' : undef;
}

# ---- other tools (MCP, WebFetch, Task, …) -------------------------------------
# Any mention of a write-denied root blocks (an MCP tool may write), and a
# path-like value must not be a folder that holds a read-denied root.

sub _strings {
    my ($d, $out) = @_;
    if (ref $d eq 'HASH') { for my $k (keys %$d) { push @$out, $k; _strings($d->{$k}, $out) } }
    elsif (ref $d eq 'ARRAY') { _strings($_, $out) for @$d }
    elsif (defined $d && !ref $d) { push @$out, "$d" }
    return $out;
}

sub _path_values {
    my ($d, $out, $key) = @_;
    if (ref $d eq 'HASH') { _path_values($d->{$_}, $out, $_) for keys %$d }
    elsif (ref $d eq 'ARRAY') { _path_values($_, $out, $key) for @$d }
    elsif (defined $d && !ref $d && length $d && defined $key && $PATH_KEY{ lc $key }) { push @$out, "$d" }
    return $out;
}

sub _other {
    my ($ctx, $in) = @_;
    my @s = grep { length } @{ _strings($in, []) };
    for my $s (@s) { return 'block' if ClaudeApart::Paths::text_hits($ctx->{write}, $s) }
    for my $s (@s) {
        my @p = ClaudeApart::Paths::text_paths($s, [ $ctx->{cwd} ], $ctx->{write});
        return 'block' if ClaudeApart::Paths::set_holds($ctx->{write}, @p);
    }
    for my $v (@{ _path_values($in, []) }) {
        (my $p = $v) =~ s{\Afile://}{}i;
        next if index($p, "\0") >= 0;
        my @sp = ClaudeApart::Paths::candidate_spellings($p, [ $ctx->{cwd} ], $ctx->{write});
        if ($p =~ ClaudeApart::Paths::glob_chars()) {    # a glob may search its whole folder
            push @sp, ClaudeApart::Paths::spellings_abs(
                ClaudeApart::Paths::glob_dir(ClaudeApart::Paths::absolute($p, $ctx->{cwd})));
        }
        return 'block' if ClaudeApart::Paths::set_inside($ctx->{read}, @sp);
    }
    return undef;
}

# ---- shell ----------------------------------------------------------------------

sub _shell {
    my ($ctx, $in) = @_;
    my $cmd = _field($in, 'command');
    return undef unless defined $cmd;
    return 'block' if ClaudeApart::Paths::text_hits($ctx->{read}, $cmd);    # before the disk
    my $sh = _analyse($ctx, $cmd);
    for my $rule (@SHELL_RULES) { return 'block' if $rule->($ctx, $sh) }
    return undef;
}

# Splits a command into simple commands ("segments": split at ; & && | ||,
# newlines, ( ) and backticks). Each segment records its words, its redirect
# targets and whether the shell runs it. A quoted word that holds shell code
# (bash -c "…", "$(…)") is analysed one level deeper; its segments count as
# run only for $(…) and backticks. Each word item is
# {w => text, sp => [spellings of its path pieces]}. Relative words are taken
# from every folder in $sh->{dirs}, and from the "missing" folders in
# $sh->{holes} when they climb out of them (see _cd_dirs).
sub _analyse {
    my ($ctx, $cmd) = @_;
    my $sh = { text => $cmd, segments => [], memo => {} };
    @$sh{qw(dirs holes)} = _cd_dirs($ctx, $cmd);
    _walk($ctx, $sh, $cmd, 0, 1);
    $sh->{spellings} = [ ClaudeApart::Paths::uniq(
        map { map { @{ $_->{sp} } } @{ $_->{words} }, @{ $_->{redirects} } } @{ $sh->{segments} }) ];
    return $sh;
}

# Does a word hold shell code to analyse one level deeper? Code nested
# deeper than $MAX_DEPTH cannot be checked, so that is an error (blocks).
sub _nested {
    my ($w, $depth) = @_;
    return 0 unless $w =~ $CODE;
    die "shell code nested too deep\n" if $depth >= $MAX_DEPTH;
    return 1;
}

sub _walk {
    my ($ctx, $sh, $text, $depth, $exec) = @_;
    my ($words, $redirs, $want_target) = ([], [], 0);
    my $end = sub {
        return unless @$words || @$redirs;
        push @{ $sh->{segments} }, {
            exec      => $exec,
            words     => [ map { _item($ctx, $sh, $_, $depth, $exec) } @$words ],
            redirects => [ map { _item($ctx, $sh, $_, $depth, $exec) } @$redirs ],
        };
        ($words, $redirs) = ([], []);
    };
    for my $t (ClaudeApart::Paths::shell_words($text)) {
        my ($w, $op) = @$t;
        unless ($op) {
            if ($want_target) { push @$redirs, $w; $want_target = 0 } else { push @$words, $w }
            next;
        }
        (my $rest = $w) =~ s/&?[<>]+[&|]?//g;
        if (length $rest) { $end->(); $want_target = 0 }
        $want_target = 1 if $rest ne $w && $w !~ /\(/;
    }
    $end->();
}

sub _item {
    my ($ctx, $sh, $w, $depth, $exec) = @_;
    my @sp = map { _piece($ctx, $sh, $_) } ClaudeApart::Paths::word_pieces($w);
    _walk($ctx, $sh, $w, $depth + 1, ($exec && $w =~ /\$\(|`/) ? 1 : 0) if _nested($w, $depth);
    return { w => $w, sp => [ ClaudeApart::Paths::uniq(@sp) ] };
}

# The spellings of one path piece, from every folder of the command.
sub _piece {
    my ($ctx, $sh, $p) = @_;
    my $m = $sh->{memo};
    return @{ $m->{$p} } if $m->{$p};
    my @sp = ClaudeApart::Paths::candidate_spellings($p, $sh->{dirs}, $ctx->{write}, 1);
    my $c = ClaudeApart::Paths::climb_ub($p);
    for my $h (@{ $sh->{holes} }) {
        push @sp, ClaudeApart::Paths::candidate_spellings($p, [ $h->[0] ], $ctx->{write}, 1) if $c >= $h->[1];
    }
    $m->{$p} = [ ClaudeApart::Paths::uniq(@sp) ];
    return @{ $m->{$p} };
}

# R8, union form: the folders a command may run in are the session cwd and
# every cd/pushd/chdir target written anywhere in it (after time, noglob,
# builtin, eval …, in quoted code, heredocs and comments; see _cd_scan).
# There is no order and no "did it run".
#
# Every target is taken from every folder found so far, until nothing new
# turns up. Every spelling of a folder (as written, through each symlink,
# the real path) is a base, because `cd l; cd ../..` climbs from the
# spelling the shell keeps in $PWD. Two spellings count as one base when
# they agree on what the command can reach from them: the same real folder,
# and the same for each of their parents up to $U levels ($U = the most
# ".." any word or target has). A spelling that lies in or holds a root
# (other than its real path) is kept as written.
#
# A folder that does not exist may be made by the command (`mkdir -p a/b &&
# cd a/b`), so it is kept too, but only by what matters: from a missing
# folder, a word reaches something else only by climbing out of the missing
# part. So a missing folder below the existing folder E becomes the
# "holes" E/<hole>, E/<hole>/<hole>, … up to $U levels deep; words and
# targets that climb that far are taken from them. A missing folder that is
# a root, or holds one, is kept as written (up to $U levels below the
# deepest root).
#
# CDPATH (from the environment and from CDPATH=… / cdpath=(…) in the
# command): a relative target is also taken from each entry.
#
# More than $MAX_DIRS real folders is an error.
# Returns ([bases], [[hole, depth], …]).
sub _cd_dirs {
    my ($ctx, $text) = @_;
    my $scan = { targets => [], swaps => [], cdpath => [], climb => 0 };
    _cd_scan($text, 0, $scan);
    my @cwd = ClaudeApart::Paths::spellings($ctx->{cwd}, '/');
    my @t = ClaudeApart::Paths::uniq(@{ $scan->{targets} });
    my @cdpath = ClaudeApart::Paths::uniq(grep { length && $_ ne '.' }
        (defined $ENV{CDPATH} ? split(/:/, $ENV{CDPATH}) : ()), @{ $scan->{cdpath} });
    if (@cdpath) {
        my @rel = grep { !_is_absolute($_, "\x02") } @t;
        @t = ClaudeApart::Paths::uniq(@t, map { my $e = $_; map { "$e/$_" } @rel } @cdpath);
    }
    my %sw;
    my @targets = (@t, grep { !$sw{"$_->[0]\0$_->[1]"}++ } @{ $scan->{swaps} });
    my %climb = map { $_ => ClaudeApart::Paths::climb_ub($_) } @t;
    return (\@cwd, []) unless @targets;

    my $U = $scan->{climb};
    for my $t (@t) { $U = $climb{$t} if $climb{$t} > $U }
    my $set = $ctx->{write};
    my $deep = 0;
    for (@{ $set->{abs} }, @{ $set->{fam} }) { my $d = tr{/}{}; $deep = $d if $d > $deep }

    my (@bases, @holes, @queue, %sig, %part, %canon, %seen, %hole);
    my $base = sub {
        my ($s) = @_;
        return if $sig{ _sig($s, $U, $set, \%part) }++;
        push @bases, $s;
        push @queue, [ $s, 0 ];
        $canon{ ClaudeApart::Paths::canon($s, '/') } = 1;
        die "too many cd directories\n" if keys %canon > $MAX_DIRS;
    };
    my $consider = sub {
        my ($s) = @_;
        return if $seen{$s}++ || index($s, $ClaudeApart::Paths::HOLE) >= 0;
        my ($e, $k) = ClaudeApart::Paths::dir_prefix($s);
        return $base->($s) unless $k;
        my $h = $e eq '/' ? '' : $e;
        for my $j (1 .. $U) {
            $h .= "/$ClaudeApart::Paths::HOLE";
            next if $hole{$h}++;
            push @holes, [ $h, $j ];
            push @queue, [ $h, $j ];
            die "too many missing cd directories\n" if @holes > 8 * $MAX_DIRS;
        }
        $base->($s) if _missing_root($set, $e, $s) && ($s =~ tr{/}{}) <= $deep + $U;
    };
    $base->($_) for @cwd;    # the session cwd counts even when it is missing
    $seen{$_} = 1 for @cwd;
    while (my $q = shift @queue) {
        my ($b, $j) = @$q;
        for my $t (@targets) {
            if (ref $t) { $consider->($_) for $j ? () : _swap($t, $b); next }
            next if $j && $climb{$t} < $j;
            $consider->($_) for ClaudeApart::Paths::candidate_spellings($t, [$b], $set);
        }
    }
    return (\@bases, \@holes);
}

# The signature of a folder spelling (see _cd_dirs): for it and each parent
# up to $U levels, the real path, or the spelling itself when a spelling
# other than the real path lies in or holds a root.
sub _sig {
    my ($s, $U, $set, $memo) = @_;
    my @parts;
    my $p = $s;
    for my $i (0 .. $U) {
        $memo->{$p} //= do {
            my $c = ClaudeApart::Paths::canon($p, '/');
            ClaudeApart::Paths::str_related($set, grep { $_ ne $c } ClaudeApart::Paths::spellings_abs($p))
                ? 'L' . ClaudeApart::Paths::fold($p) : 'C' . ClaudeApart::Paths::fold($c);
        };
        push @parts, $memo->{$p};
        last if $p eq '/';
        $p =~ s{/[^/]*\z}{};
        $p = '/' if $p eq '';
    }
    return join "\0", @parts;
}

# Is the first missing folder of $s (below the existing folder $e) a root,
# or does it hold one?
sub _missing_root {
    my ($set, $e, $s) = @_;
    my ($first) = substr($s, length($e eq '/' ? '' : $e) + 1) =~ m{\A([^/]+)};
    return 0 unless defined $first;
    my $f = ClaudeApart::Paths::fold(($e eq '/' ? '' : $e) . "/$first");
    for my $r (@{ $set->{abs} }) { return 1 if $r eq $f || index($r, "$f/") == 0 }
    for my $r (@{ $set->{fam} }) { return 1 if $r eq $f || index($r, "$f/") == 0 || index($f, "$r.") == 0 }
    return 0;
}

# Finds cd/pushd/chdir words (also glued after "=", as in `c='cd ~'` or
# `alias h='cd ~'`) and CDPATH assignments in a text, at every quoting depth.
# Fills $out: targets (strings), swaps ([old, new] for zsh's `cd old new`),
# cdpath (entries), climb (the most ".." of any word seen).
my $CD_WORD = qr/(?:\A|=)(?:cd|pushd|chdir)\z/;
my $CDPATH_SET = qr/\A(?:CDPATH|cdpath)\+?=/;

sub _cd_scan {
    my ($text, $depth, $out) = @_;
    my @tok = ClaudeApart::Paths::shell_words($text);
    for my $i (0 .. $#tok) {
        my ($w, $op) = @{ $tok[$i] };
        next if $op;
        my $c = ClaudeApart::Paths::climb_ub($w);
        $out->{climb} = $c if $c > $out->{climb};
        _cd_scan($w, $depth + 1, $out) if _nested($w, $depth);
        if ($w =~ $CDPATH_SET) {
            my $v = substr($w, $+[0]);
            if (!length $v && $i < $#tok && $tok[ $i + 1 ][1] && $tok[ $i + 1 ][0] =~ /\A\(/) {    # cdpath=(a b)
                for (my $j = $i + 2; $j <= $#tok && !$tok[$j][1]; $j++) { push @{ $out->{cdpath} }, $tok[$j][0] }
            } else {
                push @{ $out->{cdpath} }, split(/:/, $v);
            }
        }
        next unless $w =~ $CD_WORD;
        my ($args, $bare) = _cd_args(\@tok, $i + 1);
        push @{ $out->{targets} }, '~' if $bare && $w !~ /pushd\z/;    # a bare pushd swaps two old folders
        push @{ $out->{targets} }, map { _cd_forms($_) } @$args;
        push @{ $out->{swaps} }, [ @$args[ 0, 1 ] ] if @$args > 1;
    }
}

# The words after a cd: every word up to a list operator (; & && | ||
# newline ( ) `), without redirections and their targets and without the
# leading options (-L -P -q -e -s -@, --). A `}` word ends them (zsh `{ cd }`).
# $bare: the cd may have no argument at all, so it goes home: no words, a
# first word starting with # (a comment), or only words that may be the fd
# number of a redirection (`cd 2>/dev/null`).
sub _cd_args {
    my ($tok, $j) = @_;
    my (@a, $redir);
    my ($opts, $fd) = (1, 0);
    for (; $j < @$tok; $j++) {
        my ($x, $op) = @{ $tok->[$j] };
        if ($op) {
            (my $rest = $x) =~ s/&?[<>]+[&|]?//g;
            last if length $rest;
            $fd++ if @a && $tok->[ $j - 1 ][1] == 0 && $a[-1] eq $tok->[ $j - 1 ][0] && $a[-1] =~ /\A(?:[0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\})\z/;
            $redir = 1;
            next;
        }
        if ($redir) { $redir = 0; next }
        next unless length $x;
        last if $x eq '}';
        if ($opts) {
            if ($x eq '--') { $opts = 0; next }
            next if $x =~ /\A-[LPqes@]+\z/;
            $opts = 0;
        }
        push @a, $x;
    }
    my $bare = !@a || $a[0] =~ /\A#/ || $fd >= @a;
    return (\@a, $bare);
}

# The targets one cd argument stands for. `-` is $OLDPWD; ~+, ~-, $PWD and
# $OLDPWD followed by a rest stand for that rest taken from every folder
# (and ~-/$OLDPWD also from $OLDPWD of the environment). Dir stack entries
# (+N, -N), backticks and unknown variables add nothing: they go back to
# folders already counted.
sub _cd_forms {
    my ($x) = @_;
    my $old = $ENV{OLDPWD};
    $old = undef unless defined $old && substr($old, 0, 1) eq '/';
    if ($x eq '-') { return defined $old ? ($old) : () }
    return () if $x =~ /\A[-+][0-9]+\z/ || index($x, '`') >= 0;
    my $rest = ClaudeApart::Paths::prefix_rest($x);
    if (defined $rest) {
        my @f = $rest eq '.' ? () : ($rest);
        push @f, "$old/$rest" if defined $old && $x =~ /\A(?:~-|\$\{?OLDPWD)/;
        return @f;
    }
    return () if ClaudeApart::Paths::expand($x, '/') =~ /\$/;
    return ($x);
}

sub _swap {
    my ($t, $dir) = @_;
    my ($old, $new) = @$t;
    my $i = index($dir, $old);
    return () if $i < 0 || !length $old;
    substr($dir, $i, length $old) = $new;
    return ClaudeApart::Paths::spellings($dir, '/');
}

sub _rule_read_denied {
    my ($ctx, $sh) = @_;
    return 1 if ClaudeApart::Paths::text_hits($ctx->{read}, $sh->{text});
    return ClaudeApart::Paths::set_holds($ctx->{read}, @{ $sh->{spellings} });
}

# R26: a command that mentions a readable but write-denied root may only run
# read-only commands, and no redirect may point into a write-denied root.
sub _rule_write_denied {
    my ($ctx, $sh) = @_;
    my $w = $ctx->{wonly};
    return 0 unless @{ $w->{abs} } || @{ $w->{fam} };
    return 0 unless ClaudeApart::Paths::text_hits($w, $sh->{text})
        || ClaudeApart::Paths::set_holds($w, @{ $sh->{spellings} });
    for my $seg (grep { $_->{exec} } @{ $sh->{segments} }) {
        return 1 unless _read_only($seg);
        for my $r (@{ $seg->{redirects} }) {
            return 1 if ClaudeApart::Paths::text_hits($ctx->{write}, $r->{w})
                || ClaudeApart::Paths::set_holds($ctx->{write}, @{ $r->{sp} });
        }
    }
    return 0;
}

sub _read_only {
    my ($seg) = @_;
    my @w = map { $_->{w} } @{ $seg->{words} };
    while (@w && $w[0] =~ /\A([A-Za-z_][A-Za-z0-9_]*)=/) {    # PATH=…, LESSOPEN=… change what runs
        return 0 unless $SAFE_VAR{$1} || $1 =~ /\ALC_[A-Z]+\z/;
        shift @w;
    }
    return 1 unless @w;
    my ($name) = $w[0] =~ m{\A(?:/bin/|/usr/bin/|/usr/local/bin/|/opt/homebrew/bin/)?([^/]+)\z}
        or return 0;
    return 0 unless $READ_ONLY{$name};
    my @a = @w[ 1 .. $#w ];
    return 0 if $name eq 'find' && grep { /\A-(?:delete|exec|execdir|ok|okdir|fprint|fprint0|fprintf|fls)\z/ } @a;
    return 0 if $name eq 'sort' && grep { /\A-[^-]*o/ || /\A--output/ } @a;
    return 0 if $name eq 'uniq' && (grep { !/\A-/ } @a) > 1;
    return 0 if $name eq 'tree' && grep { /\A-[^-]*[oR]/ } @a;                  # -o FILE, -R write
    return 0 if $name eq 'file' && grep { /\A-[^-]*C/ || /\A--compile/ } @a;     # writes a .mgc
    return 0 if $name eq 'rg'   && grep { /\A--pre(?:=|\z)/ } @a;                # runs a command
    return 0 if $name eq 'less' && grep { /\A-[^-]*[oO]/ || /\A--(?:log-file|LOG-FILE)/ } @a;
    return 1;
}

# R6 + R24: a recursive reader may not reach a folder that holds a
# read-denied root: no word of its simple command may be such a folder, and
# with no real path operand the directory it runs in may not be one either.
sub _rule_recursive_reader {
    my ($ctx, $sh) = @_;
    for my $seg (@{ $sh->{segments} }) {
        my $r = _find_cmd($seg, \&_is_reader, \%READER_NAME) or next;
        my @w = (@{ $r->{before} }, @{ _not_patterns($r->{name}, $r->{rest}) });
        return 1 if ClaudeApart::Paths::set_inside($ctx->{read}, map { @{ $_->{sp} } } @w);
        next unless $CWD_DEFAULT{ $r->{name} };
        next if _has_real_path($r->{name}, $r->{rest});
        return 1 if ClaudeApart::Paths::set_inside($ctx->{read}, @{ $sh->{dirs} });
    }
    return 0;
}

# R30: a recursive modifier may not target a folder that holds a
# write-denied root.
sub _rule_recursive_modifier {
    my ($ctx, $sh) = @_;
    for my $seg (@{ $sh->{segments} }) {
        my $m = _find_cmd($seg, \&_is_modifier, \%MODIFIER_NAME) or next;
        my $w = _not_patterns($m->{name}, $m->{rest});
        return 1 if ClaudeApart::Paths::set_inside($ctx->{write}, map { @{ $_->{sp} } } @$w);
        next unless $m->{name} eq 'find' && !_has_real_path('find', $m->{rest});
        return 1 if ClaudeApart::Paths::set_inside($ctx->{write}, @{ $sh->{dirs} });
    }
    return 0;
}

# A glob with no "/": a name pattern, or names in the current folder.
sub _bare_glob { return $_[0] =~ ClaudeApart::Paths::glob_chars() && index($_[0], '/') < 0 }

# The items of a command minus find's name patterns (`-name '*.md'`).
my %FIND_PATTERN = map { $_ => 1 } qw(-name -iname -path -ipath -wholename -iwholename -regex
    -iregex -lname -ilname);
sub _not_patterns {
    my ($name, $rest) = @_;
    return $rest unless $name eq 'find';
    my @keep;
    for (my $i = 0; $i < @$rest; $i++) {
        push @keep, $rest->[$i];
        $i++ if $FIND_PATTERN{ $rest->[$i]{w} };
    }
    return \@keep;
}

# The first word of a segment that the test accepts, with the items up to it
# (before) and after it (rest). Only words named in %$names are tried.
sub _find_cmd {
    my ($seg, $test, $names) = @_;
    my @items = @{ $seg->{words} };
    for my $k (0 .. $#items) {
        my $name = _name($items[$k]{w});
        next unless defined $name && $names->{$name};
        my @rest = @items[ $k + 1 .. $#items ];
        return { name => $name, before => [ @items[ 0 .. $k ] ], rest => \@rest }
            if $test->($name, [ map { $_->{w} } @rest ]);
    }
    return undef;
}

sub _short { my ($args, $re) = @_; return scalar grep { /\A-[^-]/ && $_ =~ $re } @$args }

sub _is_reader {
    my ($name, $args) = @_;
    return 1 if $ALWAYS_READER{$name};
    my %long = map { $_ => 1 } grep { /\A--/ } @$args;
    if ($name =~ /\A[efz]?grep\z/) {
        return 1 if _short($args, qr/[rR]/) || $long{'--recursive'} || $long{'--dereference-recursive'}
            || $long{'--directories=recurse'};
        return 1 if join(' ', @$args) =~ /(?:\A| )(?:-d|--directories) recurse(?: |\z)/;
        return 0;
    }
    return 1 if $name eq 'ls'  && (_short($args, qr/R/) || $long{'--recursive'});
    return 1 if $name eq 'cp'  && (_short($args, qr/[rRa]/) || $long{'--recursive'} || $long{'--archive'});
    return 1 if $name eq 'scp' && _short($args, qr/r/);
    return 0;
}

sub _is_modifier {
    my ($name, $args) = @_;
    my $long = grep { $_ eq '--recursive' } @$args;
    return (_short($args, qr/[rR]/) || $long) ? 1 : 0 if $name eq 'rm';
    return (_short($args, qr/R/) || $long) ? 1 : 0 if $name =~ /\Ach(?:mod|own|grp)\z/;
    return _short($args, qr/[rR]/) ? 1 : 0 if $name eq 'xattr';
    return (grep { /\A-(?:delete|exec|execdir|ok|okdir)\z/ } @$args) ? 1 : 0 if $name eq 'find';
    return $name eq 'ditto' ? 1 : 0;
}

# Does a reader get a path operand that exists (or is a glob with a "/")?
# Option arguments (`-t py`, `-A 3`) may look like operands, so a word only
# counts when it names something on disk. A glob with no "/" (`grep -r x *`)
# names the current folder's entries, so it does not count.
sub _has_real_path {
    my ($name, $rest) = @_;
    my $glob = ClaudeApart::Paths::glob_chars();
    for my $it (@{ _operands($name, $rest) }) {
        next if _bare_glob($it->{w});
        return 1 if $it->{w} =~ $glob || ClaudeApart::Paths::exists_any(@{ $it->{sp} });
    }
    return 0;
}

sub _operands {
    my ($name, $rest) = @_;
    my @ops;
    if ($name eq 'find') {
        for (my $i = 0; $i < @$rest; $i++) {
            my $w = $rest->[$i]{w};
            next if $w =~ /\A-[HLPEXdsx]+\z/;                 # options before the paths
            if ($w eq '-f') { push @ops, $rest->[ ++$i ] if $i + 1 < @$rest; next }
            last if $w =~ /\A[-(!)]/;
            push @ops, $rest->[$i];
        }
        return \@ops;
    }
    my ($given, $skip) = (0, 0);
    for my $it (@$rest) {
        my $w = $it->{w};
        if ($skip) { $skip = 0; next }
        if ($PATTERN_FIRST{$name} && ($w =~ /\A-[^-]*[ef]\z/ || $w =~ /\A--(?:regexp|file)\z/)) {
            ($given, $skip) = (1, 1);
            next;
        }
        $given = 1 if $PATTERN_FIRST{$name} && $w =~ /\A--(?:regexp|file)=/;
        next if $w =~ /\A-/;
        push @ops, $it;
    }
    my $files = $name eq 'rg' && grep { $_->{w} eq '--files' } @$rest;
    shift @ops if $PATTERN_FIRST{$name} && !$given && !$files;
    return \@ops;
}

1;
