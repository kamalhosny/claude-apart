package ClaudeApart::Hooks;
use strict;
use warnings;
use JSON::PP ();
use ClaudeApart::Config;
use ClaudeApart::Guard;
use ClaudeApart::Identity;
use ClaudeApart::Herdr;

# Entry points for `capart.pl hook <event> --profile NAME`.
# Exit 2 blocks (Claude Code treats every other code as allow), so every
# failure becomes exit 2 with the fixed guard error text. Block messages are
# fixed text: never a path, another profile's name or an email (the identity
# text holds the own profile name). One exception: the prompt @-mention block
# repeats the path the user typed in that prompt. The time budget is
# enforced by the supervisor process in capart.pl.

our $BLOCK_TEXT = "claude-apart: blocked \xe2\x80\x94 this touches another profile.";
our $ERROR_TEXT = "claude-apart: guard error \xe2\x80\x94 blocked to be safe.";

# Same words as the launcher's refusal. Never the actual email.
sub identity_text { return "claude-apart: this session is not logged in to the account recorded for this profile. Run: claude-apart login $_[0]" }

# Each handler gets the profile name and returns undef (allow) or the text
# to print on stderr with exit 2.
my %EVENT = ('pre-tool' => \&pre_tool, 'prompt' => \&prompt);

sub main {
    my (@argv) = @_;
    my $event = $argv[0];
    return session_start_main(@argv) if defined $event && $event eq 'session-start';
    my $msg;
    my $ok = eval {
        local $SIG{__WARN__} = sub { die "warning: $_[0]" };
        shift @argv;
        die "no hook event\n" unless defined $event && $EVENT{$event};
        my $profile;
        while (@argv) {
            my $a = shift @argv;
            if ($a eq '--profile' && @argv) { $profile = shift @argv }
            else { die "bad hook argument\n" }
        }
        die "no profile\n" unless defined $profile && length $profile;
        $msg = $EVENT{$event}->($profile);
        1;
    };
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
    my $id = identity_block($profile);    # before any guard rule
    return $id if defined $id;
    my $in  = read_input();
    my $cfg = load_config($profile);
    my $v = ClaudeApart::Guard::verdict($cfg, $profile, $in->{tool_name}, $in->{tool_input}, $in->{cwd});
    return $v ? $BLOCK_TEXT : undef;
}

# The block text when the login does not match the profile, else undef.
sub identity_block {
    my ($profile) = @_;
    my ($st) = ClaudeApart::Identity::check($profile);
    return $st eq 'ok' ? undef : identity_text($profile);
}

sub prompt {
    my ($profile) = @_;
    my $id = identity_block($profile);
    return $id if defined $id;
    # R75 (F9): Claude Code reads an @-mentioned file into the prompt by itself
    # (no tool call, so the guard never sees it). Block a mention that resolves
    # into what this profile may not read, judged like a Read of that path.
    my $in = read_input();
    my $text = $in->{prompt};
    return undef unless defined $text && !ref $text && index($text, '@') >= 0;
    my $cwd = (defined $in->{cwd} && !ref $in->{cwd} && $in->{cwd} =~ m{\A/}) ? $in->{cwd} : $ENV{HOME};
    my $cfg = load_config($profile);
    for my $m (at_mentions($text)) {
        for my $p (_mention_forms($m)) {
            next unless ClaudeApart::Guard::verdict($cfg, $profile, 'Read', { file_path => $p }, $cwd);
            (my $show = $m) =~ s/[\x00-\x1f\x7f]/?/g;
            $show = substr($show, 0, 200) . '...' if length $show > 200;
            return "claude-apart: blocked \xe2\x80\x94 the prompt mentions \@$show, which this profile may not read.";
        }
    }
    return undef;
}

# The @-mention tokens of a prompt: `@path` or `@"path with spaces"`, at the
# start or after white space (so an email address is not one).
sub at_mentions {
    my ($t) = @_;
    my @m;
    while ($t =~ /(?:\A|(?<=\s))\@(?:"([^"\n]*)"|(\S+))/g) {
        my $p = defined $1 ? $1 : $2;
        push @m, $p if length $p;
    }
    return @m;
}

