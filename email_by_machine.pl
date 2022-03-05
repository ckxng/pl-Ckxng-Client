#!/usr/bin/perl
use 5.006;
use strict;
use warnings;

package Ckxng::Client::EmailByMachine;

our $VERSION = '1.000';

=head1 NAME

email_by_machine.pl (Ckxng::Client::EmailByMachine)

=head1 VERSION

1.000

=head1 SYNOPSIS

    ./email_by_machine.pl [-dhisVvTn] [-F from@address.com] [-t tag] [-f file] [-S subject] -m machine [message]
    
=head1 DESCRIPTION

This tool allows an admin at a company to send email by machine name.

Options:

=over 4

=item B<-i, --id>

Log the process ID of the logger process in a header..

=item B<-f, --file file>

Email the contents of the specified file.  This option cannot be combined with a
command-line message.

=item B<-h, --help>

Display a help text and exit.

=item B<-s, --stderr>

Output the message to standard error as well as emailing it..

=item B<-t, --tag tag>

Tag the email with a string in the header.

=item B<-V, --version>

Display version information and exit.

=item B<-v, --verbose>

Output additional diagnistic messages to stderr

=item B<-S, --subject subject>

The machine name that this email should be sent in reference to.

=item B<-m, --machine machine_name>

The machine name that this email should be sent in reference to.

=item B<-n, --notify>

Boolean to determine whether or not admin is notified.  Defaults to no.

=item B<-F, --from from@address.com>

The email address to send from.  If unspecified, upstream API default is used..

=item B<-->

End the argument list. This is to allow the message to start with a hyphen (-).

=item B<message>

Write the message in an email; if not specified, and the -f flag is not provided,
standard input is sent.

=back

The logger utility exits 0 on success, and >0 if an error occurs.

=head1 REQUIRES

=over 4

=item L<ZeroLag::ZCAPI>, lib ver. 1.0.1+

=item L<Getopt::Long>

=item L<Pod::Usage>

=back

=head1 EXPORT

None by default.

=cut

############################################################

=head1 SUBROUTINES

=head2 B<< $self->new >>()

Create a Logger object with default $self->{args}

=cut

sub new {
  my $package = shift(@_);
  my $self = {
    args => {
      id       => undef,
      file     => undef,
      stderr   => undef,
      tag      => undef,
      verbose  => undef,
      help     => undef,
      version  => undef,
      subject  => undef,
      machine  => undef,
      notify   => undef,
      from     => undef,
      argv     => undef,
    },
  };

  use ZeroLag::ZCAPI;
  $self->{api} = ZeroLag::ZCAPI->new();
  $self->{api}->connect('https://control.example.com/zcapi') or die "unable to connect to astra\n";
  $self->{api}->setApiKey('X') or die "unable to set api key\n";

  return(bless($self, $package));
}

=head2 B<run>()

Run the logger with the behavior specified by $self->{args}

=cut

sub run {
  my $self = shift(@_);

  die "-m is required\n" unless $self->{args}->{machine};

  my $headers = '';
  $headers .= "X-NotifyTag: $self->{args}->{tag}\n" if $self->{args}->{tag};
  $headers .= "X-NotifyID: PID $$\n" if $self->{args}->{id}; 

  my $message = '';
  if($self->{args}->{file}) {
    die "file unreadable\n" unless -r $self->{args}->{file};
    open READF, $self->{args}->{file} or die "unable to open file\n";
    my $message = '';
    close READF;
    $message .= $_ while(<READF>);
  } elsif($self->{args}->{argv}) {
    $message = join(" ", @{ $self->{args}->{argv} }) . "\n";
  } else {
    $message .= $_ while(<STDIN>);
  }

  print STDERR $message if $self->{args}->{stderr};
  my $api_args = {
    hostname => $self->{args}->{machine},
    message  => $message,
    notify_admin => $self->{args}->{notify}?1:0,
  };
  $api_args->{subject} = $self->{args}->{subject} if $self->{args}->{subject};
  $api_args->{from} = $self->{args}->{from} if $self->{args}->{from};
  $api_args->{headers} = $headers if $headers;

  if($self->{args}->{verbose} >= 3) {
    foreach my $key(keys(@{$api_args})) {
      print "*** sending $key \"${api_args}->{$key}\"\n";
    }
  }

  my $response = $self->{api}->exec("email_company_by_machine_dedicated", $api_args);
  die "unable to send message! ". $self->{api}->getErrorMessage ."\n" if $self->{api}->hasError || !ref($response) eq 'ARRAY';
  if($self->{args}->{verbose}) {
    foreach my $sent_to(@{ $response }) {
      print STDOUT "sent: $sent_to\n";
    }
  }
}


############################################################

=head1 MAIN SUBROUTINES

=head2 B<main_version>()

Print version information found in the documentation.

-V will print version information

=head2 B<main_help>()

Print usage information found in the documentation.

-h will print basic usage

-hv will load the man page

=head2 B<main>()

Extracts commandline arguments and initializes the application and
$self->{args}.  Runs the application.

-vvv will dump the args to stderr.

=cut

sub main_version {
  use Pod::Usage;
  print pod2usage(-verbose=>99, -sections=>[qw( NAME VERSION AUTHOR COPYRIGHT LICENSE)]);
  exit;
}

sub main_help {
  use Pod::Usage;
  print $_[0]?pod2usage(-verbose=>99, -sections=>[qw( SYNOPSIS DESCRIPTION )]):pod2usage;
  exit;
}

sub main {
  use Getopt::Long;
  Getopt::Long::Configure "bundling";
  my $app = Ckxng::Client::EmailByMachine->new;
  GetOptions($app->{args},
    "id|i",
    "tag|t=s",
    "file|f=s",
    "priority|p=s",
    "stderr|s",
    "notify|n",
    "from|F=s",
    "subject|S=s",
    "machine|m=s",
    "verbose|v+",
    "version|V",
    "help|h",
  );
  @{ $app->{args}->{argv} } = @ARGV if $#ARGV >= 0;
  if($app->{args}->{verbose} && $app->{args}->{verbose} >= 3) {
    print map { sprintf("*%s: %s\n", $_, $app->{args}->{$_}||"") } keys(%{$app->{args}});
  }
  main_help $app->{args}->{verbose} if $app->{args}->{help};
  main_version if $app->{args}->{version};
  $app->run;
}
main unless caller;

=head1 AUTHOR

Cameron King <http://cameronking.me>

=head1 COPYRIGHT

Copyright 2012 Cameron C. King.  All rights reserved.

=head1 LICENSE

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY CAMERON C. KING ''AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL CAMERON C. KING OR CONTRIBUTORS BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.

=cut
1;

