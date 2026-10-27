package ClaudeApart::Statusline;
use strict;
use warnings;
use ClaudeApart::Config;
use ClaudeApart::Identity;
use ClaudeApart::Proc;

# The first line of the status line: a coloured badge for the profile and
# the account's email, or a red WRONG ACCOUNT badge when the login does not
# match the profile. This is local output, so it may show the actual email
# (hooks never do). With a chained command, its first output line is added
# after " │ " and its other lines follow unchanged.

my $CHAIN_TIMEOUT = 2;
my $BAR = "\xe2\x94\x82";    # │ as UTF-8 bytes, like the config strings

sub render {
    my ($profile, $chain, $stdin) = @_;
    my $line1 = badge($profile);
    my $rest = '';
    if (defined $chain && length $chain) {
        my $out = ClaudeApart::Proc::capture(
            { timeout => $CHAIN_TIMEOUT, group => 1, stdin => $stdin }, '/bin/sh', '-c', $chain);
        if (defined $out && $out =~ /\A([^\n]*)(?:\n(.*))?\z/s) {
            my ($first, $more) = ($1, $2);
            $first =~ s/\r\z//;
            $line1 .= " $BAR $first" if length $first;
            $rest = $more if defined $more && length $more;
        }
    }
    $rest .= "\n" if length $rest && $rest !~ /\n\z/;
    return "$line1\n$rest";
}

sub badge {
    my ($profile) = @_;
    my ($st, $email) = eval { ClaudeApart::Identity::check($profile) };
    $st = 'missing' unless defined $st;
    if ($st eq 'ok') {
        my $p = ClaudeApart::Config::profile(
            ClaudeApart::Config::load(ClaudeApart::Config::config_path()), $profile);
        my $c = length $p->{colour_code} ? $p->{colour_code} : 250;
        return "\e[48;5;${c}m\e[38;5;16m $p->{tag} \e[0m $email";
    }
    return "\e[48;5;196m\e[38;5;231m WRONG ACCOUNT \e[0m " . (length $email ? $email : 'not logged in');
}

1;
