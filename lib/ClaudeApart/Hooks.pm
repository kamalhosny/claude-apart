package ClaudeApart::Hooks;
use strict;
use warnings;
use JSON::PP ();
use Time::HiRes ();
use ClaudeApart::Config;
use ClaudeApart::Guard;

# Entry points for `capart.pl hook <event> --profile NAME`.
# Exit 2 blocks (Claude Code treats every other code as allow), so every
# failure becomes exit 2 with the fixed guard error text. Block messages are
# fixed text: never a path, a profile name or an email.

our $BLOCK_TEXT = "claude-apart: blocked \xe2\x80\x94 this touches another profile.";
our $ERROR_TEXT = "claude-apart: guard error \xe2\x80\x94 blocked to be safe.";

# Claude Code treats a hook that times out (10 s) as allow, so a hook that
# runs too long (huge input) stops itself and blocks.
our $BUDGET = 5;

# Each handler gets the profile name and returns undef (allow) or the text
# to print on stderr with exit 2.
my %EVENT = ('pre-tool' => \&pre_tool);

sub main {
    my (@argv) = @_;
    my $msg;
    my $ok = eval {
        local $SIG{__WARN__} = sub { die "warning: $_[0]" };
        local $SIG{ALRM} = sub { die "guard timeout\n" };
        Time::HiRes::alarm($BUDGET);
        my $event = shift @argv;
        die "no hook event\n" unless defined $event && $EVENT{$event};
        my $profile;
        while (@argv) {
            my $a = shift @argv;
            if ($a eq '--profile' && @argv) { $profile = shift @argv }
            else { die "bad hook argument\n" }
        }
        die "no profile\n" unless defined $profile && length $profile;
        $msg = $EVENT{$event}->($profile);
        Time::HiRes::alarm(0);
        1;
    };
    Time::HiRes::alarm(0);
    unless ($ok) { print STDERR "$ERROR_TEXT\n"; return 2 }
    return 0 unless defined $msg;
    print STDERR "$msg\n";
    return 2;
}

# Hook stdin as a hash. All strings are UTF-8 bytes, like paths on disk.
sub read_input {
    local $/;
    my $raw = <STDIN>;
    die "no hook input\n" unless defined $raw && length $raw;
    my $in = _bytes(JSON::PP->new->utf8->decode($raw));
    die "hook input is not an object\n" unless ref $in eq 'HASH';
    return $in;
}

sub _bytes {
    my ($d) = @_;
    if (ref $d eq 'HASH') {
        my %h;
        for my $k (keys %$d) { my $b = $k; utf8::encode($b); $h{$b} = _bytes($d->{$k}) }
        return \%h;
    }
    return [ map { _bytes($_) } @$d ] if ref $d eq 'ARRAY';
    return $d if ref $d || !defined $d;
    my $s = "$d";
    utf8::encode($s);
    return $s;
}

sub load_config {
    my ($profile) = @_;
    my $cfg = ClaudeApart::Config::load(ClaudeApart::Config::config_path());
    ClaudeApart::Config::profile($cfg, $profile) or die "unknown profile\n";
    return $cfg;
}

sub pre_tool {
    my ($profile) = @_;
    my $in  = read_input();
    my $cfg = load_config($profile);
    my $v = ClaudeApart::Guard::verdict($cfg, $profile, $in->{tool_name}, $in->{tool_input}, $in->{cwd});
    return $v ? $BLOCK_TEXT : undef;
}

1;
