package ClaudeApart::Guard;
use strict;
use warnings;
use ClaudeApart::Config;
use ClaudeApart::Paths;
use ClaudeApart::Herdr;

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
# A quoted word is surely shell code after `<shell> … -c` or after one of
# %EVAL_NAME, or when it holds $(…) or backticks. Other quoted words are
# only maybe code (a JSON body, a message): see _item.
my %SHELL_NAME = map { $_ => 1 } qw(sh bash zsh dash ksh mksh ash yash posh busybox su runuser script flock);
my %EVAL_NAME  = map { $_ => 1 } qw(eval trap watch alias);

# Rules for a shell command, in order. Each gets ($ctx, $sh) and returns true
# to block. $sh->{segments} holds the simple commands; see _analyse. Later
# tasks add rules here.
our @SHELL_RULES = (\&_rule_read_denied, \&_rule_write_denied, \&_rule_recursive_reader,
                    \&_rule_recursive_modifier, \&_rule_launcher, \&_rule_env, \&_rule_env_clear,
                    \&_rule_herdr, \&_rule_new_terminal, \&_rule_keychain);

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
        cfg     => $cfg,
        profile => $profile,
        cwd     => $cwd,
        read    => ClaudeApart::Paths::root_set(@$rd),
        write   => ClaudeApart::Paths::root_set(@$wd),
        wonly   => ClaudeApart::Paths::root_set(grep { !$r{$_} } @$wd),
        names   => { map { $_ => 1 } ClaudeApart::Config::profile_names($cfg) },
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
# {w => text, sp => [spellings of its path pieces], nested => analysed
# deeper}. Relative words are taken from every folder in $sh->{dirs}, and
# from the "missing" folders in $sh->{holes} when they climb out of them
# (see _cd_dirs).
sub _analyse {
    my ($ctx, $cmd) = @_;
    my $sh = { text => $cmd, segments => [], memo => {} };
    @$sh{qw(dirs holes)} = _cd_dirs($ctx, $cmd);
    _walk($ctx, $sh, $cmd, 0, 1, 1);
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
    my ($ctx, $sh, $text, $depth, $exec, $sure) = @_;
    my ($words, $redirs, $want_target) = ([], [], 0);
    my (@wsoft, @rsoft);    # R40 (b): the word is in a heredoc body
    my $pipe = [];          # words of the earlier commands of this pipeline
    my $end = sub {
        return unless @$words || @$redirs;
        my @code = _code_flags($words);
        push @{ $sh->{segments} }, {
            exec      => $exec,
            code      => $sure,
            pipe_in   => [@$pipe],
            words     => [ map { _item($ctx, $sh, $words->[$_], $depth, $exec, $sure, $code[$_], $wsoft[$_]) } 0 .. $#$words ],
            redirects => [ map { _item($ctx, $sh, $redirs->[$_], $depth, $exec, $sure, 0, $rsoft[$_]) } 0 .. $#$redirs ],
        };
        ($words, $redirs) = ([], []);
        @wsoft = @rsoft = ();
    };
    for my $t (ClaudeApart::Paths::shell_words($text)) {
        my ($w, $op, $body) = @$t;
        unless ($op) {
            if ($want_target) { push @$redirs, $w; push @rsoft, $body; $want_target = 0 }
            else { push @$words, $w; push @wsoft, $body }
            next;
        }
        (my $rest = $w) =~ s/&?[<>]+[&|]?//g;
        if (length $rest) {
            my $done = $words;
            $end->();
            $pipe = $rest =~ /\A\|&?\z/ ? [ @$pipe, @$done ] : [];
            $want_target = 0;
        }
        $want_target = 1 if $rest ne $w && $w !~ /\(/;
    }
    $end->();
}

# Code inside a word that is only maybe code: past the brace cap, a word
# there is taken as written instead of being an error (R37). So is a word of
# a heredoc body (R40 b). A segment is surely code (its `code` field) at
# the top, and below when its word is surely code (see _code_flags) or holds
# $(…) or backticks; a word that is only maybe code (a quoted message) gives
# segments that are not (the new-terminal and Keychain rules skip those).
sub _item {
    my ($ctx, $sh, $w, $depth, $exec, $seg_code, $code, $body) = @_;
    local $ClaudeApart::Paths::BRACE_SOFT = $body ? 1 : $ClaudeApart::Paths::BRACE_SOFT;
    my @sp = map { _piece($ctx, $sh, $_) } ClaudeApart::Paths::word_pieces($w);
    my $nested = _nested($w, $depth);
    my $braces = !$nested && _quoted_braces($w);
    if ($nested || $braces) {
        my $sure = ($code || $w =~ /\$\(|`/) ? 1 : 0;
        local $ClaudeApart::Paths::BRACE_SOFT = $sure ? 0 : 1;
        local $ClaudeApart::Paths::VIEW_OFF = $braces ? 1 : $ClaudeApart::Paths::VIEW_OFF;
        _walk($ctx, $sh, $w, $depth + 1, ($exec && $w =~ /\$\(|`/) ? 1 : 0, ($seg_code && $sure) ? 1 : 0);
    }
    return { w => $w, sp => [ ClaudeApart::Paths::uniq(@sp) ], nested => ($nested || $braces) ? 1 : 0 };
}

# R40 (a): a word whose { , } were quoted ('{a,b}x', with no other code
# in it) is not brace expanded here, but a shell or eval that runs it as
# code would expand them; so it is parsed again one level deeper (see
# Paths $VIEW_OFF).
sub _quoted_braces {
    my ($w) = @_;
    return 0 unless index($w, '{') >= 0 && index($w, ',') >= 0;
    return ClaudeApart::Paths::brace_view($w) ne $w ? 1 : 0;
}

# For each word of a simple command: is it surely shell code (see %SHELL_NAME)?
sub _code_flags {
    my ($words) = @_;
    my ($shell, $code, @f) = (0, 0);
    for my $w (@$words) {
        push @f, $code;
        my $n = _name($w) // '';
        if    ($EVAL_NAME{$n})  { $code  = 1 }
        elsif ($SHELL_NAME{$n}) { $shell = 1 }
        elsif ($shell && $w =~ /\A-[A-Za-z]*c[A-Za-z]*\z/) { $code = 1 }
    }
    return @f;
}

# The spellings of one path piece, from every folder of the command.
sub _piece {
    my ($ctx, $sh, $p) = @_;
    my $m = $sh->{memo};
    my $key = "$ClaudeApart::Paths::BRACE_SOFT\0" . ClaudeApart::Paths::brace_view($p);
    return @{ $m->{$key} } if $m->{$key};
    my @sp = ClaudeApart::Paths::candidate_spellings($p, $sh->{dirs}, $ctx->{write}, 1);
    my $c = ClaudeApart::Paths::climb_ub($p);
    for my $h (@{ $sh->{holes} }) {
        push @sp, ClaudeApart::Paths::candidate_spellings($p, [ $h->[0] ], $ctx->{write}, 1) if $c >= $h->[1];
    }
    $m->{$key} = [ ClaudeApart::Paths::uniq(@sp) ];
    return @{ $m->{$key} };
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

    my @t_swaps = grep { ref } @targets;
    my (@bases, @holes, @queue, @swap_from, %sig, %part, %canon, %seen, %hole, %is_base);
    my $swapped = 0;
    my $base = sub {
        my ($s) = @_;
        return if $sig{ _sig($s, $U, $set, \%part) }++;
        push @bases, $s;
        push @queue, [ $s, 0 ];
        $is_base{$s} = 1;
        $canon{ ClaudeApart::Paths::canon($s, '/') } = 1;
        die "too many cd directories\n" if keys %canon > $MAX_DIRS;
    };
    my $consider = sub {
        my ($s) = @_;
        return if $seen{$s}++ || index($s, $ClaudeApart::Paths::HOLE) >= 0;
        push @swap_from, $s if @t_swaps;
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
    $seen{$_} = $is_base{$_} = 1 for @cwd;
    push @swap_from, @cwd if @t_swaps;
    while (@queue || @swap_from) {
        if (@swap_from) {
            # zsh's `cd old new` edits the text of $PWD, which may be any
            # spelling seen, also one dropped as a duplicate or a missing one.
            # The result must be a folder that exists; from a base (or the
            # cwd) a missing result is kept too, as it may be made first.
            my $s = shift @swap_from;
            for my $t (@t_swaps) {
                for my $r (_swap($t, $s)) {
                    next if $seen{$r} || !($is_base{$s} || ClaudeApart::Paths::isdir($r));
                    die "too many cd directories\n" if ++$swapped > 16 * $MAX_DIRS;
                    $consider->($r);
                }
            }
            next;
        }
        my ($b, $j) = @{ shift @queue };
        for my $t (@t) {
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

# ---- launchers, env and Herdr -------------------------------------------------
# These rules see every simple command, also inside nested code. A word that
# holds nested code is skipped here: its own words are seen one level deeper.

my $CLAUDE_APART = qr{(?:\A|[=/])claude-apart\z}i;
my $CAPART_WORD   = qr{(?:\A|/)capart\.pl\z}i;
my %RUNS_SCRIPTS  = map { $_ => 1 } qw(perl sh bash zsh dash ksh csh tcsh fish python python3 ruby node xargs parallel);
my $HERDR_WORD   = qr{(?:\A|[=/])herdr\z}i;
my %APART_SAFE   = map { $_ => 1 } qw(status check help -h --help);
my %APART_CMD    = map { $_ => 1 } qw(setup add remove login status check copy new sync uninstall help);
my $ENV_NAME     = qr/CLAUDE_CONFIG_DIR|CLAUDE_APART_PROFILE|CLAUDE_CODE_CHILD_SESSION/;

my $FIND_EXEC    = qr/\A-(?:exec|execdir|ok|okdir)\z/;
my %FEEDS_ARGS   = map { $_ => 1 } qw(xargs parallel);
my $ASSIGN       = qr/\A[A-Za-z_][A-Za-z0-9_]*\+?=/;
my %CMD_PREFIX   = map { $_ => 1 } qw(! { do then else elif if while until time exec command builtin
    nohup env sudo nice noglob nocorrect timeout caffeinate ionice);

# R53: the index of the command word of a simple command: the first word
# after VAR=… words, shell keywords (do, then, if, {, !, …) and plain
# prefixes (env, nohup, sudo, timeout, …, with -options right after them).
# It is past the end when there is none. An option value (nice -n 5) is
# taken as the command word.
sub _cmd_index {
    my ($w) = @_;
    my ($i, $prefix) = (0, 0);
    for (; $i < @$w; $i++) {
        my $x = $w->[$i];
        if ($CMD_PREFIX{ _name($x) // '' }) { $prefix = 1; next }
        next if $x =~ $ASSIGN || ($prefix && $x =~ /\A-/);
        last;
    }
    return $i;
}

# R49: is the word at $k a command that gets words no one can see? Right
# after find's -exec, -execdir, -ok or -okdir: yes, whatever follows it. As
# the last word: only when the command word (see _cmd_index) is xargs or
# parallel, and not as the argument of which, type or command -v. Any other
# last word is just an argument (`cat bin/claude-apart`, `ls ~/.config/herdr`).
sub _fed_words {
    my ($w, $k) = @_;
    return 1 if $k > 0 && $w->[ $k - 1 ] =~ $FIND_EXEC;
    return 0 if $k < $#$w;
    my $c = _cmd_index($w);
    my $n = $c < @$w ? _name($w->[$c]) : undef;
    return 0 unless defined $n && $FEEDS_ARGS{$n};
    return _lookup_only($w, $k) ? 0 : 1;
}

# Is the word at $k an argument of which, type or command -v/-V (a lookup,
# not a run)?
sub _lookup_only {
    my ($w, $k) = @_;
    for my $j (0 .. $k - 1) {
        my $n = _name($w->[$j]) // next;
        return 1 if $n eq 'which' || $n eq 'type';
        return 1 if $n eq 'command' && grep { $w->[$_] =~ /\A-[A-Za-z]*[vV][A-Za-z]*\z/ } $j + 1 .. $k - 1;
    }
    return 0;
}

# Another profile's launcher: a word, or an a=b piece of one, named
# claude-<other profile>. R53: claude-<rest> where the rest cannot be known
# (claude-$p, claude-`…`, claude-{a,b}, claude-) blocks only as the command
# word or a fed word (see _fed_words); as plain text it passes
# (`grep -n claude- README.md`, `curl -o claude-$VER.tgz …`).
# R42: `claude-apart` blocks when the next word is a known subcommand other
# than status, check, help or `new <own profile>`; when it is an option other
# than -h/--help, or cannot be known ($X, `…`, xargs' {}). Any other next word is a
# file, not a subcommand (`git add bin/claude-apart README.md`). Glued after
# = (c=claude-apart) it may run later with any words: block. R49: after
# find -exec, or last under xargs/parallel, it blocks (see _fed_words); any
# other last word passes (bare `claude-apart` prints usage).
sub _rule_launcher {
    my ($ctx, $sh) = @_;
    my $own = $ctx->{profile};
    my %other = map { $_ => 1 } grep { $_ ne $own } ClaudeApart::Config::profile_names($ctx->{cfg});
    for my $seg (@{ $sh->{segments} }) {
        my @it = @{ $seg->{words} };
        my @w  = map { $_->{w} } @it;
        my $ci = _cmd_index(\@w);
        for my $k (0 .. $#it) {
            next if $it[$k]{nested};
            for my $p (ClaudeApart::Paths::word_pieces($w[$k])) {
                my $n = _name($p);
                next unless defined $n && $n =~ /\Aclaude-(.*)\z/is;
                my $rest = $1;
                return 1 if $other{ lc $rest };
                return 1 if ($rest eq '' || $rest =~ /[\$`{]/) && ($k == $ci || _fed_words(\@w, $k));
            }
            # R65: capart.pl RUNS (command word, fed word, or the script of an
            # interpreter or runner); a plain mention (cat, grep, git add) passes.
            if ($w[$k] =~ $CAPART_WORD) {
                return 1 if $k == $ci || _fed_words(\@w, $k) || _runs_script(\@w, $ci, $k);
            }
            next unless $w[$k] =~ $CLAUDE_APART;
            return 1 if index($w[$k], '=') >= 0 || _fed_words(\@w, $k) || _apart_blocks($own, \@w, $k);
        }
    }
    return 0;
}

# R42: does the `claude-apart` at $k change profile setup (see _rule_launcher)?
sub _apart_blocks {
    my ($own, $w, $k) = @_;
    return 0 if $k == $#$w;
    my $sub = $w->[ $k + 1 ];
    return 0 if $APART_SAFE{$sub};
    return 1 if $sub =~ /\A-|[\$`]/ || index($sub, '{}') >= 0;
    return 0 unless $APART_CMD{$sub};
    return 0 if $sub eq 'new' && $k + 2 <= $#$w && $w->[ $k + 2 ] eq $own;
    return 1;
}

# R67 (2): is the word at $k the script that the last interpreter or runner
# before it (from the command word on) runs? Not when a real program option
# comes between them: then the program is that option's text and the word
# is a data file (`perl -ne '…' capart.pl`). perl -n or -p alone give no
# program, nor does ruby -E (an encoding). A shell's -c gives none either
# (R76): the word after it is the program, and later words become $0 and
# $@, which the program can run.
my %PROGRAM_OPT = (
    perl   => qr/\A-(?:[aclnpsStTuUwWX]|[0l][0-7]*)*[eE]\z/,
    ruby   => qr/\A-[acdlnpsSvwy]*e\z/,
    node   => qr/\A(?:-[ep]|--eval|--print)\z/,
    python => qr/\A-[bBdEhiIOqRsSuvx]*c\z/,
);
my %RUNNER_KIND = ((map { $_ => 'shell' } qw(sh bash zsh dash ksh csh tcsh fish)),
                   perl => 'perl', ruby => 'ruby', node => 'node', python => 'python', python3 => 'python');

sub _runs_script {
    my ($w, $ci, $k) = @_;
    for (my $j = $k - 1; $j >= $ci; $j--) {
        my $n = _name($w->[$j]) // next;
        next unless $RUNS_SCRIPTS{$n};
        my $re = $PROGRAM_OPT{ $RUNNER_KIND{$n} // '' } or return 1;    # xargs, parallel
        return (grep { $_ =~ $re } @$w[ $j + 1 .. $k - 1 ]) ? 0 : 1;
    }
    return 0;
}

# R11: any mention of CLAUDE_CONFIG_DIR, CLAUDE_APART_PROFILE or
# CLAUDE_CODE_CHILD_SESSION blocks (so `unset …` and `env -u …` do), except
# an assignment that names the own profile. `env -i` is a known limit.
sub _rule_env {
    my ($ctx, $sh) = @_;
    my $seen = 0;
    for my $seg (@{ $sh->{segments} }) {
        for my $it (@{ $seg->{words} }, @{ $seg->{redirects} }) {
            next if $it->{nested} || $it->{w} !~ $ENV_NAME;
            $seen = 1;
            return 1 unless _own_assignment($ctx, $it->{w});
        }
    }
    return (!$seen && $sh->{text} =~ $ENV_NAME) ? 1 : 0;    # a mention no word showed
}

# R54 (c): env -i, env -, env --ignore-environment and exec -c drop the
# session's profile variables, so a later claude or claude-… word in the
# same command would not know its profile. Blocked, also in code inside it
# (env -i bash -c "claude …"). env -i without a claude word passes.
# R55 (2) as corrected: a later word that holds code (or a brace group) is
# matched by the token claude anywhere in it; any other later word only by
# its name (see _launcher_name, the own profile included), so
# `env -i … git log --grep claude-ish` passes. exec counts only as the
# command word (see _word0).
my $CLAUDE_TOKEN  = qr/(?<![\w.])claude(?![\w.])/i;
my %ENV_VALUE_OPT = map { $_ => 1 } qw(-u -C -S -P --unset --chdir --split-string);
my %KEYWORD       = map { $_ => 1 } qw(! { do then else elif if while until time command builtin);

sub _rule_env_clear {
    my ($ctx, $sh) = @_;
    for my $seg (@{ $sh->{segments} }) {
        return 1 if _env_clear_claude($ctx, [ map { $_->{w} } @{ $seg->{words} } ]);
    }
    return 0;
}

sub _env_clear_claude {
    my ($ctx, $w) = @_;
    my $w0 = _word0($w);
    for my $j (0 .. $#$w) {
        my $n = _name($w->[$j]) // next;
        next unless ($n eq 'env' || ($n eq 'exec' && $j == $w0)) && _clears_env($w, $j, $n eq 'exec');
        for my $x (@$w[ $j + 1 .. $#$w ]) {
            return 1 if ($x =~ $CODE || index($x, '{') >= 0) ? $x =~ $CLAUDE_TOKEN : _launcher_name($ctx, $x, 1);
        }
    }
    return 0;
}

# The index of the first word the shell may run as a builtin: after VAR=…
# words and shell keywords (with options right after them: time -p).
sub _word0 {
    my ($w) = @_;
    my ($i, $kw) = (0, 0);
    for (; $i < @$w; $i++) {
        my $x = $w->[$i];
        if ($KEYWORD{$x}) { $kw = 1; next }
        next if $x =~ $ASSIGN || ($kw && $x =~ /\A-/);
        last;
    }
    return $i;
}

# Is a word a claude launcher by its name: claude, or claude-<rest> where
# the rest cannot be known (claude-, claude-$P, claude-{a,b}) or names a
# configured profile (the own one only with $own_too)? Any letter case: the
# macOS disk finds `CLAUDE` as `claude`.
sub _launcher_name {
    my ($ctx, $x, $own_too) = @_;
    my $n = _name($x) // return 0;
    return 1 if $n =~ /\Aclaude\z/i;
    return 0 unless $n =~ /\Aclaude-(.*)\z/is;
    my $rest = $1;
    return 1 if $rest eq '' || $rest =~ /[\$`{]/;
    my $p = lc $rest;
    return 0 if !$own_too && $p eq $ctx->{profile};
    return $ctx->{names}{$p} ? 1 : 0;
}

# Does a text hold, at any quoting depth, a word named like a launcher (see
# _launcher_name)? A word with a brace group counts by the token claude.
sub _names_launcher {
    my ($ctx, $text, $own_too, $depth) = @_;
    $depth ||= 0;
    return 1 if _launcher_name($ctx, $text, $own_too);
    return 1 if index($text, '{') >= 0 && $text =~ $CLAUDE_TOKEN;
    return 0 unless $text =~ $CODE;
    return $text =~ $CLAUDE_TOKEN ? 1 : 0 if $depth > 2 * $MAX_DEPTH;
    for my $x (ClaudeApart::Paths::words($text)) {
        return 1 if $x ne $text && _names_launcher($ctx, $x, $own_too, $depth + 1);
    }
    return 0;
}

# F6: a new terminal, a tmux or screen server, osascript, open, an at,
# batch, cron or launchd job, ssh and systemd-run run their command without
# this session's environment, so a plain claude there starts the default
# profile (and claude-<other> another profile). Blocked: such a command
# word (after prefixes, or the command xargs or parallel runs; not after
# which/type) with a later word named claude or claude-<profile other than
# the own one>, at any quoting depth. at, batch, crontab, ssh and osascript
# also read commands from stdin, and xargs feeds words from it: there a
# launcher word in an earlier command of the same pipeline blocks too
# (R76: never the rest of the line, so `gh pr list --state open --search
# claude` passes). Only surely-code segments count (a quoted message passes).
my %NEW_TERM = map { $_ => 1 } qw(tmux screen zellij osascript open at batch crontab launchctl ssh systemd-run);
my %READS_IN = map { $_ => 1 } qw(at batch crontab ssh osascript);

sub _rule_new_terminal {
    my ($ctx, $sh) = @_;
    for my $seg (grep { $_->{code} } @{ $sh->{segments} }) {
        return 1 if _new_terminal_blocks($ctx, [ map { $_->{w} } @{ $seg->{words} } ], $seg->{pipe_in});
    }
    return 0;
}

sub _new_terminal_blocks {
    my ($ctx, $w, $pipe_in) = @_;
    my $ci = _cmd_index($w);
    return 0 if $ci > $#$w;
    my $fed = $FEEDS_ARGS{ _name($w->[$ci]) // '' };
    my @k = ($ci);
    # the command word may be a prefix option's value (sudo -u me tmux …)
    push @k, $ci + 1 if $ci > 0 && $w->[ $ci - 1 ] =~ /\A-/;
    if ($fed) {
        my $k = $ci + 1;
        $k++ while $k <= $#$w && $w->[$k] =~ /\A(?:-|\d+\z)/;
        @k = ($k);
    }
    for my $k (grep { $_ <= $#$w } @k) {
        my $n = _name($w->[$k]) // next;
        next unless $NEW_TERM{$n} && !_lookup_only($w, $k);
        for my $x (@$w[ $k + 1 .. $#$w ]) { return 1 if _names_launcher($ctx, $x, 0) }
        next unless $READS_IN{$n} || $fed;
        for my $x (@{ $pipe_in || [] }) { return 1 if _names_launcher($ctx, $x, 0) }
    }
    return 0;
}

# F7: every profile's login token is in the Keychain under "Claude
# Code-credentials" (with a suffix for a CLAUDE_CONFIG_DIR profile). A
# `security` command that names it would print a token into the transcript.
# Other ways into the Keychain are a known limit.
my $CREDENTIALS = qr/Claude\W{0,4}Code-credentials/i;

sub _rule_keychain {
    my ($ctx, $sh) = @_;
    for my $seg (grep { $_->{code} } @{ $sh->{segments} }) {
        return 1 if _keychain_blocks([ map { $_->{w} } @{ $seg->{words} } ], $sh->{text});
    }
    return 0;
}

sub _keychain_blocks {
    my ($w, $all) = @_;
    return 0 unless grep { (_name($_) // '') eq 'security' } @$w;
    return (grep { $_ =~ $CREDENTIALS } @$w, $all) ? 1 : 0;
}

# Do the options after env (or exec) at $j clear the environment?
sub _clears_env {
    my ($w, $j, $exec) = @_;
    for (my $i = $j + 1; $i < @$w; $i++) {
        my $x = $w->[$i];
        if ($exec) {
            return 1 if $x =~ /\A-[A-Za-z]*c[A-Za-z]*\z/;
            return 0 unless $x =~ /\A-/;
            $i++ if $x eq '-a';
            next;
        }
        return 1 if $x eq '-' || $x eq '--ignore-environment' || $x =~ /\A-[A-Za-z0-9]*i[A-Za-z0-9]*\z/;
        if ($x =~ /\A-/) { $i++ if $ENV_VALUE_OPT{$x}; next }
        return 0 unless $x =~ $ASSIGN;
    }
    return 0;
}

# CLAUDE_APART_PROFILE=<own name>, or CLAUDE_CONFIG_DIR=<the own dir>
# (absolute after ~ or $HOME, in any spelling that resolves to it).
sub _own_assignment {
    my ($ctx, $w) = @_;
    return 0 unless $w =~ /\A(CLAUDE_CONFIG_DIR|CLAUDE_APART_PROFILE)=(.*)\z/s;
    my ($name, $v) = ($1, $2);
    return 0 if $v =~ $ENV_NAME;
    return $v eq $ctx->{profile} ? 1 : 0 if $name eq 'CLAUDE_APART_PROFILE';
    my $p = ClaudeApart::Paths::expand($v, $ctx->{cwd});
    return 0 unless substr($p, 0, 1) eq '/' && $p !~ /[\$`]/ && $p !~ ClaudeApart::Paths::glob_chars();
    my $own = ClaudeApart::Config::profile($ctx->{cfg}, $ctx->{profile})->{abs_dir};
    return ClaudeApart::Paths::fold(ClaudeApart::Paths::canon($p, '/'))
        eq ClaudeApart::Paths::fold(ClaudeApart::Paths::canon($own, '/')) ? 1 : 0;
}

# Herdr. A read needs every target in the own or a readable profile; input
# (also rename, close, move, stop, and R51: a new shell from pane split, tab
# create, worktree create/open) needs the own profile. A target that maps
# to no profile, a failed or slow lookup, and a command for another server
# all block. On every herdr call, of any kind:
# - R45: a workspace label it writes must start with the own <emoji> <TAG>
#   (with a label of no profile the wrapper falls back to the default);
# - R46: no --env HERDR_… (or an --env that cannot be known), and no change
#   of the Herdr env the lookups rely on (HERDR_SOCKET=…, unset HERDR_…);
#   $HERDR_PANE_ID and the like may be read;
# - R47: herdr runs in the open. Blocked: herdr glued after = (h=herdr),
#   command words that cannot be known, and a herdr read or input command
#   after a word that may run herdr unseen (see _unknown_runner_before).
# - R54 (b, c): text typed into a pane (pane run, send-text, send-keys;
#   agent prompt, send-keys) runs in a plain shell, with no session check
#   behind it: see _typed_blocks.
# - R49: herdr after find -exec, or last under xargs/parallel, blocks (see
#   _fed_words); any other last herdr word passes (bare `herdr` needs a
#   terminal; `ls ~/.config/herdr`, `command -v herdr`).
sub _rule_herdr {
    my ($ctx, $sh) = @_;
    my ($any, @calls) = (0);
    for my $seg (@{ $sh->{segments} }) {
        my @it = @{ $seg->{words} };
        my @w  = map { $_->{w} } @it;
        my $ci = _cmd_index(\@w);
        for my $k (0 .. $#it) {
            next if $it[$k]{nested};
            if ($w[$k] !~ $HERDR_WORD) {
                return 1 if _unknown_runner_before(\@w, $k, $ci)
                    && ClaudeApart::Herdr::command_kind(@w[ $k .. $#w ]) ne 'other';
                next;
            }
            $any = 1;
            return 1 if index($w[$k], '=') >= 0 || _fed_words(\@w, $k);
            next if $k == $#w;
            my $c = ClaudeApart::Herdr::parse_command([ @w[ $k + 1 .. $#w ] ]);
            return 1 if $c->{kind} eq 'unknown';
            push @calls, $c;
        }
    }
    return 0 unless $any;
    for my $seg (@{ $sh->{segments} }) {
        for my $it (@{ $seg->{words} }, @{ $seg->{redirects} }) {
            return 1 if !$it->{nested} && $it->{w} =~ /(?<![\$\{])HERDR_/;
        }
    }
    my $own = $ctx->{profile};
    my %readable = map { $_ => 1 } $own, @{ ClaudeApart::Config::profile($ctx->{cfg}, $own)->{can_read} };
    for my $c (@calls) {
        for my $e (@{ $c->{env} }) { return 1 if !defined $e || $e =~ /[\$`]|\AHERDR_/ }
        for my $t (@{ $c->{text} }) { return 1 if _typed_blocks($ctx, $t, 0) }
        for my $l (@{ $c->{labels} }) {
            my $p = defined $l ? ClaudeApart::Herdr::profile_for_label($ctx->{cfg}, $l) : undef;
            return 1 unless defined $p && $p eq $own;
        }
        next if $c->{kind} eq 'other';
        return 1 if $c->{machine} || !@{ $c->{targets} };
        for my $t (@{ $c->{targets} }) {
            my $p = ClaudeApart::Herdr::profile_of_target($ctx->{cfg}, $t->[1], $t->[0]);
            return 1 unless defined $p;
            return 1 if $c->{kind} eq 'input' ? $p ne $own : !$readable{$p};
        }
    }
    return 0;
}

# R47/R53/R54 (a): may the word before $k run herdr under a name no one can
# see? Yes at the start of a command; after a fed word (find -exec …); and
# after a word with $ or ` that is the command word, or that is no option
# and does not follow one (nice -n 5 $H …, xargs "$(…)" …). After an
# option's value it may not (`git -C "$R" worktree remove x`).
sub _unknown_runner_before {
    my ($w, $k, $ci) = @_;
    return 1 if $k == 0 || _fed_words($w, $k - 1);
    my $p = $w->[ $k - 1 ];
    return 0 unless $p =~ /[\$`]/;
    return 1 if $k - 1 == $ci;
    return ($p !~ /\A-/ && !($k >= 2 && $w->[ $k - 2 ] =~ /\A-/)) ? 1 : 0;
}

# R54 (b, c), R55 (1): in each simple command of typed text (and of code
# inside it), a command word named claude-<rest> (after quotes and
# backslashes are removed) blocks when the rest cannot be known or is not a
# plain lowercase name (claude-$P, claude-${P:-x}, CLAUDE-PERSONAL), or
# names another profile (cl\aude-work); claude-apart follows R42; any other
# plain name passes (claude-code). env -i / exec -c may not come before a
# claude word, and the new-terminal (F6) and Keychain (F7) rules apply as in
# a Bash call. Plain `claude` resolves by the pane's workspace, which input
# already checks.
sub _typed_blocks {
    my ($ctx, $text, $depth) = @_;
    my $own = $ctx->{profile};
    return 1 if $depth > $MAX_DEPTH;
    my @segs = ([]);
    my %pipe_in;    # segment => words of the earlier commands of its pipeline
    for my $t (ClaudeApart::Paths::shell_words($text)) {
        unless ($t->[1]) { push @{ $segs[-1] }, $t->[0]; next }
        my $prev = $segs[-1];
        push @segs, [];
        $pipe_in{ $segs[-1] } = [ @{ $pipe_in{$prev} || [] }, @$prev ] if $t->[0] =~ /\A\|&?\z/;
    }
    for my $w (grep { @$_ } @segs) {
        my $ci = _cmd_index($w);
        my $n = $ci < @$w ? _name($w->[$ci]) // '' : '';
        # R76: a pane shell is not a session, so status and check there
        # would print every profile's identity for this session to read back
        if ($n =~ $CLAUDE_APART) {
            return 1 if _apart_blocks($own, $w, $ci) || ($ci < $#$w && $w->[ $ci + 1 ] =~ /\A(?:status|check)\z/);
        }
        elsif ($n =~ /\Aclaude-(.*)\z/is) {
            my $rest = $1;
            return 1 if $rest !~ /\A[a-z0-9-]+\z/ || ($rest ne $own && $ctx->{names}{$rest});
        }
        return 1 if _env_clear_claude($ctx, $w) || _new_terminal_blocks($ctx, $w, $pipe_in{$w}) || _keychain_blocks($w, $text);
        my @code = _code_flags($w);
        for my $i (0 .. $#$w) {
            return 1 if ($code[$i] || $w->[$i] =~ $CODE) && _typed_blocks($ctx, $w->[$i], $depth + 1);
        }
    }
    return 0;
}

1;
