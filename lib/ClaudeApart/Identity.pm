package ClaudeApart::Identity;
use strict;
use warnings;
use JSON::PP ();
use ClaudeApart::Config;

sub _cfg { return ClaudeApart::Config::load(ClaudeApart::Config::config_path()) }

sub file_for {
    my ($name) = @_;
    my $p = ClaudeApart::Config::profile(_cfg(), $name) or die "unknown profile: $name\n";
    return $p->{adopted} ? "$ENV{HOME}/.claude.json" : "$p->{abs_dir}/.claude.json";
}

sub read {
    my ($name) = @_;
    my $file = file_for($name);
    open my $fh, '<', $file or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $d = eval { JSON::PP->new->utf8->decode($raw) };
    return undef unless ref $d eq 'HASH' && ref $d->{oauthAccount} eq 'HASH';
    my $a = $d->{oauthAccount};
    return undef unless defined $a->{emailAddress} && length $a->{emailAddress};
    return {
        email    => $a->{emailAddress},
        org      => defined $a->{organizationUuid} ? $a->{organizationUuid} : '',
        org_name => defined $a->{organizationName} ? $a->{organizationName} : '',
    };
}

sub check {
    my ($name) = @_;
    my $p = ClaudeApart::Config::profile(_cfg(), $name) or die "unknown profile: $name\n";
    return ('missing', '') unless length $p->{email} && length $p->{org};
    my $id = ClaudeApart::Identity::read($name) or return ('missing', '');
    return ('mismatch', $id->{email}) if length $p->{email} && lc $id->{email} ne lc $p->{email};
    return ('mismatch', $id->{email}) if length $p->{org} && $id->{org} ne $p->{org};
    return ('ok', $id->{email});
}

1;
