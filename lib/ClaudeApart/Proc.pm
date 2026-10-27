package ClaudeApart::Proc;
use strict;
use warnings;

# Runs a command and returns its output, or undef when it cannot start, exits
# non-zero, prints nothing or takes longer than the deadline; then it is
# killed. Inside a hook the supervisor in capart.pl owns the only timer
# signal, so this waits with select and waitpid polling, never alarm.
#   capture(\%opt, @cmd)   (@cmd is exec'd directly, no shell)
#     timeout => seconds (default 3)
#     max     => output bytes allowed (default 1 MiB; more is a failure)
#     stdin   => a string the command reads (default: /dev/null)
#     group   => true: the command gets its own process group and a timeout
#                kills the whole group (a shell's grandchildren too)
sub capture {
    my ($opt, @cmd) = @_;
    require POSIX;
    require Time::HiRes;
    my $timeout = $opt->{timeout} || 3;
    my $max = $opt->{max} || 1 << 20;
    my $in;
    if (defined $opt->{stdin}) {    # an anonymous temp file: no pipe to fill up
        open $in, '+>', undef or return undef;
        print {$in} $opt->{stdin} or return undef;
        seek($in, 0, 0) or return undef;
    }
    my ($r, $w);
    pipe($r, $w) or return undef;
    my $pid = fork();
    unless (defined $pid) { close $r; close $w; return undef }
    if (!$pid) {
        no warnings 'exec';    # a failed exec returns; the exit code tells
        setpgrp(0, 0) if $opt->{group};
        close $r;
        open STDOUT, '>&', $w or POSIX::_exit(127);
        open STDERR, '>', '/dev/null';
        if ($in) { open STDIN, '<&', $in or POSIX::_exit(127) }
        else     { open STDIN, '<', '/dev/null' }
        exec { $cmd[0] } @cmd or POSIX::_exit(127);
    }
    setpgrp($pid, $pid) if $opt->{group};    # both sides, so a kill never races
    close $w;
    my $deadline = Time::HiRes::time() + $timeout;
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
            if ($got) { $out .= $buf; last if length $out > $max } else { $eof = 1 }
            next;
        }
        my $done = waitpid($pid, POSIX::WNOHANG());
        if ($done == $pid) { $status = $?; last }
        last if $done < 0;
        select(undef, undef, undef, 0.005);
    }
    close $r;
    unless (defined $status) {
        $opt->{group} ? (kill('KILL', -$pid) or kill('KILL', $pid)) : kill('KILL', $pid);
        waitpid($pid, 0);
        return undef;
    }
    return ($status == 0 && length $out && length $out <= $max) ? $out : undef;
}

1;
