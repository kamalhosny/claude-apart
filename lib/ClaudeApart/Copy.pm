package ClaudeApart::Copy;
use strict;
use warnings;
use File::Basename qw(dirname);
use JSON::PP ();
use ClaudeApart::Config;
use ClaudeApart::Paths;
use ClaudeApart::Settings;

# The logic behind `claude-apart copy`: list what one profile could hand to
# another, and copy one chosen item. Only a fixed set of kinds exists (memory
# notes, skills, agents, commands, output styles, CLAUDE.md, hooks, status line
# and three plain settings), so history, transcripts, sessions, credentials and
# claude-apart's own files can never be listed or copied.
#
# Source side: a symlink is followed only when it resolves inside the source
# folder (its content is copied, not the link); any other link is skipped.
# Target side: every write goes under the target's canonical folder, step by
# step, and stops at any symlink on the way. Settings go through
# Settings::modify (the guarded atomic writer).

my $PREVIEW_LINES = 8;
my @DIR_KINDS = (['skill', 'skills'], ['agent', 'agents'], ['command', 'commands'], ['output-style', 'output-styles']);
my %NEVER_NAME = map { $_ => 1 } ('.claude-apart-state.json', 'settings.json.claude-apart.bak', '.claude.json', '.credentials.json');
my $OURS_RE = qr/capart\.pl' (?:hook (?:pre-tool|prompt|session-start)|statusline) --profile /;

sub _never_name {
    my ($n) = @_;
    return $NEVER_NAME{$n} || $n =~ /\.tmp\./ || $n =~ /\.jsonl\z/ ? 1 : 0;
}

# ---- ids and paths -------------------------------------------------------------

