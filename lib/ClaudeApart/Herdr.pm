package ClaudeApart::Herdr;
use strict;
use warnings;
use JSON::PP ();
use ClaudeApart::Config;
use ClaudeApart::Proc;

my $TIMEOUT = 3;           # seconds for one herdr call
my $MAX_OUT = 1 << 20;     # more output than this is a failure

my $WS   = qr/w[A-Za-z0-9]+/;           # workspace id: w1, wG
my $PANE = qr/\A($WS):p[0-9]+\z/;       # pane id: w1:p1
my $TAB  = qr/\A($WS):t[0-9]+\z/;       # tab id: w1:t1
my $NAME = qr/\A[a-z][a-z0-9_-]{0,31}\z/;    # agent name

# The label must start with "<emoji> <TAG>", then end of string or " · ".
sub profile_for_label {
    my ($cfg, $label) = @_;
    return undef unless defined $label && length $label;
    for my $n (ClaudeApart::Config::profile_names($cfg)) {
        my $p = ClaudeApart::Config::profile($cfg, $n);
        next unless length $p->{emoji} && length $p->{tag};
        my $head = "$p->{emoji} $p->{tag}";
        return $n if $label =~ /^\Q$head\E(?: \xc2\xb7 |\z)/;
    }
    return undef;
}

# Runs `herdr @args` and returns its decoded JSON output (a hash), or undef
# when it cannot start, fails, prints no JSON object or takes longer than
# $TIMEOUT seconds; then it is killed. Inside a hook the supervisor in
# capart.pl owns the only timer signal, so this waits with select and
# waitpid polling instead. herdr stays in our process group, so the
# supervisor's group kill reaches it too. One result per call per process.
my %RUN;
sub _herdr_json {
    my (@args) = @_;
    my $key = join "\0", @args;
    return $RUN{$key} if exists $RUN{$key};
    my $out = _run_herdr(@args);
    my $d = defined $out ? eval { JSON::PP->new->utf8->decode($out) } : undef;
    return $RUN{$key} = ref $d eq 'HASH' ? $d : undef;
}

sub _run_herdr {
    my (@args) = @_;
    return ClaudeApart::Proc::capture({ timeout => $TIMEOUT, max => $MAX_OUT }, "herdr", @args);
}

# A workspace's label ('' when it has none), or undef when the lookup fails
# (bad id, herdr missing, failing or slow, a reply without a label).
sub workspace_label {
    my ($ws) = @_;
    return undef unless defined $ws && $ws =~ /\A[A-Za-z0-9]+\z/;
    my $d = _herdr_json('workspace', 'get', $ws) or return undef;
    my $l = eval { $d->{result}{workspace}{label} };
    return undef unless defined $l && !ref $l;
    utf8::encode($l);
    return $l;
}

# A tab's label ('' when it has none), or undef when the lookup fails.
sub tab_label {
    my ($tab) = @_;
    return undef unless defined $tab && $tab =~ $TAB;
    my $d = _herdr_json('tab', 'get', $tab) or return undef;
    my $l = eval { $d->{result}{tab}{label} };
    return undef unless defined $l && !ref $l;
    utf8::encode($l);
    return $l;
}

# Rename a workspace or a tab. True when herdr accepted it; callers ignore
# failure. Never cached (unlike the lookups).
sub rename_workspace {
    my ($ws, $label) = @_;
    return 0 unless defined $ws && $ws =~ /\A$WS\z/ && defined $label && length $label;
    return defined _run_herdr('workspace', 'rename', $ws, $label) ? 1 : 0;
}

sub rename_tab {
    my ($tab, $label) = @_;
    return 0 unless defined $tab && $tab =~ $TAB && defined $label && length $label;
    return defined _run_herdr('tab', 'rename', $tab, $label) ? 1 : 0;
}

# The pane an agent (by name) is in, from `herdr agent get`, or undef.
sub agent_pane {
    my ($name) = @_;
    return undef unless defined $name && $name =~ $NAME;
    my $d = _herdr_json('agent', 'get', $name) or return undef;
    my $p = eval { $d->{result}{agent}{pane_id} };
    return (defined $p && !ref $p && $p =~ $PANE) ? $p : undef;
}

# ---- parsing herdr commands ---------------------------------------------------

