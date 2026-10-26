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
# from every folder in $sh->{dirs} (see _cd_dirs).
sub _analyse {
    my ($ctx, $cmd) = @_;
    my $sh = { text => $cmd, dirs => _cd_dirs($ctx, $cmd), segments => [] };
    _walk($ctx, $sh, $cmd, 0, 1);
    $sh->{spellings} = [ ClaudeApart::Paths::uniq(
        map { map { @{ $_->{sp} } } @{ $_->{words} }, @{ $_->{redirects} } } @{ $sh->{segments} }) ];
    return $sh;
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
    my @sp = map { ClaudeApart::Paths::candidate_spellings($_, $sh->{dirs}, $ctx->{write}) }
             ClaudeApart::Paths::word_pieces($w);
    if ($depth < $MAX_DEPTH && $w =~ $CODE) {
        _walk($ctx, $sh, $w, $depth + 1, ($exec && $w =~ /\$\(|`/) ? 1 : 0);
    }
    return { w => $w, sp => [ ClaudeApart::Paths::uniq(@sp) ] };
}

# R8, union form: the folders a command may run in are the session cwd and
# every cd/pushd/chdir target written anywhere in it (after time, noglob,
# builtin, eval …, in quoted code, heredocs and comments). There is no order
# and no "did it run". A target is taken from the cwd, and again from every
# folder found so far, as long as that gives a new folder that exists
# (`cd ~; cd .claude`, `cd a; cd b; cd ../..`): a cd into a missing folder
# fails, so only the cwd round keeps missing ones (`mkdir x && cd x`).
# zsh's `cd old new` also swaps old for new in those folders. popd, `cd -`,
# $OLDPWD and targets with an unknown variable add nothing: they go back to
# folders already counted. More than $MAX_DIRS folders is an error.
# Returns the spellings of all the folders.
sub _cd_dirs {
    my ($ctx, $text) = @_;
    my (@all, %have, %canon);
    my $add = sub {    # keeps every spelling; returns those of folders not seen before
        my (@new, %fresh);
        for my $s (@_) {
            next if $have{$s}++;
            push @all, $s;
            my $c = ClaudeApart::Paths::canon($s, '/');
            $fresh{$c} = 1 unless $canon{$c};
            push @new, $s if $fresh{$c};
        }
        %canon = (%canon, %fresh);
        die "too many cd directories\n" if keys %canon > $MAX_DIRS;
        return @new;
    };
    my @bases = $add->(ClaudeApart::Paths::spellings($ctx->{cwd}, '/'));
    my @targets = _cd_targets($ctx, $text, 0);
    my $first = 1;
    while (@bases && @targets) {
        my @found;
        for my $t (@targets) {
            for my $b (@bases) {
                my @s = ref $t ? _swap($t, $b) : ClaudeApart::Paths::candidate_spellings($t, [$b], $ctx->{write});
                push @found, @s if $first || grep { -d $_ } @s;
            }
        }
        @bases = $add->(@found);
        $first = 0;
    }
    return \@all;
}

# The cd/pushd/chdir targets in a text: a word, or [old, new] for `cd old new`.
sub _cd_targets {
    my ($ctx, $text, $depth) = @_;
    my @tok = ClaudeApart::Paths::shell_words($text);
    my @out;
    for my $i (0 .. $#tok) {
        my ($w, $op) = @{ $tok[$i] };
        next if $op;
        push @out, _cd_targets($ctx, $w, $depth + 1) if $depth < $MAX_DEPTH && $w =~ $CODE;
        next unless $w =~ /\A(?:cd|pushd|chdir)\z/;
        my @a;
        for (my $j = $i + 1; $j <= $#tok && !$tok[$j][1]; $j++) { push @a, $tok[$j][0] }
        shift @a while @a && $a[0] =~ /\A(?:--|-[LPqe@]+)\z/;
        if (!@a) { push @out, '~' unless $w eq 'pushd'; next }
        next if $a[0] =~ /\A[-+]|`|OLDPWD|\A~[-+]/
             || ClaudeApart::Paths::expand($a[0], $ctx->{cwd}) =~ /\$/;
        push @out, $a[0];
        push @out, [ @a[ 0, 1 ] ] if @a > 1;
    }
    return @out;
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
        my $r = _find_cmd($seg, \&_is_reader) or next;
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
        my $m = _find_cmd($seg, \&_is_modifier) or next;
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
# (before) and after it (rest).
sub _find_cmd {
    my ($seg, $test) = @_;
    my @items = @{ $seg->{words} };
    for my $k (0 .. $#items) {
        my $name = _name($items[$k]{w});
        next unless defined $name;
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
