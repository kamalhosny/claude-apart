package ClaudeApart::Herdr;
use strict;
use warnings;
use JSON::PP ();
use ClaudeApart::Config;

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
    require POSIX;
    require Time::HiRes;
    my ($r, $w);
    pipe($r, $w) or return undef;
    my $pid = fork();
    unless (defined $pid) { close $r; close $w; return undef }
    if (!$pid) {
        no warnings 'exec';    # a failed exec returns; the exit code tells
        close $r;
        open STDOUT, '>&', $w or POSIX::_exit(127);
        open STDERR, '>', '/dev/null';
        open STDIN,  '<', '/dev/null';
        exec { 'herdr' } 'herdr', @args or POSIX::_exit(127);
    }
    close $w;
    my $deadline = Time::HiRes::time() + $TIMEOUT;
    my ($out, $eof, $status) = ('', 0, undef);
    while (1) {
        my $left = $deadline - Time::HiRes::time();
        last if $left <= 0;
        if (!$eof) {    # read until end of file, at most until the deadline
            my $rin = '';
            vec($rin, fileno($r), 1) = 1;
            my $n = select(my $rout = $rin, undef, undef, $left);
            next if $n < 0 && $!{EINTR};
            last if $n < 0;
            next unless $n;
            my $got = sysread($r, my $buf, 65536);
            next if !defined $got && $!{EINTR};
            last unless defined $got;
            if ($got) { $out .= $buf; last if length $out > $MAX_OUT } else { $eof = 1 }
            next;
        }
        my $done = waitpid($pid, POSIX::WNOHANG());
        if ($done == $pid) { $status = $?; last }
        last if $done < 0;
        select(undef, undef, undef, 0.005);
    }
    close $r;
    unless (defined $status) { kill 'KILL', $pid; waitpid($pid, 0); return undef }
    return ($status == 0 && length $out) ? $out : undef;
}

sub workspace_label {
    my ($ws) = @_;
    return undef unless defined $ws && $ws =~ /\A[A-Za-z0-9]+\z/;
    my $d = _herdr_json('workspace', 'get', $ws) or return undef;
    my $l = eval { $d->{result}{workspace}{label} };
    return undef unless defined $l && !ref $l && length $l;
    utf8::encode($l);
    return $l;
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

# Read kinds show a pane's content; input kinds type into a pane or change
# which profile a pane belongs to (rename, close, move). Everything else
# (list, get, create, split, focus, …) is "other".
my %KIND = (
    (map { $_ => 'read' } 'pane read', 'pane wait-output', 'agent read', 'agent wait', 'agent explain'),
    (map { $_ => 'input' } 'pane run', 'pane send-keys', 'pane send-text', 'pane close', 'pane rename',
        'pane move', 'pane swap', 'agent prompt', 'agent send-keys', 'agent start', 'agent rename',
        'agent attach', 'workspace rename', 'workspace close', 'tab rename', 'tab close'),
);
# Options that take a value, and the kind of id the id options name.
my %ID_OPT = ('--pane' => 'pane', '--source-pane' => 'pane', '--target-pane' => 'pane',
              '--tab' => 'tab', '--workspace' => 'workspace');
my %VALUE_OPT = map { $_ => 1 } keys %ID_OPT, qw(--session --machine --remote --remote-keybindings
    --direction --amount --source --lines --format --right-click --ratio --cwd --env --split --label
    --tab-label --match --regex --timeout --agent --state --message --seq --agent-session-id
    --agent-session-path --applies-to-source --title --display-agent --state-label --token
    --clear-token --ttl-ms --until --kind --file);
my %FLAG_OPT = map { $_ => 1 } qw(--current --toggle --on --off --focus --no-focus --new-tab
    --new-workspace --raw --ansi --clear --clear-title --clear-display-agent --clear-state-labels
    --wait --takeover --json --verbose --group --handoff --help -h);
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

# The words after `herdr`, as written (quotes removed). Returns
#   kind    => 'read', 'input' or 'other';
#   machine => true when the command goes to another server (--machine,
#              --session, --remote);
#   targets => [[type, id], …] for read and input kinds: the first
#              positional (not for `agent start`, where it is a new name),
#              every --pane/--source-pane/--target-pane/--tab/--workspace,
#              and --current ($HERDR_PANE_ID). type is 'pane', 'agent',
#              'tab' or 'workspace'; an undef id cannot be known (blocks);
#   target  => the first target id;
#   labels  => new workspace labels the command sets (undef: cannot be known).
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
    my ($noun, $verb) = @pos;
    my $kind = (defined $verb && $KIND{"$noun $verb"}) || 'other';
    my %r = (kind => $kind, machine => $machine, targets => \@targets, labels => \@labels);
    return \%r if $kind eq 'other';
    my $first = $pos[2];
    if (defined $first && "$noun $verb" ne 'agent start') {
        push @targets, [ $noun, _value($first) ];
    }
    for my $o (sort keys %ID_OPT) {
        push @targets, map { [ $ID_OPT{$o}, defined $_ ? _value($_) : undef ] } @{ $opt{$o} || [] };
    }
    push @targets, [ 'pane', _value('$HERDR_PANE_ID') ] if $opt{'--current'};
    push @targets, [ undef, undef ] if $unknown;
    push @labels, _value($pos[3]) if "$noun $verb" eq 'workspace rename' && defined $pos[3];
    push @labels, map { defined $_ ? _value($_) : undef } @{ $opt{'--label'} || [] }
        if "$noun $verb" eq 'pane move' && $opt{'--new-workspace'};
    $r{target} = @targets ? $targets[0][1] : undef;
    return \%r;
}

# The profile a target belongs to (by its workspace's label), or undef.
# $type: 'workspace', 'tab', 'pane' or 'agent' (default). A tab or pane id
# names its workspace before the ":"; an agent name (also in a pane place)
# is looked up with `herdr agent get`.
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
    return undef unless $type eq 'pane' || $type eq 'agent';
    return $1 if $id =~ $PANE;
    my $p = agent_pane($id);
    return (defined $p && $p =~ $PANE) ? $1 : undef;
}

1;
