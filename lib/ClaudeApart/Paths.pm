package ClaudeApart::Paths;
use strict;
use warnings;

# Path helpers for the guard. Core Perl only.
#
# A path can have several spellings: as written, with `.`/`..` collapsed,
# and the forms it takes while its symlinks are followed one hop at a time.
# Tools disagree on which one they use (Node collapses `..` before the kernel
# follows links; the shell lets the kernel do both), so the guard checks
# every spelling. A path is inside a root when ANY of its spellings is under
# ANY spelling of the root.

my $MAX_HOPS   = 40;
my $GLOB_CAP   = 512;
my $GLOB_CHARS = qr/[*?\[{]/;
my $WS         = "[ \\t\\n\\r\\f\\x0b]";
my $SPLIT      = qr/[ \t\n\r\f\x0b;&|()<>`'"]+/;    # plain split, quotes included
my $PIECES     = qr/[=,:@]+/;                         # a=b, a,b, url:path, @file

my (%LINK, %SPELL);    # caches; one hook call is one process

sub _uniq { my %s; return grep { !$s{$_}++ } @_ }

sub home {
    my $h = $ENV{HOME};
    die "HOME is not set\n" unless defined $h && length $h;
    $h =~ s{(?<=.)/+\z}{};
    return $h;
}

# Expands a leading ~, $HOME or ${HOME}. Any other leading $VAR / ${VAR} is
# taken from the environment ($PWD = the given cwd), so `$XDG_CONFIG_HOME/…`
# is caught too, and so are ${VAR:-word} style defaults:
# `${XDG_CONFIG_HOME:-$HOME/.config}/…`.
my $NAME = qr/[A-Za-z_][A-Za-z0-9_]*/;

sub _var {
    my ($name, $cwd) = @_;
    my $v = $name eq 'HOME' ? home() : ($name eq 'PWD' && defined $cwd) ? $cwd : $ENV{$name};
    return (defined $v && length $v) ? $v : undef;
}

sub expand {
    my ($p, $cwd, $depth) = @_;
    return home() . substr($p, 1) if $p =~ m{^~(?=/|\z)};
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
    $SPELL{$raw} = [ _uniq(@all) ];
    return @{ $SPELL{$raw} };
}

sub spellings { my ($path, $cwd) = @_; return spellings_abs(absolute($path, $cwd)) }

sub _under_str {
    my ($a, $r) = @_;
    return 1 if $r eq '/' || $a eq $r;
    return substr($a, 0, length($r) + 1) eq "$r/" ? 1 : 0;
}

# True when $abs is $root or inside it, comparing every spelling of both.
sub under {
    my ($abs, $root) = @_;
    my @r = spellings($root, '/');
    for my $a (spellings($abs, '/')) {
        for my $x (@r) { return 1 if _under_str($a, $x) }
    }
    return 0;
}

# ---- root sets ---------------------------------------------------------------

# Everything needed to match a group of roots: their absolute spellings and
# one regex for the text spellings (absolute, ~/, $HOME/, ${HOME}/; a file://
# URL contains the absolute one). A root matches only when followed by the
# end of the text or a character outside [A-Za-z0-9._-].
sub root_set {
    my (@roots) = @_;
    my @homes = grep { $_ ne '/' } spellings(home(), '/');
    my (@abs, @text);
    for my $root (@roots) {
        for my $s (spellings($root, '/')) {
            push @abs, $s;
            push @text, $s;
            for my $h (@homes) {
                my $rest;
                if ($s eq $h) { $rest = '' }
                elsif (index($s, "$h/") == 0) { $rest = substr($s, length $h) }
                else { next }
                push @text, "~$rest", "\$HOME$rest", "\${HOME}$rest";
            }
        }
    }
    @abs  = _uniq(@abs);
    @text = _uniq(@text);
    my $re;
    if (@text) {
        my $alt = join '|', map { quotemeta } sort { length($b) <=> length($a) } @text;
        $re = qr/(?:$alt)(?![A-Za-z0-9._-])/;
    }
    return { abs => \@abs, re => $re };
}

sub text_hits {
    my ($set, $text) = @_;
    return (defined $set->{re} && $text =~ $set->{re}) ? 1 : 0;
}

# Some spelling lies inside a root of the set.
sub set_holds {
    my ($set, @spellings) = @_;
    for my $a (@spellings) {
        for my $r (@{ $set->{abs} }) { return 1 if _under_str($a, $r) }
    }
    return 0;
}

# A root of the set lies inside some spelling (the spelling is an ancestor).
sub set_inside {
    my ($set, @spellings) = @_;
    for my $a (@spellings) {
        for my $r (@{ $set->{abs} }) { return 1 if _under_str($r, $a) }
    }
    return 0;
}

# ---- text -> paths -------------------------------------------------------------

# Shell words with quotes and backslashes removed, as [text, is_operator].
# Runs of ; & | ( ) < > ` are operator tokens.
sub shell_words {
    my ($s) = @_;
    my @w;
    my ($cur, $have) = ('', 0);
    my $flush = sub { push @w, [ $cur, 0 ] if $have; ($cur, $have) = ('', 0) };
    pos($s) = 0;
    while (pos($s) < length $s) {
        if ($s =~ /\G$WS+/gc) { $flush->() }
        elsif ($s =~ /\G([;&|()<>`]+)/gc) { $flush->(); push @w, [ $1, 1 ] }
        elsif ($s =~ /\G\\(.)/gcs) { $cur .= $1 unless $1 eq "\n"; $have = 1 }
        elsif ($s =~ /\G'([^']*)'?/gc) { $cur .= $1; $have = 1 }
        elsif ($s =~ /\G"((?:[^"\\]+|\\.)*)"?/gcs) {
            my $q = $1;
            $q =~ s/\\([\$`"\\\n])/$1 eq "\n" ? '' : $1/ge;
            $cur .= $q;
            $have = 1;
        }
        elsif ($s =~ /\G([^ \t\n\r\f\x0b;&|()<>`\\'"]+)/gc) { $cur .= $1; $have = 1 }
        else { $s =~ /\G(.)/gcs; $cur .= $1; $have = 1 }
    }
    $flush->();
    return @w;
}

# Words of a text: shell words (quotes removed) plus a plain split that also
# breaks on quotes, so paths inside quoted code (`bash -c "…"`,
# `python3 -c "open('…')"`) become words too.
sub words {
    my ($text) = @_;
    return grep { length } (map { $_->[1] ? () : $_->[0] } shell_words($text)), split($SPLIT, $text);
}

# Words that may be paths, plus the pieces of a=b, a,b, url:path and @file.
# Options (starting with -) are skipped.
sub path_candidates {
    my ($text) = @_;
    my (@c, %seen);
    for my $w (words($text)) {
        for my $p ($w, ($w =~ $PIECES ? split($PIECES, $w) : ())) {
            next if !length $p || substr($p, 0, 1) eq '-' || $seen{$p}++;
            push @c, $p;
        }
    }
    return @c;
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
    require File::Glob;
    my @m = File::Glob::bsd_glob($pat, File::Glob::GLOB_NOSORT() | File::Glob::GLOB_BRACE()
        | File::Glob::GLOB_NOMAGIC() | File::Glob::GLOB_LIMIT());
    return undef if File::Glob::GLOB_ERROR() || @m > $GLOB_CAP;
    return \@m;
}

# Every spelling of every path a text may refer to. Relative words are
# resolved against each base. A word with glob characters adds the spellings
# of its literal directory, and, when that directory holds a root of $gate,
# the spellings of its matches (too many matches: the gate roots under that
# directory are taken as matched).
sub text_paths {
    my ($text, $bases, $gate) = @_;
    my (@out, %done);
    for my $c (path_candidates($text)) {
        for my $b (@$bases) {
            my $abs = absolute($c, $b);
            next if $done{$abs}++;
            push @out, spellings_abs($abs);
            next unless $abs =~ $GLOB_CHARS;
            my @dir = spellings_abs(glob_dir($abs));
            push @out, @dir;
            next unless $gate && set_inside($gate, @dir);
            my $m = glob_paths($abs);
            if ($m) {
                push @out, spellings_abs($_) for grep { substr($_, 0, 1) eq '/' } @$m;
            } else {
                for my $r (@{ $gate->{abs} }) {
                    push @out, $r if grep { _under_str($r, $_) } @dir;
                }
            }
        }
    }
    return _uniq(@out);
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