# Read kinds show a pane's content. Input kinds type into a pane, change
# which profile a pane belongs to (rename, close, move), make a new shell
# there (R51: pane split, tab create, worktree create/open; plain `claude` in
# it takes that workspace's profile), or stop panes and agent setups of
# every profile (server, session, integration). Everything else (list, get,
# workspace create, focus, …) is "other"; workspace create only needs an
# own label (R45). A key is the two or three command words after `herdr`.
my %KIND = (
    (map { $_ => 'read' } 'pane read', 'pane wait-output', 'agent read', 'agent wait', 'agent explain',
        'terminal session observe', 'api snapshot'),
    (map { $_ => 'input' } 'pane run', 'pane send-keys', 'pane send-text', 'pane close', 'pane rename',
        'pane move', 'pane swap', 'pane split', 'agent prompt', 'agent send-keys', 'agent start', 'agent rename',
        'agent attach', 'workspace rename', 'workspace close', 'tab create', 'tab rename', 'tab close',
        'worktree create', 'worktree open',
        'terminal session control', 'terminal attach', 'worktree remove', 'session attach',
        'session stop', 'session delete', 'server stop', 'integration install', 'integration uninstall'),
);
# What the first positional after the command words names. Other nouns
# (session, integration, …) have no target that maps to a profile.
my %TYPE = (pane => 'pane', agent => 'agent', workspace => 'workspace', tab => 'tab', terminal => 'terminal');
# Commands that write a workspace label with --label (`workspace rename`
# takes it as a positional; `pane move` only with --new-workspace).
my %LABEL_OPT = map { $_ => 1 } 'workspace create', 'worktree create', 'worktree open';
# Commands that type text into a pane or agent (R54 b): their positionals.
my %TYPED = map { $_ => 1 } 'pane run', 'pane send-text', 'pane send-keys', 'agent prompt', 'agent send-keys';
# Options that take a value, and the kind of id the id options name.
my %ID_OPT = ('--pane' => 'pane', '--source-pane' => 'pane', '--target-pane' => 'pane',
              '--tab' => 'tab', '--workspace' => 'workspace');
my %VALUE_OPT = map { $_ => 1 } keys %ID_OPT, qw(--session --machine --remote --remote-keybindings
    --direction --amount --source --lines --format --right-click --ratio --cwd --env --split --label
    --tab-label --match --regex --timeout --agent --state --message --seq --agent-session-id
    --agent-session-path --applies-to-source --title --display-agent --state-label --token
    --clear-token --ttl-ms --until --kind --file --cols --rows --branch --base --path --body
    --position --sound --output);
my %FLAG_OPT = map { $_ => 1 } qw(--current --toggle --on --off --focus --no-focus --new-tab
    --new-workspace --raw --ansi --clear --clear-title --clear-display-agent --clear-state-labels
    --wait --takeover --json --verbose --group --handoff --force --trust-repository --outdated-only
    --help -h);
my %REMOTE = map { $_ => 1 } qw(--machine --session --remote);    # another server: ids mean other panes

