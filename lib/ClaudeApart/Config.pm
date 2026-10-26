package ClaudeApart::Config;
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path);

my $HEADER = "# claude-apart config \xe2\x80\x94 edit freely, then run: claude-apart sync\n";
my @FIELDS = qw(dir tag emoji colour email org can_read protect theme);
my %FIELD  = map { $_ => 1 } @FIELDS;
my %COLOUR = (orange => 208, purple => 135, blue => 33, green => 40, red => 196,
              yellow => 220, pink => 205, cyan => 45, grey => 245);

sub empty { return { default => undef, order => [], profiles => {} } }

sub config_path {
    my $base = (defined $ENV{XDG_CONFIG_HOME} && length $ENV{XDG_CONFIG_HOME})
        ? $ENV{XDG_CONFIG_HOME} : "$ENV{HOME}/.config";
    return "$base/claude-apart/config";
}

sub _trim { my $s = shift; $s =~ s/^\s+//; $s =~ s/\s+$//; return $s }

sub _check_name {
    my ($n) = @_;
    die "bad profile name '$n' (use lowercase letters, digits, dashes; start with a letter)\n"
        unless $n =~ /^[a-z][a-z0-9-]{0,30}$/;
    die "profile name 'apart' is not allowed\n" if $n eq 'apart';
}

sub load {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read config $path: $!\n";
    my $cfg = empty();
    my ($cur, $ln) = (undef, 0);
    while (my $line = <$fh>) {
        $ln++;
        $line =~ s/\r?\n\z//;
        my $t = _trim($line);
        next if $t eq '' || $t =~ /^#/;
        if ($t =~ /^\[(.*)\]$/) {
            my $inner = _trim($1);
            $inner =~ /^profile\s+(\S+)$/ or die "config line $ln: bad section '$t'\n";
            my $n = $1;
            _check_name($n);
            die "config line $ln: duplicate profile '$n'\n" if $cfg->{profiles}{$n};
            $cfg->{profiles}{$n} = {};
            push @{ $cfg->{order} }, $n;
            $cur = $cfg->{profiles}{$n};
            next;
        }
        $t =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/ or die "config line $ln: syntax error: '$t'\n";
        my ($k, $v) = ($1, $2);
        if ($cur) {
            die "config line $ln: unknown key '$k'\n" unless $FIELD{$k};
            $cur->{$k} = $v;
        } else {
            die "config line $ln: unknown key '$k'\n" unless $k eq 'default';
            $cfg->{default} = $v;
        }
    }
    close $fh;
    validate($cfg);
    return $cfg;
}

sub validate {
    my ($cfg) = @_;
    my (%tag, %emoji);
    for my $n (@{ $cfg->{order} }) {
        my $p = $cfg->{profiles}{$n};
        die "profile '$n': missing dir\n" unless defined $p->{dir} && length $p->{dir};
        die "profile '$n': missing tag\n" unless defined $p->{tag} && length $p->{tag};
        die "duplicate tag '$p->{tag}' (profile '$n')\n" if $tag{ $p->{tag} }++;
        if (defined $p->{emoji} && length $p->{emoji}) {
            die "duplicate emoji '$p->{emoji}' (profile '$n')\n" if $emoji{ $p->{emoji} }++;
        }
        if (defined $p->{colour} && length $p->{colour}) {
            die "profile '$n': unknown colour '$p->{colour}'\n"
                unless exists $COLOUR{ $p->{colour} } || $p->{colour} =~ /^\d{1,3}$/;
        }
    }
    if (defined $cfg->{default} && length $cfg->{default}) {
        die "default profile '$cfg->{default}' does not exist\n" unless $cfg->{profiles}{ $cfg->{default} };
    }
}

sub _list { my $s = shift; return grep { length } split /[\s,]+/, (defined $s ? $s : '') }

sub _abs {
    my ($d) = @_;
    my $home = $ENV{HOME};
    $d =~ s{^~(?=/|\z)}{$home};
    $d =~ s{(?<=.)/+\z}{};
    return $d;
}

sub profile_names { my ($cfg) = @_; return @{ $cfg->{order} } }

sub profile {
    my ($cfg, $name) = @_;
    my $r = $cfg->{profiles}{$name} or return undef;
    my %p = map { $_ => (defined $r->{$_} ? $r->{$_} : '') } @FIELDS;
    $p{name}     = $name;
    $p{abs_dir}  = _abs($r->{dir});
    $p{adopted}  = $p{abs_dir} eq "$ENV{HOME}/.claude" ? 1 : 0;
    my $c = $p{colour};
    $p{colour_code} = $c eq '' ? '' : (exists $COLOUR{$c} ? $COLOUR{$c} : $c);
    $p{can_read} = [ _list($r->{can_read}) ];
    $p{protect}  = [ map { _abs($_) } _list($r->{protect}) ];
    return \%p;
}

sub default_profile {
    my ($cfg) = @_;
    return (defined $cfg->{default} && length $cfg->{default}) ? $cfg->{default} : undef;
}

# Absolute paths a profile owns. An entry ending in ".*" names a family: the
# path without ".*" plus every sibling "<that path>.<anything>". The adopted
# profile owns the whole ~/.claude.json family, because Claude Code keeps
# copies of the identity file next to it (.backup, .tmp.<pid>.<hex>).
sub owned_paths {
    my ($cfg, $name) = @_;
    my $p = profile($cfg, $name) or die "unknown profile: $name\n";
    my @o = ($p->{abs_dir});
    push @o, "$ENV{HOME}/.claude.json", "$ENV{HOME}/.claude.json.*" if $p->{adopted};
    push @o, @{ $p->{protect} };
    return @o;
}

sub _uniq { my %s; return grep { !$s{$_}++ } @_ }

sub foreign_paths {
    my ($cfg, $name) = @_;
    my $me = profile($cfg, $name) or die "unknown profile: $name\n";
    my (@write, %readable);
    for my $o (profile_names($cfg)) {
        next if $o eq $name;
        push @write, owned_paths($cfg, $o);
    }
    my $cdir = dirname(config_path());
    push @write, $cdir;
    my %can = map { $_ => 1 } @{ $me->{can_read} };
    my @read;
    for my $o (profile_names($cfg)) {
        next if $o eq $name || $can{$o};
        push @read, owned_paths($cfg, $o);
    }
    push @read, $cdir;
    return ([ _uniq(@read) ], [ _uniq(@write) ]);
}

sub save {
    my ($cfg, $path) = @_;
    validate($cfg);
    my $out = $HEADER;
    $out .= "default = $cfg->{default}\n" if defined $cfg->{default} && length $cfg->{default};
    for my $n (@{ $cfg->{order} }) {
        my $p = $cfg->{profiles}{$n};
        $out .= "\n[profile $n]\n";
        for my $k (@FIELDS) {
            $out .= "$k = $p->{$k}\n" if defined $p->{$k} && length $p->{$k};
        }
    }
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    -d $dir or die "cannot create $dir: $!\n";
    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or die "cannot write $tmp: $!\n";
    print $fh $out or die "write failed: $!\n";
    close $fh or die "write failed: $!\n";
    rename $tmp, $path or do { my $e = $!; unlink $tmp; die "cannot rename to $path: $e\n" };
    return 1;
}

sub set_top {
    my ($cfg, $key, $val) = @_;
    die "unknown key '$key'\n" unless $key eq 'default';
    die "unknown profile: $val\n" unless $cfg->{profiles}{$val};
    $cfg->{default} = $val;
}

sub set_profile {
    my ($cfg, $name, $field, $val) = @_;
    die "unknown profile: $name\n" unless $cfg->{profiles}{$name};
    die "unknown key '$field'\n" unless $FIELD{$field};
    $cfg->{profiles}{$name}{$field} = $val;
    validate($cfg);
}

sub add_profile {
    my ($cfg, $name) = @_;
    _check_name($name);
    die "profile '$name' already exists\n" if $cfg->{profiles}{$name};
    my $tag = uc $name;
    $tag =~ s/-//g;
    $tag = substr($tag, 0, 6);
    $cfg->{profiles}{$name} = { dir => "~/.claude-$name", tag => $tag };
    push @{ $cfg->{order} }, $name;
    validate($cfg);
}

sub remove_profile {
    my ($cfg, $name) = @_;
    die "unknown profile: $name\n" unless $cfg->{profiles}{$name};
    delete $cfg->{profiles}{$name};
    $cfg->{order} = [ grep { $_ ne $name } @{ $cfg->{order} } ];
    $cfg->{default} = undef if defined $cfg->{default} && $cfg->{default} eq $name;
}

1;
