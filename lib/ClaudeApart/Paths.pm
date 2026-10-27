package ClaudeApart::Paths;
use strict;
use warnings;
no warnings 'newline';    # words may end in a newline ($'a\n', "a<NL>"); stat on them just fails

# Path helpers for the guard. Core Perl only.
#
# A path can have several spellings: as written, with `.`/`..` collapsed,
# and the forms it takes while its symlinks are followed one hop at a time.
# Tools disagree on which one they use (Node collapses `..` before the kernel
# follows links; the shell lets the kernel do both), so the guard checks
# every spelling. A path is inside a root when ANY of its spellings is under
# ANY spelling of the root, or when one of its existing prefixes is the same
# file (device + inode) as the root. The inode check catches spellings that
# are not symlinks: macOS firmlinks (/System/Volumes/Data/...) and other
# letter case on a case-insensitive disk.

my $MAX_HOPS   = 40;
my $GLOB_CAP   = 512;
my $GLOB_CHARS = qr/[*?\[{]/;
my $SPLIT      = qr/[ \t\n\r\f\x0b;&|()<>`'"]+/;    # plain split, quotes included
my $PIECES     = qr/[=,:@]+/;                         # a=b, a,b, url:path, @file
my $FOLD       = $^O eq 'darwin';                     # macOS: names match in any case
my $DATA       = '/System/Volumes/Data';              # macOS firmlink spelling

my (%LINK, %SPELL, %ID, %GLOB, %ISDIR, %LST, %PW);    # caches; one hook call is one process

# A path component that stands for "some folder that does not exist yet"
# (see Guard::_cd_dirs). Nobody has a folder with this name.
our $HOLE = "\x01capart-missing\x01";

# The home folder of a user name, from the password database, or undef.
# A code ref so tests can stub it.
our $USER_HOME = sub {
    my @pw = getpwnam($_[0]);
    return (@pw && defined $pw[7] && substr($pw[7], 0, 1) eq '/') ? $pw[7] : undef;
};

sub uniq { my %s; return grep { !$s{$_}++ } @_ }

sub glob_chars { return $GLOB_CHARS }

sub home {
    my $h = $ENV{HOME};
    die "HOME is not set\n" unless defined $h && length $h;
    $h =~ s{(?<=.)/+\z}{};
    return $h;
}

# Expands a leading ~, ~user (password database), $HOME or ${HOME}. ~+ and
# $PWD are the given cwd; ~- and $OLDPWD are $OLDPWD from the environment,
# else the cwd. Any other leading $VAR / ${VAR} is taken from the
# environment, so `$XDG_CONFIG_HOME/…` is caught too, and so are
# ${VAR:-word} style defaults: `${XDG_CONFIG_HOME:-$HOME/.config}/…`.
my $NAME = qr/[A-Za-z_][A-Za-z0-9_]*/;

sub _oldpwd {
    my $o = $ENV{OLDPWD};
    return (defined $o && substr($o, 0, 1) eq '/') ? $o : undef;
}

sub _var {
    my ($name, $cwd) = @_;
    my $v = $name eq 'HOME' ? home()
          : ($name eq 'PWD' && defined $cwd) ? $cwd
          : $name eq 'OLDPWD' ? (_oldpwd() // $cwd)
          : $ENV{$name};
    return (defined $v && length $v) ? $v : undef;
}

sub expand {
    my ($p, $cwd, $depth) = @_;
    return home() . substr($p, 1) if $p =~ m{^~(?=/|\z)};
    if ($p =~ m{^~([-+])(?=/|\z)}) {
        my $v = $1 eq '+' ? $cwd : (_oldpwd() // $cwd);
        return defined $v ? $v . substr($p, 2) : $p;
    }
    if ($p =~ m{^~([A-Za-z0-9_][A-Za-z0-9._-]*)(?=/|\z)}) {
        my ($name, $len) = ($1, $+[0]);
        my $h = exists $PW{$name} ? $PW{$name} : ($PW{$name} = $USER_HOME->($name));
        return defined $h ? $h . substr($p, $len) : $p;
    }
    return $p if ($depth || 0) > 4;
    my ($name, $op, $word, $len);
    if ($p =~ m{^\$($NAME)(?=/|\z)}) {
        ($name, $len) = ($1, $+[0]);
    } elsif ($p =~ m{^\$(\{((?:[^{}]++|(?1))*)\})(?=/|\z)}) {
        my $inner = $2;
        $len = $+[0];
        return $p unless $inner =~ m{^($NAME)(?:(:?[-=?+])(.*))?\z}s;
        ($name, $op, $word) = ($1, $2, $3);
    } else {
        return $p;
    }
    my $rest = substr($p, $len);
    my $val  = _var($name, $cwd);
    if (defined $op && $op =~ /\+/) {    # ${VAR:+word}: word when VAR is set
        return defined $val ? expand($word, $cwd, ($depth || 0) + 1) . $rest : $p;
    }
    return $val . $rest if defined $val;
    return expand($word, $cwd, ($depth || 0) + 1) . $rest if defined $op && $op =~ /[-=]/;
    return $p;
}

# Expanded and joined onto $cwd; not normalised.
sub absolute {
    my ($path, $cwd) = @_;
    my $p = expand($path, $cwd);
    return $p if substr($p, 0, 1) eq '/';
    die "relative path without an absolute cwd\n" unless defined $cwd && substr($cwd, 0, 1) eq '/';
    return "$cwd/$p";
}

# Collapses //, . and .. without looking at the disk.
sub _lex {
    my ($p) = @_;
    my @out;
    for my $c (split m{/+}, $p) {
        next if $c eq '' || $c eq '.';
        if ($c eq '..') { pop @out } else { push @out, $c }
    }
    return '/' . join('/', @out);
}

# Walks an absolute path one component at a time and follows symlinks
# (dangling ones too) with readlink, at most $MAX_HOPS times. A `..` pops the
# resolved prefix, as the kernel does. Once a component does not exist the
# rest stays literal. Returns (final, spellings seen after each hop).
sub _resolve {
    my ($p) = @_;
    my @todo = grep { length && $_ ne '.' } split m{/}, $p;
    my $done = '';    # resolved prefix; '' is the root
    my @seen;
    my $hops = 0;
    while (@todo) {
        my $c = shift @todo;
        if ($c eq '..') { $done =~ s{/[^/]*\z}{}; next }
        my $cur = "$done/$c";
        my $t = exists $LINK{$cur} ? $LINK{$cur} : ($LINK{$cur} = readlink $cur);
        if (defined $t && length $t && $hops < $MAX_HOPS) {
            $hops++;
            $done = '' if substr($t, 0, 1) eq '/';
            unshift @todo, grep { length && $_ ne '.' } split m{/}, $t;
            push @seen, _lex(join('/', $done, @todo));
            next;
        }
        $done = $cur;
    }
    return (length $done ? $done : '/', @seen);
}

# Absolute, `.`/`..` collapsed, symlinks resolved, no trailing slash.
sub canon {
    my ($path, $cwd) = @_;
    my ($final) = _resolve(_lex(absolute($path, $cwd)));
    return $final;
}

# Every spelling of an already absolute path (see the top of this file).
sub spellings_abs {
    my ($raw) = @_;
    return @{ $SPELL{$raw} } if $SPELL{$raw};
    my $lex = _lex($raw);
    my ($final, @seen) = _resolve($lex);
    my @all = ($lex, @seen, $final);
    if ($raw =~ m{(?:^|/)\.\.(?:/|\z)}) {    # kernel order: links first, then ..
        my ($pf, @ps) = _resolve($raw);
        push @all, @ps, $pf;
    }
    $SPELL{$raw} = [ uniq(@all) ];
    return @{ $SPELL{$raw} };
}

sub spellings { my ($path, $cwd) = @_; return spellings_abs(absolute($path, $cwd)) }

# "dev:inode" of an existing path (symlinks followed), else undef.
sub _id {
    my ($p) = @_;
    return $ID{$p} if exists $ID{$p};
    my @st = stat $p;
    return $ID{$p} = @st ? "$st[0]:$st[1]" : undef;
}

sub exists_any {
    for (@_) { return 1 if defined _id($_) }
    return 0;
}

sub _fold { return $FOLD ? lc $_[0] : $_[0] }
sub fold  { return _fold($_[0]) }

sub _under_str {    # both sides already folded
    my ($a, $r) = @_;
    return 1 if $r eq '/' || $a eq $r;
    return substr($a, 0, length($r) + 1) eq "$r/" ? 1 : 0;
}

# True when $abs is $root or inside it (see the top of this file).
sub under {
    my ($abs, $root) = @_;
    return set_holds(root_set($root), spellings($abs, '/'));
}

# ---- root sets ---------------------------------------------------------------

# Everything needed to match a group of roots:
# - their absolute spellings (plus the /System/Volumes/Data spelling on macOS);
# - one regex for the text spellings (absolute, ~/, $HOME/, ${HOME}/; a
#   file:// URL contains the absolute one). A root matches only when followed
#   by the end of the text or a character outside [A-Za-z0-9._-];
# - a family root ("<path>.*", see Config::owned_paths) also matches
#   "<path>." followed by anything;
# - device+inode of each existing root, and of each of its parents.
sub root_set {
    my (@roots) = @_;
    my $data  = -d $DATA;
    my @homes = grep { $_ ne '/' } spellings(home(), '/');
    my (@abs, @fam, @text, @famtext, %ids, %anc);
    for my $root (@roots) {
        my $base   = $root;
        my $family = $base =~ s/\.\*\z//;
        my @s = spellings($base, '/');
        push @s, map { "$DATA$_" } grep { index($_, "$DATA/") != 0 } @s if $data;
        @s = uniq(@s);
        for my $s (@s) {
            my @t = ($s);
            for my $h (@homes) {
                my $rest;
                if ($s eq $h) { $rest = '' }
                elsif (index($s, "$h/") == 0) { $rest = substr($s, length $h) }
                else { next }
                push @t, "~$rest", "\$HOME$rest", "\${HOME}$rest";
            }
            if ($family) { push @fam, $s; push @famtext, @t }
            else         { push @abs, $s; push @text, @t }
        }
        next if $family;
        for my $s (@s) {
            my $id = _id($s);
            $ids{$id} = 1 if defined $id;
            for (my $p = $s; ; ) {
                my $i = _id($p);
                $anc{$i} = 1 if defined $i;
                last if $p eq '/';
                $p =~ s{/[^/]*\z}{};
                $p = '/' if $p eq '';
            }
        }
    }
    my @alts;
    push @alts, '(?:' . _alt(@text) . ')(?![A-Za-z0-9._-])' if @text;
    push @alts, '(?:' . _alt(@famtext) . ')\.' if @famtext;
    my $re;
    if (@alts) {
        my $src = join '|', @alts;
        $re = $FOLD ? qr/$src/i : qr/$src/;
    }
    @abs = uniq(@abs);
    return {
        abs_raw => \@abs,
        abs     => [ map { _fold($_) } @abs ],
        fam     => [ map { _fold($_) } uniq(@fam) ],
        re      => $re,
        ids     => \%ids,
        anc     => \%anc,
        memo    => {},
    };
}

sub _alt { return join '|', map { quotemeta } sort { length($b) <=> length($a) } uniq(@_) }

sub text_hits {
    my ($set, $text) = @_;
    return (defined $set->{re} && $text =~ $set->{re}) ? 1 : 0;
}

# Is some existing prefix of $p one of the set's roots (by device+inode)?
sub _id_hit {
    my ($set, $p) = @_;
    my $memo = $set->{memo};
    my (@chain, $hit);
    while (1) {
        if (exists $memo->{$p}) { $hit = $memo->{$p}; last }
        push @chain, $p;
        my $id = _id($p);
        if (defined $id && $set->{ids}{$id}) { $hit = 1; last }
        if ($p eq '/') { $hit = 0; last }
        $p =~ s{/[^/]*\z}{};
        $p = '/' if $p eq '';
    }
    $memo->{$_} = $hit for @chain;
    return $hit;
}

# Some spelling lies inside a root of the set.
sub set_holds {
    my ($set, @spellings) = @_;
    for my $a (@spellings) {
        my $f = _fold($a);
        for my $r (@{ $set->{abs} }) { return 1 if _under_str($f, $r) }
        for my $b (@{ $set->{fam} }) { return 1 if index($f, "$b.") == 0 }
    }
    if (%{ $set->{ids} }) {
        for my $a (@spellings) { return 1 if _id_hit($set, $a) }
    }
    return 0;
}

# A root of the set lies inside some spelling (the spelling is an ancestor).
sub set_inside {
    my ($set, @spellings) = @_;
    for my $a (@spellings) {
        my $f = _fold($a);
        for my $r (@{ $set->{abs} }) { return 1 if _under_str($r, $f) }
        my $id = _id($a);
        return 1 if defined $id && $set->{anc}{$id};
    }
    return 0;
}

# ---- text -> paths -------------------------------------------------------------

# Shell words with quotes and backslashes removed, as [text, is_operator].
# Runs of ; & | ( ) < > ` are operator tokens; an unquoted newline is the
# operator "\n".
# A backslash before a newline joins the lines. $'…' is decoded (ANSI-C
# escapes); $"…" counts as "…".
my %CESC = (a => "\a", b => "\b", e => "\e", E => "\e", f => "\f", n => "\n", r => "\r",
            t => "\t", v => "\x0b");

sub _ansi_c {
    my ($q) = @_;
    $q =~ s{\\(?:([abeEfnrtv])|([0-7]{1,3})|x([0-9A-Fa-f]{1,2})|u([0-9A-Fa-f]{1,4})|U([0-9A-Fa-f]{1,8})|c(.)|(.))}{
        defined $1 ? $CESC{$1}
      : defined $2 ? chr(oct($2) & 255)
      : defined $3 ? chr(hex $3)
      : defined $4 ? _utf8(hex $4)
      : defined $5 ? _utf8(hex $5)
      : defined $6 ? chr(ord(uc $6) ^ 64)
      : $7
    }gse;
    return $q;
}

sub _utf8 { my $c = $_[0] > 0x10FFFF ? 0xFFFD : $_[0]; my $s = chr($c); utf8::encode($s); return $s }

#
# R37: like bash, only braces outside quotes expand. For each word with a
# brace or comma, shell_words remembers in %VIEW a "view" of the word in
# which the quoted (or backslashed) { , } are swapped for the bytes \x1c
# \x1d \x1e; brace_alts expands the view, so only the unquoted ones count.
# The same text written both ways counts as unquoted (more is checked).
# Code in quotes (bash -c '…') is parsed again one level deeper, where its
# own unquoted braces expand.
# R40 (a): a quoted word with no other code in it ('{a,b}x') is parsed again
# with $VIEW_OFF set: there every brace counts as unquoted, and nothing is
# remembered, so the word keeps its quoted view one level up.
my %VIEW;
our $VIEW_OFF = 0;

sub _inert { (my $v = $_[0]) =~ tr/{,}/\x1c\x1d\x1e/; return $v }
sub brace_view { return (!$VIEW_OFF && exists $VIEW{ $_[0] }) ? $VIEW{ $_[0] } : $_[0] }

sub _remember_view {
    my ($w, $v) = @_;
    return if $VIEW_OFF || $w !~ /[{,}]/;
    $v = $w if $w =~ /[\x1c-\x1e]/;    # cannot tell apart: all unquoted
    my $old = $VIEW{$w};
    if (defined $old && $old ne $v) {   # merge: a brace is unquoted if it is in either
        my $m = $old;
        for my $i (0 .. length($m) - 1) {
            substr($m, $i, 1) = substr($w, $i, 1) if substr($v, $i, 1) eq substr($w, $i, 1);
        }
        $v = $m;
    }
    $VIEW{$w} = $v;
}

#
# R40 (b): a heredoc body is data to bash (it never brace-expands one), so
# its tokens get a third element: [text, is_operator, 1]. A body starts
# after the newline that ends the line of its `<<WORD` (`<<-WORD` also strips
# leading tabs) and ends at the first line that is exactly WORD (quotes
# removed). Lines are never joined by a backslash here, so a body never ends
# later than bash ends it. `<<` inside (( … )) is a shift, not a heredoc.
# $in_body (internal): the text is a body; no heredocs in it.
sub shell_words {
    my ($s, $in_body) = @_;
    my @w;
    my ($cur, $view, $have) = ('', '', 0);
    my @pending;                  # [delimiter, strip tabs] waiting for their body
    my ($want, $arith) = (0, 0);  # want: [strip tabs] while the next word is a delimiter
    my $flush = sub {
        if ($have) {
            push @w, [ $cur, 0 ];
            _remember_view($cur, $view);
            push @pending, [ $cur, $want->[0] ] if $want;
            $want = 0;
        }
        ($cur, $view, $have) = ('', '', 0);
    };
    my $add = sub { $cur .= $_[0]; $view .= $_[1] ? _inert($_[0]) : $_[0]; $have = 1 };
    pos($s) = 0;
    while (pos($s) < length $s) {
        if ($s =~ /\G([ \t\n\r\f\x0b]+)/gc) {
            my ($ws, $at) = ($1, $-[1]);
            $flush->();
            next if index($ws, "\n") < 0;
            push @w, [ "\n", 1 ];
            next unless @pending;
            pos($s) = $at + index($ws, "\n") + 1;
            push @w, _heredoc_body(\$s, @$_), [ "\n", 1, 1 ] for @pending;
            @pending = ();
        }
        elsif ($s =~ /\G([;&|()<>`]+)/gc) {
            my $op = $1;
            $flush->();
            push @w, [ $op, 1 ];
            $want = 0;
            next if $in_body;
            $arith += () = $op =~ /\(\(/g;
            $arith -= () = $op =~ /\)\)/g;
            $arith = 0 if $arith < 0;
            $want = [ $s =~ /\G-/gc ? 1 : 0 ] if !$arith && $op =~ /(?<!<)<<\z/;
        }
        elsif ($s =~ /\G\\\n/gc) { }
        elsif ($s =~ /\G\\(.)/gcs) { $add->($1, 1) }
        elsif ($s =~ /\G\$'((?:[^'\\]+|\\.)*)'?/gcs) { $add->(_ansi_c($1), 1) }
        elsif ($s =~ /\G'([^']*)'?/gc) { $add->($1, 1) }
        elsif ($s =~ /\G\$?"((?:[^"\\]+|\\.)*)"?/gcs) {
            my $q = $1;
            $q =~ s/\\([\$`"\\\n])/$1 eq "\n" ? '' : $1/ge;
            $add->($q, 1);
        }
        elsif ($s =~ /\G((?:[^ \t\n\r\f\x0b;&|()<>`\\'"\$]+|\$(?!['"]))+)/gc) { $add->($1, 0) }
        else { $s =~ /\G(.)/gcs; $add->($1, 0) }
    }
    $flush->();
    return @w;
}

# The tokens of one heredoc body read from pos($$sr), which then stands
# after its delimiter line (or at the end of the text).
sub _heredoc_body {
    my ($sr, $delim, $tabs) = @_;
    my $body = '';
    while (pos($$sr) < length $$sr) {
        $$sr =~ /\G([^\n]*)(\n?)/gc;
        my ($line, $nl) = ($1, $2);
        my $cmp = $line;
        $cmp =~ s/\A\t+// if $tabs;
        last if $cmp eq $delim;
        $body .= $line . $nl;
    }
    return map { [ $_->[0], $_->[1], 1 ] } shell_words($body, 1);
}

# Words of a text: shell words (quotes removed) plus a plain split that also
# breaks on quotes, so paths inside quoted code become words too.
sub words {
    my ($text) = @_;
    return grep { length } (map { $_->[1] ? () : $_->[0] } shell_words($text)), split($SPLIT, $text);
}

# A word and the pieces of a=b, a,b, url:path and @file in it. Options
# (starting with -) and anything with a NUL byte are skipped.
sub word_pieces {
    my ($w) = @_;
    return grep { length && substr($_, 0, 1) ne '-' && index($_, "\0") < 0 }
        ($w, ($w =~ $PIECES ? split($PIECES, $w) : ()));
}

sub path_candidates {
    my ($text) = @_;
    my %seen;
    return grep { !$seen{$_}++ } map { word_pieces($_) } words($text);
}

# The directory part before the first glob character of an absolute pattern.
sub glob_dir {
    my ($abs) = @_;
    return $abs unless $abs =~ $GLOB_CHARS;
    my $lit = substr($abs, 0, $-[0]);
    $lit =~ s{[^/]*\z}{};
    return length $lit ? $lit : '/';
}

# Matches of an absolute glob pattern, or undef when there are too many.
sub glob_paths {
    my ($pat) = @_;
    return $GLOB{$pat} if exists $GLOB{$pat};
    require File::Glob;
    my @m = File::Glob::bsd_glob($pat, File::Glob::GLOB_NOSORT() | File::Glob::GLOB_BRACE()
        | File::Glob::GLOB_NOMAGIC() | File::Glob::GLOB_LIMIT());
    return $GLOB{$pat} = (File::Glob::GLOB_ERROR() || @m > $GLOB_CAP) ? undef : \@m;
}

# Every spelling of one candidate path, relative to each base. A glob with a
# "/" adds the spellings of its literal directory (a shell with dotglob may
# reach anything there). When that directory holds a root of $gate, a glob
# also adds the spellings of its matches (too many matches: the gate roots
# under that directory count as matched). A glob with no "/" (`*.md`) is often
# a pattern, not a path, so it adds no directory; the guard checks the folder
# a command runs in for those itself.
#
# A word that starts with ~+, ~-, $PWD or $OLDPWD names a place relative to
# the folder the shell is in, so its rest is also taken from each base.
# A word that does not depend on the base is resolved once.
# $plain (optional): bases that neither lie in nor hold a root of $gate (see
# plain_dir). From such a base, a simple relative word whose first part does
# not exist cannot reach a root (no symlink on the way, no root below the
# base), so it is skipped there. This keeps long texts fast when a command
# has many cd targets.
sub _dotdot_glob { return $_[0] =~ /\A\.\.?[*?\[{]/ }    # can this part match ".."?

# Upper bound of how many folders a word climbs: its ".." parts (between
# / = , : @), counting a part that may match ".." (.* .? .[ ..*) as one too.
# A word with a brace group counts every ".." and ".*"-like text in it.
sub climb_ub {
    my ($w) = @_;
    return scalar(() = $w =~ /\.\.|\.[*?\[{]/g) if index($w, '{') >= 0;
    return scalar grep { $_ eq '..' || _dotdot_glob($_) } split m{[/=,:@]+}, $w;
}

sub prefix_rest {
    my ($c) = @_;
    return undef unless $c =~ m{\A(?:~[-+]|\$\{(?:OLD)?PWD\}|\$(?:OLD)?PWD(?![A-Za-z0-9_]))(?=/|\z)/*};
    my $r = substr($c, $+[0]);
    return length $r ? $r : '.';
}

sub _isdir { my ($p) = @_; return exists $ISDIR{$p} ? $ISDIR{$p} : ($ISDIR{$p} = -d $p ? 1 : 0) }
sub isdir  { return _isdir($_[0]) }
# '' (missing), 'l' (symlink), 'd' (directory) or 'f' (anything else); not following a last symlink.
sub _ltype {
    my ($p) = @_;
    return $LST{$p} if exists $LST{$p};
    return $LST{$p} = !(lstat $p) ? '' : -l _ ? 'l' : -d _ ? 'd' : 'f';
}

# Walking down from the real folder $pre ('' is /) through @$names: does
# the walk reach a name that does not exist while every folder on the way
# is a real directory (no symlink) that neither lies in nor holds a root of
# $gate? Then the path cannot reach a root.
sub _unreachable {
    my ($gate, $pre, $names) = @_;
    my $cur = $pre;
    for my $n (@$names) {
        return 0 unless plain_dir($gate, length $cur ? $cur : '/');
        my $t = _ltype("$cur/$n");
        return 1 if $t eq '';
        return 0 unless $t eq 'd';
        $cur .= "/$n";
    }
    return 0;
}

# The longest prefix of an absolute path that is an existing directory, and
# how many parts come after it.
sub dir_prefix {
    my ($p) = @_;
    my $k = 0;
    while ($p ne '/' && !_isdir($p)) {
        $p =~ s{/[^/]*\z}{};
        $p = '/' if $p eq '';
        $k++;
    }
    return ($p, $k);
}

# Is one of these spellings inside a root of the set, or a root inside it,
# comparing text only?
sub str_related {
    my ($set, @spellings) = @_;
    for my $a (@spellings) {
        my $f = _fold($a);
        for my $r (@{ $set->{abs} }) { return 1 if _under_str($f, $r) || _under_str($r, $f) }
        for my $b (@{ $set->{fam} }) { return 1 if index($f, "$b.") == 0 || _under_str($b, $f) }
    }
    return 0;
}

# A folder that neither lies in nor holds a root of the set, by text or by
# inode, in any spelling.
sub plain_dir {
    my ($set, $d) = @_;
    my $m = $set->{plain} ||= {};
    return $m->{$d} if exists $m->{$d};
    my @sp = spellings_abs($d);
    return $m->{$d} = (str_related($set, @sp) || set_holds($set, @sp) || set_inside($set, @sp)) ? 0 : 1;
}

my %CANON;    # is a folder spelled as its real path (no symlink in it)?
sub _is_canon { my ($b) = @_; return $CANON{$b} //= (canon($b, "/") eq $b ? 1 : 0) }

sub _anc {    # $p climbed $n folders up
    my ($p, $n) = @_;
    while ($n-- > 0 && $p ne "/") { $p =~ s{/[^/]*\z}{}; $p = "/" if $p eq "" }
    return $p;
}

# Brace expansion, which the shell does before ~ and $ expansion:
# "a{b,c}d" gives "abd" and "acd" (nested groups too). Only a group with a
# comma at its top level expands; ${…} is a variable, not a group. More than
# $BRACE_CAP words is an error, except with $BRACE_SOFT set (text that is
# only maybe code, see Guard::_item): then the word is taken as written.
# Only unquoted braces expand (see %VIEW above).
my $BRACE_CAP = 256;
our $BRACE_SOFT = 0;

sub _brace_group {    # (before, [alternatives], after) of the first group, or ()
    my ($s) = @_;
    my $n = length $s;
    for (my $i = 0; $i < $n; $i++) {
        my $ch = substr($s, $i, 1);
        if ($ch eq '\\') { $i++; next }
        next unless $ch eq '{';
        my $var = $i > 0 && substr($s, $i - 1, 1) eq '$';
        my ($depth, $start, @alts) = (0, $i + 1);
        for (my $j = $i; $j < $n; $j++) {
            my $d = substr($s, $j, 1);
            if    ($d eq '\\') { $j++ }
            elsif ($d eq '{') { $depth++ }
            elsif ($d eq ',' && $depth == 1) { push @alts, substr($s, $start, $j - $start); $start = $j + 1 }
            elsif ($d eq '}' && --$depth == 0) {
                last if $var || !@alts;    # ${…} or no comma: not a group; look further on
                push @alts, substr($s, $start, $j - $start);
                return (substr($s, 0, $i), \@alts, substr($s, $j + 1));
            }
        }
    }
    return ();
}

sub brace_alts {
    my ($w) = @_;
    my $v = brace_view($w);
    return ($w) unless index($v, '{') >= 0 && index($v, ',') >= 0;
    my (@out, @todo);
    @todo = ($v);
    while (@todo) {
        my $s = shift @todo;
        my ($pre, $alts, $post) = _brace_group($s);
        if (!defined $pre) { push @out, $s; next }
        push @todo, map { "$pre$_$post" } @$alts;
        next unless @out + @todo > $BRACE_CAP;
        return ($w) if $BRACE_SOFT;
        die "too many brace expansions\n";
    }
    if ($v ne $w) { tr/\x1c\x1d\x1e/{,}/ for @out }
    return uniq(@out);
}

# Every spelling of a path word from each base: the word as written and
# each of its brace expansions.
sub candidate_spellings {
    my ($c, $bases, $gate, $fast) = @_;
    my @alts = brace_alts($c);
    return _candidates($c, $bases, $gate, $fast) if @alts == 1 && $alts[0] eq $c;
    return map { _candidates($_, $bases, $gate, $fast) } uniq($c, @alts);
}

sub _candidates {    # candidate_spellings without brace expansion
    my ($c, $bases, $gate, $fast) = @_;
    my @out;
    my $rest = prefix_rest($c);
    push @out, _candidates($rest, $bases, $gate, $fast) if defined $rest && $rest ne $c;
    my $x = expand($c, "\x02");
    my @bases = (substr($x, 0, 1) eq '/' && index($x, "\x02") < 0) ? ($bases->[0]) : @$bases;
    # Fast path ($fast, needs $gate): a relative word made of leading . and ..
    # parts and then plain names ($tail). From a base with no symlink in it,
    # the kernel and the text agree on where the leading .. parts go, so the
    # word's spellings are those of "<that folder>/<tail>" (shared by every
    # base that climbs to the same folder). If that folder neither lies in
    # nor holds a root of $gate and the first name of the tail does not exist
    # there, nothing can be reached: no symlink on the way, no root below.
    my ($up, $tail);
    if ($fast && $gate && !defined $rest && $c !~ m{\A[~\$]} && $c !~ $GLOB_CHARS
        && $c =~ m{\A((?:\.\.?(?:/+|\z))*)(.*)\z}s) {
        my ($lead, $t) = ($1, $2);
        if (substr($c, 0, 1) ne '/' && $t !~ m{(?:\A|/)\.\.?(?:/|\z)}) {
            $up = () = $lead =~ /\.\./g;
            ($tail = $t) =~ s{/+\z}{};
        }
    }
    my @names = defined $tail ? split(m{/+}, $tail) : ();
    for my $b (@bases) {
        if (defined $up && _is_canon($b)) {
            my $a = _anc($b, $up);
            if (!@names) { push @out, spellings_abs($a); next }
            my $pre = $a eq '/' ? '' : $a;
            next if _unreachable($gate, $pre, \@names);
            push @out, spellings_abs("$pre/$tail");
            next;
        }
        my $abs = absolute($c, $b);
        push @out, spellings_abs($abs);
        (my $g = $abs) =~ s/\{\}//g;                    # "{}" is literal in a shell (find -exec)
        next unless $g =~ $GLOB_CHARS;
        my @dir = spellings_abs(glob_dir($abs));
        push @out, @dir if index($c, "/") >= 0;
        # `.*`, `.?`, `..*` also match "..": add the spelling with each such part as "..".
        (my $up = $abs) =~ s{(?<=/)(\.[^/]*)}{ _dotdot_glob($1) ? '..' : $1 }ge;
        push @out, spellings_abs($up) if $up ne $abs;
        next unless $gate && set_inside($gate, @dir);
        my $m = glob_paths($abs);
        if ($m) {
            push @out, spellings_abs($_) for grep { substr($_, 0, 1) eq '/' } @$m;
        } else {
            for my $r (@{ $gate->{abs_raw} }) {
                push @out, $r if grep { _under_str(_fold($r), _fold($_)) } @dir;
            }
        }
    }
    return @out;
}

# Every spelling of every path a text may refer to, from the given bases.
# Free text (a prompt, a JSON body) is only maybe code: past the brace cap a
# word is taken as written.
sub text_paths {
    my ($text, $bases, $gate) = @_;
    local $BRACE_SOFT = 1;
    return uniq(map { candidate_spellings($_, $bases, $gate) } path_candidates($text));
}

# True if $text mentions $root: a text spelling of the root, or a word that
# resolves into it from $cwd.
sub mentions {
    my ($text, $root, $cwd) = @_;
    my $set = root_set($root);
    return 1 if text_hits($set, $text);
    return set_holds($set, text_paths($text, [$cwd], $set)) ? 1 : 0;
}

1;