# A word as herdr gets it: $HERDR_PANE_ID, $HERDR_TAB_ID and
# $HERDR_WORKSPACE_ID (also in ${…}) come from the environment; any other
# word with $ or ` in it cannot be known (undef).
sub _value {
    my ($w) = @_;
    if ($w =~ /\A\$(?:(HERDR_(?:PANE|TAB|WORKSPACE)_ID)|\{(HERDR_(?:PANE|TAB|WORKSPACE)_ID)\})\z/) {
        my $v = $ENV{ $1 // $2 };
        return (defined $v && length $v) ? $v : undef;
    }
    return $w =~ /[\$`]/ ? undef : $w;
}

# The kind of the command words at the start of @words, and how many there
# are (3 or 2).
sub _kind {
    my @p = @_;
    for my $n (3, 2) {
        next if @p < $n;
        my $k = $KIND{ join ' ', @p[ 0 .. $n - 1 ] };
        return ($k, $n) if $k;
    }
    return ('other', 2);
}

# The kind (read, input or other) of the command words that start @_.
sub command_kind { return (_kind(@_))[0] }

# The words after `herdr`, as written (quotes removed). Returns
#   kind    => 'read', 'input', 'other', or 'unknown' when a command word
#              cannot be known ($V, `…`, find's {}): that blocks;
#   machine => true when the command goes to another server (--machine,
#              --session, --remote);
#   targets => [[type, id], …] for read and input kinds: the first
#              positional after the command words (not for `agent start`,
#              where it is a new name), every --pane/--source-pane/
#              --target-pane/--tab/--workspace, and --current
#              ($HERDR_PANE_ID). R51 defaults: `pane split` with no pane
#              takes $HERDR_PANE_ID, `worktree create|open` with no
#              --workspace takes $HERDR_WORKSPACE_ID, and `tab create` with
#              no --workspace (and R54 d: `pane move --new-tab` with no
#              --workspace) gets an unknown target. type is 'pane',
#              'agent', 'tab', 'workspace' or 'terminal'; an undef id cannot
#              be known (blocks);
#   target  => the first target id;
#   labels  => the workspace labels the command writes (undef: cannot be
#              known, or herdr picks one itself);
#   env     => the --env values, as written;
#   text    => for commands that type into a pane or agent, every
#              positional after the command words (target and payload).
# An unknown option in a read or input command gives an undef target,
# because it may take the next word as its value.
sub parse_command {
    my ($argv) = @_;
    my @a = @$argv;
    my (@pos, @targets, @labels, %opt);
    my ($machine, $unknown, $opts) = (0, 0, 1);
    while (@a) {
        my $w = shift @a;
        if ($opts && $w eq '--') { $opts = 0; next }
        if ($opts && $w =~ /\A-/) {
            my ($o, $v) = $w =~ /\A(--[^=]+)=(.*)\z/s ? ($1, $2) : ($w, undef);
            $machine = 1 if $REMOTE{$o};
            if ($VALUE_OPT{$o}) {
                $v = shift @a if !defined $v;
                push @{ $opt{$o} }, $v;
            } elsif (!$FLAG_OPT{$o} || defined $v) {
                $unknown = 1;
            } else {
                $opt{$o} = 1;
            }
            next;
        }
        push @pos, $w;
    }
    my %r = (machine => $machine, targets => \@targets, labels => \@labels,
             env => [ @{ $opt{'--env'} || [] } ], text => []);
    my $head = (($pos[0] // '') eq 'terminal' && ($pos[1] // '') eq 'session') ? 3 : 2;
    my @head = @pos > $head ? @pos[ 0 .. $head - 1 ] : @pos;
    if (grep { /[\$`]/ || $_ eq '{}' } @head) {
        $r{kind} = 'unknown';
        return \%r;
    }
    my ($kind, $n) = _kind(@pos);
    my $cmd = @pos >= 2 ? "$pos[0] $pos[1]" : '';
    $kind = 'other' if $cmd eq 'agent explain' && $opt{'--file'} && @pos <= $n;    # reads a file
    $r{kind} = $kind;
    $r{text} = [ @pos[ $n .. $#pos ] ] if $TYPED{$cmd};
    if ($cmd eq 'workspace rename') {
        push @labels, @pos == 4 ? _value($pos[3]) : undef;
    } elsif ($LABEL_OPT{$cmd} || ($cmd eq 'pane move' && $opt{'--new-workspace'})) {
        push @labels, map { defined $_ ? _value($_) : undef } @{ $opt{'--label'} || [undef] };
    }
    return \%r if $kind eq 'other';
    my $first = $pos[$n];
    if (defined $first && $cmd ne 'agent start') {
        my $type = $TYPE{ $pos[0] };
        push @targets, [ $type, defined $type ? _value($first) : undef ];
    }
    for my $o (sort keys %ID_OPT) {
        push @targets, map { [ $ID_OPT{$o}, defined $_ ? _value($_) : undef ] } @{ $opt{$o} || [] };
    }
    push @targets, [ 'pane', _value('$HERDR_PANE_ID') ] if $opt{'--current'};
    push @targets, [ 'pane', _value('$HERDR_PANE_ID') ] if $cmd eq 'pane split' && !@targets;
    push @targets, [ undef, undef ] if $cmd eq 'tab create' && !$opt{'--workspace'};
    push @targets, [ undef, undef ] if $cmd eq 'pane move' && $opt{'--new-tab'} && !$opt{'--workspace'};
    push @targets, [ 'workspace', _value('$HERDR_WORKSPACE_ID') ]
        if $cmd =~ /\Aworktree (?:create|open)\z/ && !$opt{'--workspace'};
    push @targets, [ undef, undef ] if $unknown;
    $r{target} = @targets ? $targets[0][1] : undef;
    return \%r;
}

# The profile a target belongs to (by its workspace's label), or undef.
# $type: 'workspace', 'tab', 'pane', 'terminal' or 'agent' (default). A tab
# or pane id names its workspace before the ":"; an agent name (also in a
# pane place) is looked up with `herdr agent get`. A terminal target must
# be a pane id.
sub profile_of_target {
    my ($cfg, $id, $type) = @_;
    my $ws = _workspace_of($id, $type // 'agent');
    return undef unless defined $ws;
    return profile_for_label($cfg, workspace_label($ws));
}

sub _workspace_of {
    my ($id, $type) = @_;
    return undef unless defined $id;
    return $id =~ /\A$WS\z/ ? $id : undef if $type eq 'workspace';
    return $id =~ $TAB ? $1 : undef if $type eq 'tab';
    return $id =~ $PANE ? $1 : undef if $type eq 'terminal';
    return undef unless $type eq 'pane' || $type eq 'agent';
    return $1 if $id =~ $PANE;
    my $p = agent_pane($id);
    return (defined $p && $p =~ $PANE) ? $1 : undef;
}

1;
