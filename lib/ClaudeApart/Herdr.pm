package ClaudeApart::Herdr;
use strict;
use warnings;
use JSON::PP ();
use ClaudeApart::Config;

my $TIMEOUT = 3;

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

sub workspace_label {
    my ($ws) = @_;
    return undef unless defined $ws && $ws =~ /^[A-Za-z0-9]+$/;
    my ($r, $w);
    pipe($r, $w) or return undef;
    my $pid = fork();
    return undef unless defined $pid;
    if (!$pid) {
        close $r;
        open STDOUT, '>&', $w or exit 127;
        open STDERR, '>', '/dev/null';
        open STDIN,  '<', '/dev/null';
        exec { 'herdr' } 'herdr', 'workspace', 'get', $ws;
        exit 127;
    }
    close $w;
    my $out = '';
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $TIMEOUT;
        local $/;
        $out = <$r>;
        alarm 0;
        1;
    };
    alarm 0;
    if (!$ok) { kill 'KILL', $pid }
    close $r;
    waitpid $pid, 0;
    return undef if !$ok || $? != 0 || !defined $out || !length $out;
    my $d = eval { JSON::PP->new->utf8->decode($out) };
    return undef unless ref $d eq 'HASH';
    my $l = eval { $d->{result}{workspace}{label} };
    return undef unless defined $l && !ref $l && length $l;
    utf8::encode($l);
    return $l;
}

1;