sub _check_rel {
    my ($r) = @_;
    die "not a valid item id\n"
        if !defined $r || !length $r || $r =~ m{\A/} || $r =~ m{/\z} || $r =~ m{//} || $r =~ /\.\./
        || $r =~ /[\x00-\x1f\x7f]/ || $r =~ m{(?:\A|/)\.(?:/|\z)};
    return $r;
}

sub _inside { my ($path, $canon_root) = @_; return index(ClaudeApart::Paths::canon($path), "$canon_root/") == 0 }

# Source readability: a plain entry, or a link that resolves inside the source folder.
sub _src_ok {
    my ($path, $sroot) = @_;
    return 1 unless -l $path;
    return -e $path && _inside($path, $sroot) ? 1 : 0;
}

# Walks the target path component by component; any symlink stops it. With $mk
# the missing parent folders are made (one at a time, so each is checked).
sub _target_path {
    my ($tcan, $rel, $mk) = @_;
    _check_rel($rel);
    die "the target folder is missing\n" unless -d $tcan;
    my @c = split m{/}, $rel;
    my $cur = $tcan;
    for my $i (0 .. $#c) {
        $cur .= "/$c[$i]";
        die "refusing to write through a symlink ($rel)\n" if -l $cur;
        if ($i < $#c) {
            if (-e $cur) { -d $cur or die "not a folder in the target ($rel)\n" }
            elsif ($mk) { mkdir $cur, 0755 or die "cannot make a folder in the target: $!\n" }
        }
    }
    die "the target is a folder ($rel)\n" if -d $cur;
    return $cur;
}

sub _slurp {
    my ($f) = @_;
    open my $fh, '<', $f or die "cannot read $f: $!\n";
    binmode $fh;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return defined $raw ? $raw : '';
}

sub _put {
    my ($tcan, $rel, $bytes, $mode) = @_;
    my $p = _target_path($tcan, $rel, 1);
    ClaudeApart::Settings::_write_atomic($p, $bytes, $mode);
}

sub _mode_of { my ($f) = @_; return ((stat $f)[2] & 0755) | 0600 }

# ---- display helpers -------------------------------------------------------------

# One printable line: control characters (and C1) become "?"; length cut.
sub _clean {
    my ($s) = @_;
    $s =~ s/\xc2[\x80-\x9f]/?/g;
    $s =~ s/[\x00-\x1f\x7f]/?/g;
    $s = substr($s, 0, 200) . '...' if length $s > 203;
    return $s;
}

# First lines of a file as a preview (list of clean lines).
sub _head {
    my ($f) = @_;
    my @l;
    if (open my $fh, '<', $f) {
        binmode $fh;
        while (@l < $PREVIEW_LINES && defined(my $line = <$fh>)) { $line =~ s/\r?\n\z//; push @l, _clean($line) }
    }
    return @l;
}

sub _frontmatter {
    my ($f) = @_;
    my %fm;
    open my $fh, '<', $f or return %fm;
    my $first = <$fh>;
    return %fm unless defined $first && $first =~ /\A---\s*\z/;
    while (defined(my $l = <$fh>)) {
        last if $l =~ /\A---\s*\z/;
        if ($l =~ /\A(name|description):\s*(.*?)\s*\z/) {
            my ($k, $v) = ($1, $2);
            $v =~ s/\A(["'])(.*)\1\z/$2/;
            $fm{$k} = $v;
        }
    }
    return %fm;
}

# ---- source reading ---------------------------------------------------------------

sub _profile {
    my ($cfg, $name) = @_;
    return ClaudeApart::Config::profile($cfg, $name) || die "unknown profile: $name\n";
}

sub _state_listed {
    my ($dir) = @_;
    my %l;
    my $f = "$dir/.claude-apart-state.json";
    return \%l unless -f $f && !-l $f;
    my $st = eval { ClaudeApart::Settings::_read_json($f, 'state') } or return \%l;
    $l{$_} = 1 for grep { defined && !ref } values %{ ref $st->{hooks} eq 'HASH' ? $st->{hooks} : {} };
    my $sl = $st->{statusLine_set};
    $l{ $sl->{command} } = 1 if ref $sl eq 'HASH' && defined $sl->{command} && !ref $sl->{command};
    return \%l;
}

sub _is_ours {
    my ($cmd, @listed) = @_;
    return 0 unless defined $cmd && !ref $cmd;
    return 1 if $cmd =~ $OURS_RE;
    return (grep { $_->{$cmd} } @listed) ? 1 : 0;
}

sub _src_settings {
    my ($sroot) = @_;
    my $f = "$sroot/settings.json";
    return {} unless -e $f || -l $f;
    return {} unless _src_ok($f, $sroot) && -f $f;
    my $d = eval { ClaudeApart::Settings::_read_json($f, 'settings.json') };
    return ref $d eq 'HASH' ? $d : {};
}

# ---- command rewriting -------------------------------------------------------------

# The spellings of a folder in a command: absolute (literal and real), ~/, $HOME/, ${HOME}/.
sub _spell {
    my ($abs) = @_;
    my $canon = ClaudeApart::Paths::canon($abs);
    my %m = ($abs => $abs, $canon => $abs);
    my $home = $ENV{HOME};
    if (defined $home && length $home) {
        for my $h ($home, ClaudeApart::Paths::canon($home)) {
            next unless index($abs, "$h/") == 0;
            my $rel = substr($abs, length($h) + 1);
            $m{"~/$rel"} = "~/$rel";
            $m{"\$HOME/$rel"} = "\$HOME/$rel";
            $m{"\${HOME}/$rel"} = "\${HOME}/$rel";
        }
    }
    return \%m;
}

# Rewrite source spellings to target spellings. Returns the new text and the
# relative paths (under the source folder) that the text points at.
sub _rewrite {
    my ($cmd, $sabs, $tabs) = @_;
    my $sm = _spell($sabs);
    my $thome = $ENV{HOME};
    my $trel = defined $thome && index($tabs, "$thome/") == 0 ? substr($tabs, length($thome) + 1) : undef;
    my %to = ($sabs => $tabs, ClaudeApart::Paths::canon($sabs) => ClaudeApart::Paths::canon($tabs));
    my $srel = defined $thome && index($sabs, "$thome/") == 0 ? substr($sabs, length($thome) + 1) : undef;
    if (defined $trel && defined $srel) { %to = (%to, "~/$srel" => "~/$trel", "\$HOME/$srel" => "\$HOME/$trel", "\${HOME}/$srel" => "\${HOME}/$trel") }
    my @alt = sort { length $b <=> length $a } keys %$sm;
    my $re = join '|', map { quotemeta } @alt;
    my @files;
    my $out = $cmd;
    $out =~ s{(?<![\w./~\-])($re)(?![\w.\-])((?:/[^\s'"`;|&<>()\$\\*?]+)*)}{
        my ($sp, $tail) = ($1, $2);
        push @files, substr($tail, 1) if length $tail;
        (exists $to{$sp} ? $to{$sp} : $sp) . $tail
    }ge;
    return ($out, @files);
}

# ---- listing ------------------------------------------------------------------------

sub _kind_file { my ($k) = @_; return $k eq 'claude-md' }

sub items {
    my ($cfg, $from, $to) = @_;
    my $fp = _profile($cfg, $from);
    my $tp = _profile($cfg, $to);
    die "choose two different profiles\n" if $from eq $to;
    my $sdir = $fp->{abs_dir};
    -d $sdir or die "the source folder is missing\n";
    my $sroot = ClaudeApart::Paths::canon($sdir);
    my $tcan = ClaudeApart::Paths::canon($tp->{abs_dir});
    my @out;
    my $add = sub {
        my ($kind, $id, $label, $prev) = @_;
        return if $id =~ /[\x00-\x1f\x7f]/ || $id =~ /\.\./;
        my $note = '';
        $note = " (replaces what $to already has)" if $kind =~ /\A(?:memory|skill|agent|command|output-style|claude-md)\z/ && -e "$tcan/$id";
        push @out, { kind => $kind, id => $id, label => _clean($label) . $note, preview => $prev };
    };

    # memory notes
    if (opendir my $pd, "$sroot/projects") {
        for my $proj (sort grep { !/\A\./ } readdir $pd) {
            my $mdir = "$sroot/projects/$proj/memory";
            next unless -d $mdir && _src_ok("$sroot/projects/$proj", $sroot) && _src_ok($mdir, $sroot);
            opendir my $md, $mdir or next;
            for my $f (sort grep { /\.md\z/ && $_ ne 'MEMORY.md' && !/\A\./ } readdir $md) {
                my $p = "$mdir/$f";
                next unless -f $p && _src_ok($p, $sroot) && !_never_name($f);
                my %fm = _frontmatter($p);
                my $label = defined $fm{name} && length $fm{name} ? $fm{name} : $f;
                $label .= " — $fm{description}" if defined $fm{description} && length $fm{description};
                $add->('memory', "projects/$proj/memory/$f", $label, [ _head($p) ]);
            }
        }
    }

    # skills, agents, commands, output styles
    for my $dk (@DIR_KINDS) {
        my ($kind, $d) = @$dk;
        opendir my $dh, "$sroot/$d" or next;
        for my $n (sort grep { !/\A\./ } readdir $dh) {
            my $p = "$sroot/$d/$n";
            next if _never_name($n) || !_src_ok($p, $sroot);
            my @prev;
            if (-d $p) { @prev = -f "$p/SKILL.md" ? _head("$p/SKILL.md") : _listing($p) }
            elsif (-f $p) { @prev = _head($p) }
            else { next }
            $add->($kind, "$d/$n", "$d/$n", \@prev);
        }
    }

    if (-f "$sroot/CLAUDE.md" && _src_ok("$sroot/CLAUDE.md", $sroot)) {
        $add->('claude-md', 'CLAUDE.md', 'CLAUDE.md', [ _head("$sroot/CLAUDE.md") ]);
    }

    # settings.json: hooks, status line, plain settings
    my $s = _src_settings($sroot);
    my @listed = (_state_listed($sdir), _state_listed($tp->{abs_dir}));
    if (ref $s->{hooks} eq 'HASH') {
        for my $ev (sort keys %{ $s->{hooks} }) {
            next unless ref $s->{hooks}{$ev} eq 'ARRAY' && $ev =~ /\A\w+\z/;
            my $i = -1;
            for my $g (@{ $s->{hooks}{$ev} }) {
                $i++;
                my @h = _own_free($g, @listed) or next;
                my @prev = map { _clean(ref $_ eq 'HASH' && defined $_->{command} && !ref $_->{command} ? $_->{command} : JSON::PP->new->canonical->encode($_)) } @h;
                splice @prev, $PREVIEW_LINES;
                my $m = ref $g eq 'HASH' && defined $g->{matcher} && !ref $g->{matcher} ? " (matcher $g->{matcher})" : '';
                $add->('hook', "$ev#$i", "$ev#$i$m", \@prev);
            }
        }
    }
    my $sl = $s->{statusLine};
    if (ref $sl eq 'HASH' && defined $sl->{command} && !ref $sl->{command} && length $sl->{command} && !_is_ours($sl->{command}, @listed)) {
        $add->('statusline', 'statusLine', 'status line', [ _clean($sl->{command}) ]);
    }
    my $tst = _read_state_quiet($tp->{abs_dir});
    for my $k (qw(model theme)) {
        next unless defined $s->{$k} && !ref $s->{$k} && length $s->{$k};
        next if $k eq 'theme' && $tst && exists $tst->{theme_set};    # the profile's theme belongs to claude-apart
        $add->('setting', $k, "$k = $s->{$k}", [ _clean("$k = $s->{$k}") ]);
    }
    if (ref $s->{enabledPlugins} eq 'HASH' && %{ $s->{enabledPlugins} }) {
        my @p = map { _clean("$_ = " . JSON::PP->new->allow_nonref->encode($s->{enabledPlugins}{$_})) } sort keys %{ $s->{enabledPlugins} };
        splice @p, $PREVIEW_LINES;
        $add->('setting', 'enabledPlugins', 'enabledPlugins', \@p);
    }
    return @out;
}

sub _read_state_quiet {
    my ($dir) = @_;
    my $f = "$dir/.claude-apart-state.json";
    return undef unless -f $f && !-l $f;
    return eval { ClaudeApart::Settings::_read_json($f, 'state') };
}

sub _listing {
    my ($d) = @_;
    my @l;
    if (opendir my $dh, $d) {
        for my $n (sort grep { !/\A\./ } readdir $dh) { push @l, _clean($n) . (-d "$d/$n" ? '/' : ''); last if @l >= $PREVIEW_LINES }
    }
    return @l;
}

# The hook entries of one group that are not claude-apart's.
sub _own_free {
    my ($g, @listed) = @_;
    return () unless ref $g eq 'HASH' && ref $g->{hooks} eq 'ARRAY';
    return grep { !(ref $_ eq 'HASH' && _is_ours($_->{command}, @listed)) } @{ $g->{hooks} };
}

# TSV: kind, id, label, preview (newlines as \n, backslashes doubled).
sub list_tsv {
    my ($cfg, $from, $to) = @_;
    my @lines;
    for my $it (items($cfg, $from, $to)) {
        my $prev = join "\n", @{ $it->{preview} };
        $prev = '(empty)' unless length $prev;
        $prev =~ s/\\/\\\\/g;
        $prev =~ s/\n/\\n/g;
        $prev =~ s/\t/ /g;
        my $label = $it->{label};
        $label =~ s/\t/ /g;
        $label = $it->{id} unless length $label;
        push @lines, join("\t", $it->{kind}, $it->{id}, $label, $prev) . "\n";
    }
    return @lines;
}

# ---- applying -----------------------------------------------------------------------

# Copies one item. Returns a short result line. Dies with a message on refusal.
sub apply {
    my ($cfg, $from, $to, $kind, $id) = @_;
    _check_rel($id) unless $kind eq 'hook' || $kind eq 'setting' || $kind eq 'statusline';
    my ($it) = grep { $_->{kind} eq $kind && $_->{id} eq $id } items($cfg, $from, $to);
    die "that is not an item that can be copied\n" unless $it;
    my $fp = _profile($cfg, $from);
    my $tp = _profile($cfg, $to);
    my $sroot = ClaudeApart::Paths::canon($fp->{abs_dir});
    my $tcan = ClaudeApart::Paths::canon($tp->{abs_dir});
    -d $tcan or die "the target folder is missing\n";

    if ($kind eq 'memory') { _copy_memory($sroot, $tcan, $id) }
    elsif ($kind eq 'claude-md') { _copy_file($sroot, $tcan, $id) }
    elsif ($kind =~ /\A(?:skill|agent|command|output-style)\z/) {
        if (-d "$sroot/$id") { _copy_tree($sroot, $tcan, $id, 0) } else { _copy_file($sroot, $tcan, $id) }
    }
    elsif ($kind eq 'hook') { _copy_hook($cfg, $fp, $tp, $sroot, $tcan, $to, $id) }
    elsif ($kind eq 'statusline') { return _copy_statusline($cfg, $fp, $tp, $sroot, $tcan, $to) }
    elsif ($kind eq 'setting') { _copy_setting($cfg, $fp, $to, $sroot, $id) }
    else { die "unknown kind\n" }
    return "copied $kind $id";
}

sub _copy_file {
    my ($sroot, $tcan, $rel) = @_;
    my $src = "$sroot/$rel";
    _src_ok($src, $sroot) && -f $src or die "cannot read $rel\n";
    _put($tcan, $rel, _slurp($src), _mode_of($src));
}

sub _copy_tree {
    my ($sroot, $tcan, $rel, $depth) = @_;
    die "folder too deep ($rel)\n" if $depth > 12;
    my $dir = "$sroot/$rel";
    opendir my $dh, $dir or die "cannot read $rel: $!\n";
    for my $n (sort grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
        next if _never_name($n) || $n =~ /[\x00-\x1f\x7f]/ || $n =~ /\.\./;
        my $p = "$dir/$n";
        next unless _src_ok($p, $sroot);
        if (-d $p) { _copy_tree($sroot, $tcan, "$rel/$n", $depth + 1) }
        elsif (-f $p) { _copy_file($sroot, $tcan, "$rel/$n") }
    }
}

sub _copy_memory {
    my ($sroot, $tcan, $id) = @_;
    $id =~ m{\Aprojects/([^/]+)/memory/([^/]+)\z} or die "not a memory note\n";
    my ($proj, $file) = ($1, $2);
    my $src = "$sroot/$id";
    _src_ok($src, $sroot) && -f $src or die "cannot read $id\n";
    my $idx_rel = "projects/$proj/memory/MEMORY.md";
    my $idx_path = _target_path($tcan, $idx_rel, 0);    # refuse early if it is a link
    my $have = -e $idx_path ? _slurp($idx_path) : '';
    my $add;
    if ($have !~ /\(\Q$file\E\)/) {
        my $sidx = "$sroot/$idx_rel";
        if (-f $sidx && _src_ok($sidx, $sroot)) {
            for my $l (split /\n/, _slurp($sidx)) { if ($l =~ /\(\Q$file\E\)/) { $add = $l; last } }
        }
        unless (defined $add) {
            my %fm = _frontmatter($src);
            (my $base = $file) =~ s/\.md\z//;
            my $name = defined $fm{name} && length $fm{name} ? $fm{name} : $base;
            $add = "- [$name]($file)" . (defined $fm{description} && length $fm{description} ? " — $fm{description}" : '');
        }
    }
    _put($tcan, $id, _slurp($src), _mode_of($src));
    if (defined $add) {
        $have .= "\n" if length $have && $have !~ /\n\z/;
        _put($tcan, $idx_rel, "$have$add\n", -e $idx_path ? ((stat $idx_path)[2] & 07777) : 0644);
    }
}

# Copies the files a command points at under the source folder; returns the
# command rewritten for the target.
sub _carry_files {
    my ($cmd, $fp, $tp, $sroot, $tcan) = @_;
    my ($new, @files) = _rewrite($cmd, $fp->{abs_dir}, $tp->{abs_dir});
    my %seen;
    for my $rel (grep { !$seen{$_}++ } @files) {
        next unless eval { _check_rel($rel); 1 };
        my $src = "$sroot/$rel";
        next unless -f $src && _src_ok($src, $sroot) && !_never_name((split m{/}, $rel)[-1]);
        _copy_file($sroot, $tcan, $rel);
    }
    return $new;
}

sub _copy_hook {
    my ($cfg, $fp, $tp, $sroot, $tcan, $to, $id) = @_;
    $id =~ /\A(\w+)#(\d+)\z/ or die "not a hook id\n";
    my ($ev, $i) = ($1, $2);
    my @listed = (_state_listed($fp->{abs_dir}), _state_listed($tp->{abs_dir}));
    my $g = (ref _src_settings($sroot)->{hooks} eq 'HASH' && ref _src_settings($sroot)->{hooks}{$ev} eq 'ARRAY') ? _src_settings($sroot)->{hooks}{$ev}[$i] : undef;
    my @h = _own_free($g, @listed) or die "that hook cannot be copied\n";
    my $enc = JSON::PP->new->canonical;
    my @new;
    for my $e (@h) {
        my $c = $enc->decode($enc->encode($e));    # deep copy
        $c->{command} = _carry_files($c->{command}, $fp, $tp, $sroot, $tcan) if ref $c eq 'HASH' && defined $c->{command} && !ref $c->{command};
        push @new, $c;
    }
    my $group = $enc->decode($enc->encode($g));
    $group->{hooks} = \@new;
    ClaudeApart::Settings::modify($cfg, $to, sub {
        my ($d) = @_;
        $d->{hooks} = {} unless ref $d->{hooks} eq 'HASH';
        my $list = ($d->{hooks}{$ev} ||= []);
        my $want = $enc->encode($group);
        push @$list, $group unless grep { $enc->encode($_) eq $want } @$list;
    });
}

sub _copy_statusline {
    my ($cfg, $fp, $tp, $sroot, $tcan, $to) = @_;
    my $sl = _src_settings($sroot)->{statusLine};
    my $enc = JSON::PP->new->canonical;
    my $new = $enc->decode($enc->encode($sl));
    $new->{command} = _carry_files($new->{command}, $fp, $tp, $sroot, $tcan);
    my $result = "copied statusline";
    ClaudeApart::Settings::modify($cfg, $to, sub {
        my ($d, $st) = @_;
        my $cur = $d->{statusLine};
        my $ours = ref $cur eq 'HASH' && defined $cur->{command} && !ref $cur->{command}
            && ($cur->{command} =~ /capart\.pl' statusline --profile / || _is_ours($cur->{command}, _state_listed($tp->{abs_dir})));
        if ($ours) {
            # keep the badge; the copied command becomes the chained original
            (my $base = $cur->{command}) =~ s/ --chain '(?:[^']|'\\'')*'\z//;
            $cur->{command} = "$base --chain " . ClaudeApart::Settings::_shq($new->{command});
            $st->{statusLine_original} = $new if $st;
            $result = "copied statusline (chained behind the claude-apart badge)";
        } else {
            $d->{statusLine} = $new;
        }
    });
    return $result;
}

sub _copy_setting {
    my ($cfg, $fp, $to, $sroot, $id) = @_;
    my $s = _src_settings($sroot);
    ClaudeApart::Settings::modify($cfg, $to, sub {
        my ($d) = @_;
        if ($id eq 'enabledPlugins') {
            $d->{enabledPlugins} = {} unless ref $d->{enabledPlugins} eq 'HASH';
            $d->{enabledPlugins}{$_} = $s->{enabledPlugins}{$_} for keys %{ $s->{enabledPlugins} };
        } else {
            $d->{$id} = $s->{$id};
        }
    });
}

1;