# A mention as written, without trailing punctuation, and without a #L line range.
sub _mention_forms {
    my ($m) = @_;
    (my $a = $m) =~ s/[,.;:!?)\]}'"]+\z//;
    my @f = ($m, $a);
    push @f, map { (my $b = $_) =~ s/#L?\d[\d-]*\z//; $b } @f;
    my %seen;
    return grep { length $_ && !$seen{$_}++ } @f;
}

# SessionStart never blocks: every path ends in exit 0, whatever fails
# (bad profile, herdr missing or slow). Its stdin is not read.
sub session_start_main {
    my (@argv) = @_;
    my $msgs = eval {
        local $SIG{__WARN__} = sub { };
        shift @argv;
        my $profile;
        while (@argv) {
            my $a = shift @argv;
            if ($a eq '--profile' && @argv) { $profile = shift @argv } else { die "bad hook argument\n" }
        }
        die "no profile\n" unless defined $profile && length $profile;
        session_start($profile);
    };
    # F14: a config or profile that cannot be loaded makes every tool call
    # block (fail closed); say why once, at the start.
    if (!defined $msgs) {
        my $e = $@;
        $e = 'unknown error' unless defined $e && length $e;
        $e =~ s/ at \S+ line \d+\.?\n?\z//;
        chomp $e;
        $e =~ s/[\x00-\x1f\x7f]/ /g;
        $msgs = ["claude-apart: the profile setup could not be loaded ($e), so every tool call is blocked. Run claude-apart check in a terminal."];
    }
    if (ref $msgs eq 'ARRAY' && @$msgs) {
        my $json = eval { JSON::PP->new->utf8->canonical->encode({ systemMessage => join("\n", @$msgs) }) };
        print "$json\n" if defined $json;
    }
    return 0;
}

# Messages for the user (a list): the identity block, and a note when the
# Herdr workspace belongs to another profile. Inside Herdr it also puts the
# profile's emoji (and tag) on the workspace and tab labels, once.
sub session_start {
    my ($profile) = @_;
    my @msgs;
    my $id = identity_block($profile);
    push @msgs, $id if defined $id;
    my $cfg = load_config($profile);
    my $p = ClaudeApart::Config::profile($cfg, $profile);
    push @msgs, eval { herdr_labels($cfg, $profile, $p) };
    return \@msgs;
}

sub herdr_labels {
    my ($cfg, $profile, $p) = @_;
    return () unless ($ENV{HERDR_ENV} || '') eq '1' && length $p->{emoji} && length $p->{tag};
    require Time::HiRes;
    my $t0 = Time::HiRes::time();
    # The supervisor kills at 5 s: all herdr work shares one deadline.
    local $ClaudeApart::Herdr::DEADLINE = $t0 + 3.5;
    my @msgs;
    my $other = 0;    # R56: another profile's workspace: no tab rename
    my $ws = $ENV{HERDR_WORKSPACE_ID};
    if (defined $ws && length $ws) {
        my $label = ClaudeApart::Herdr::workspace_label($ws);
        if (defined $label) {
            my $owner = ClaudeApart::Herdr::profile_for_label($cfg, $label);
            if (!defined $owner) {
                my $head = "$p->{emoji} $p->{tag}";
                ClaudeApart::Herdr::rename_workspace($ws, length $label ? "$head \xc2\xb7 $label" : $head);
            } elsif ($owner ne $profile) {
                $other = 1;
                push @msgs, 'claude-apart: this Herdr workspace belongs to another profile.';
            }
        }
    }
    my $tab = $ENV{HERDR_TAB_ID};
    if (defined $tab && length $tab && !$other) {
        my $label = ClaudeApart::Herdr::tab_label($tab);
        if (defined $label && $label !~ /\A\Q$p->{emoji}\E(?: |\z)/) {
            ClaudeApart::Herdr::rename_tab($tab, length $label ? "$p->{emoji} $label" : $p->{emoji});
        }
    }
    return @msgs;
}

1;
