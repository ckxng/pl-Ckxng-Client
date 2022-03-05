#!/usr/bin/perl
# $Id: logcopy.pl,v 1.2 2012/06/15 17:19:41 cameron Exp cameron $
package Ckxng::Client::LogCopy;
use 5.006;
use strict;
use warnings;
our $DEBUG=1;

our $VERSION = '0.001';

=head1 NAME

clientlogcopy.pl / Ckxng::Client::LogCopy

=head1 VERSION

0.001

=head1 SYNOPSIS

    ./nfllogcopy.pl [ --config /etc/nfllogcopy.cfg ]

    ./nfllogcopy.pl [ --version | --help ]

    OR

    use Ckxng::Client::LogCopy;
    my $app = Ckxng::Client::LogCopy->new();
    $app->configfile('/etc/clientlogcopy.cfg');
    $app->run();

=head1 DESCRIPTION

Run commands on certain days.  Alert in the event that there are not enough
days configured or not enough days remaining in the list.  If any command
returns a non-zero value, alert.  Alerts send emails.  All parameters
are configurable.

=head1 REQUIRES

=over 4

=item * B<YAML::Loader>

YAML is used because it's human readable, has a very simple Perl module, 
and is very flexible and easy to use.  People familiar with JSON will "just
get it" and it doesn't make me sick like XML.

=item * B<sendmail> binary in I<$ENV{'PATH'}>

Gotta send mail.  Most hosts have a working sendmail.  There ya go.

=back

=head1 EXPORT

None by default.

=head1 CONFIG

The config file is a YAML file with the following format:

    log: /var/log/clientlogcopy.log

    check:
        remaining: 1
        minimum: 15
        alert:
            - to: client-host@example.com
	    - to: noc@example.com
	    - subject: Client Log Backup Warning

    dates:
        - date: 20120630
        - date: 20120701
        - date: 20120705
        - date: 20120708
        - date: 20120710

    run:
        - cmd: /usr/local/bin/logcopy.sh
        - cmd: /usr/local/bin/logverify.sh


=head1 SUBROUTINES

=head2 B<Ckxng::Client::LogCopy>->B<new>()

Create a new instance of B<Ckxng::Client::LogCopy>.  This sub sets default 
values:

=over 4

=item * log enabled

=item * log file '/var/log/clientlogcopy.log' (failback to STDERR)

=item * alert enabled

=item * alert to nfl-host@zerolag.com

=item * subject '[TEST]' Client Log Move

=item * remaining dates -1 (no check)

=item * minimum dates -1 (no check)

=item * empty date set

=item * empty command set

=back

This function also records the current date in YYYYMMDD format in 
I<$self>->{'_now'} for later use.

=cut

sub new {
  my $package = shift(@_);

  my $self = {};

  # default log settings
  $self->{'_log'} = {
    'enabled' => 1,
    'file' => '/var/log/clientlogcopy.log',
    'handle' => *STDERR,
  };

  # default alert settings
  $self->{'_alert'} = {
    'enabled' => 1,
    'to' => ['client-host@example.com'],
    'subject' => '[TEST] Client Log Move',
    'remaining' => -1,
    'minimum' => -1,
    'lines' => [],
  };

  # default date and run array
  $self->{'_dates'} = [];
  $self->{'_run'} = [];

  # today's date
  my @localtime = localtime();
  $self->{'_now'} = sprintf("%04d%02d%02d", $localtime[5]+1900, $localtime[4]+1, $localtime[3]);

  return(bless($self, $package));
}

=head2 I<$self>->B<configfile>(I<$filename>)

=head2 I<$self>->B<config>(I<$yaml_contents>)

These functions load a the configuration that determines what the
module will do and how it gets done.  This sub generates quite a bit of 
output compared to the other subs.  Warnings and errors are identified
here:

B<Warnings:>

=over 4

=item * optional configation item invalid

=item * alert threshhold met for minimum or remaining dates

=back

B<Errors:>

=over 4

=item * config file not found or not readable

=item * required configuration item invalid

=item * no dates or no commands found

=back

If a configuration can be read, whether it is reasonable or not, B<config> will return 1.
Otherwise it will return 0.

=cut

sub configfile {
  unless($#_==1) { die("configfile: invalid args"); }
  my ($self, $cfgf) = @_;
  unless(-e $cfgf) { $self->_error("configfile: file not found"); return; }
  unless(-r $cfgf) { $self->_error("configfile: file not readable"); return; }

  my $cfgs = '';
  open(CFG, "<$cfgf");
  $cfgs .= $_ for(<CFG>);
  close(CFG);

  return($self->config($cfgs));
}

sub config {
  unless($#_==1) { die("config: invalid args"); }
  my ($self, $cfgs) = @_;
  require YAML::Loader;
  my $loader = YAML::Loader->new();
  my $config = $loader->load($cfgs);

  # log config
  # optional, defaults OK
  if(exists($config->{'log'})) {
    $self->{'_log'}->{'file'} = $config->{'log'};
    if(open(LOG, sprintf(">>%s", $self->{'_log'}->{'file'}))) {
      $self->{'_log'}->{'handle'} = *LOG;
      $self->_debug(sprintf("config: switched to log %s", $self->{'_log'}->{'file'}));
    }
  }


  # alert config
  # optional, defaults OK
  my $_firstemail = 1;
  if(exists($config->{'check'})) {
    if(exists($config->{'check'}->{'alert'})) {
      for my $c(@{$config->{'check'}->{'alert'}}) {

        # to foun
        if(exists($c->{'to'})) {
          unless($c->{'to'} eq '') {
	    if($_firstemail) {
	      $self->_debug('config: at least one email address found');
	      $self->{'_alert'}->{'to'} = [];
	      $_firstemail = 0;
 	    }
	    $self->_debug->sprintf("config: adding to '%s'", $c->{'to'});
	    push(@{$self->{'_alert'}->{'to'}}, $c->{'to'});
	  } else {
	    $self->_warn('config: alert:to cannot be empty');
	  }
	}
      }
    }
    
    my $c = $config->{'check'};

    # subject found
    if(exists($c->{'subject'})) {
      unless($c->{'subject'} eq '') {
        $self->{'_alert'}->{'subject'} = $c->{'subject'};
	$self->_debug(sprintf("config: check:subject '%s'", $c->{'subject'});
      } else {
        $self->_warn('config: alert:subject cannont be empty');
      }
    }

    # remaining
    if(exists($c->{'remaining'})) {
      if($c->{'remaining'} =~ /^\d+$/) {
        $self->{'_alert'}->{'remaining'} = $c->{'remaining'};
	$self->_debug(sprintf("config: check:remaining dates '%s'", $c->{'remaining'});
      } else {
        $self->_warn('config: check:remaining must be an integer');
      }
    }

    # minimum
    if(exists($c->{'minimum'})) {
      if($c->{'minimum'} =~ /^\d+$/) {
        $self->{'_alert'}->{'minimum'} = $c->{'minimum'};
	$self->_debug(sprintf("config: check:minimum dates '%s'", $c->{'minimum'});
      } else {
        $self->_warn('config: check:minimum must be an integer');
      }
    }
  }


  # top-level directives exist
  for(qw( dates run )) {
    unless(exists($config->{$_})) {
      $self->_error("config: missing required option '$_'"); 
      return(0);
    }
    unless($#{ $config->{$_} } >= 0) {
      $self->_error("config: nothing in section '$_'");
      return(0);
    }

    # iterate over category, date and run can share this loop
    for my $c(@{ $config->{$_} }) {

      # date found
      if(exists($c->{'date'})) {
        unless($c->{'date'} eq '') {
          if($c->{'date'} =~ /^20\d\d[0-1]\d[0-3]\d$/) {
            push(@{ $self->{'_dates'} }, sprintf("%d", $c->{'date'}));
	    $self->_notice(sprintf("config: date added '%s'", $c->{'date'}));
	  } else {
            $self->_error(sprintf("config: date is invalid (must be YYYYMMDD) '%s'", $c->{'date'}));
	  }
        } else {
          $self->_error('config: date cannot be empty');
        }
      }

      # command found
      if(exists($c->{'cmd'})) {
        unless($c->{'cmd'} eq '') {
	  push(@{ $self->{'_run'} }, $c->{'cmd'});
	  $self->_notice(sprintf("config: cmd added '%s'", $c->{'cmd'}));
	} else {
          $self->_error('config: cmd cannot be empty');
	}
      }
    }
  }
  

  # alerts in case of policy failure
  if($self->{'_alert'}->{'minimum'} >= 0) {
    if($#{ $self->{'_dates'} } + 1 <= $self->{'_alert'}->{'minimum'}) {
      $self->_warn(sprintf("config: minimum threshhold of dates violated %d <= %d", 
          $#{ $self->{'_dates'} } + 1, $self->{'_alert'}->{'minimum'}));
    }
  }
  if($self->{'_alert'}->{'remaining'} >= 0) {
    my $dates = 0;
    for my $date(@{ $self->{'_dates'} }) {
      if($self->{'_now'} <= $date) { $dates++; }
    }
    $self->_debug(sprintf('config: %d dates remain', $dates));
    if($dates <= $self->{'_alert'}->{'remaining'}) {
      $self->_warn(sprintf("config: minimum threshhold of remaining dates violated %d <= %d", 
          $dates, $self->{'_alert'}->{'remaining'}));
    }
  }
  
  $self->_debug(sprintf("config: today is %s", $self->{'_now'}));

  $self->{'_config'} = $config;

  if($DEBUG) {
    use Data::Dumper;
    $self->_debug(Dumper($self));
  }

  return(1);
}

=head2 I<$self>->B<_debug>(I<$message>)

=head2 I<$self>->B<_notice>(I<$message>)

=head2 I<$self>->B<_warn>(I<$message>)

=head2 I<$self>->B<_error>(I<$message>)

These subs print data to the configured output source.  This will be
either a log file or I<STDERR>.  Debug and notice messages are logged
but not emailed.  Warning and error messages are also queued for 
emailing.

Debug will only print if I<$DEBUG> evaluates to true.

=cut

sub _debug {
  unless($#_==1) { die("debug: invalid args"); }
  return unless($DEBUG);
  my ($self, $msg) = @_;
  my $fh = $self->{'_log'}->{'handle'};
  print $fh sprintf("debug: %s\n", $msg);
}

sub _notice {
  unless($#_==1) { die("notice: invalid args"); }
  my ($self, $msg) = @_;
  my $fh = $self->{'_log'}->{'handle'};
  print $fh sprintf("notice: %s\n", $msg);
}

sub _warn {
  unless($#_==1) { die("warn: invalid args"); }
  my ($self, $msg) = @_;
  my $fh = $self->{'_log'}->{'handle'};
  my $out = sprintf("warn: %s\n", $msg);
  $self->{'_alert'}->{'sendemail'} = 1;
  print $fh $out;
  push(@{ $self->{'_alert'}->{'lines'} }, $out);
}

sub _error {
  unless($#_==1) { die("error: invalid args"); }
  my ($self, $msg) = @_;
  my $fh = $self->{'_log'}->{'handle'};
  my $out = sprintf("error: %s\n", $msg);
  $self->{'_alert'}->{'sendemail'} = 1;
  print $fh $out;
  push(@{ $self->{'_alert'}->{'lines'} }, $out);
}

=head2 I<$self>->B<_send_alert>()

This sub sends mail via B<sendmail> found in I<$ENV{'PATH'}>.  Warnings and
errors that have been printed so far will go out according to the
configuration.

It will print and error if something goes wrong, but of course it will only
show up in the logs.  This is the most important thing to test when deploying.

=cut

sub _send_alert {
  unless($#_==2) { die("email: invalid args"); }
  my ($self) = shift(@_);

  for my $to(@{ $self->{'_alert'}->{'to'} }) {
    $self->_debug("send_alert: sending mail to '%s'", $to);
    open(SENDMAIL, "|sendmail") or $self->_error("send_alert: cannot open sendmail");
    print SENDMAIL sprintf("From: %s\n", 'noc@example.com');
    print SENDMAIL sprintf("Subject: %s\n", $self->{'_alert'}->{'subject'});
    print SENDMAIL sprintf("To: %s\n", $to);
    print SENDMAIL "Content-type: text/plain\n\n";
    print SENDMAIL sprintf("%s alert on %s\n\n", $0, `hostname`);
    for my $line(@{ $self->{'_alert'}->{'lines'} }) {
      print SENDMAIL $line;
    }
    close(SENDMAIL);
  }
}

=head2 I<$self>->B<run>()

Check dates to see if any of them is today, then run all the commands 
that are configured to run.  Record the output and keep up with the
return code.  If the return code is not 0, then print an error.

This sub also triggers the email alerts if there are any warnings
or errors pending.

=cut

sub run {
  unless($#_==0) { die("run: invalid args"); }
  my $self = shift(@_);
  
  for my $date(@{ $self->{'_dates'} }) {
    if($self->{'_now'} eq $date) {

      # RUN!
      for my $cmd(@{ $self->{'_run'} }) {
        my $out = `/bin/sh -c $cmd 2>&1`;
	my @outs = split(/\n/, $out);
	my $ret = $?;
	if($ret == 0) {
	  $self->_debug(sprintf("running: %s (%d)", $cmd, $?));
	  for my $o(@outs) { $self->_debug(sprintf("  %s", $o)); }
	} else {
	  $self->_error(sprintf("running: %s (%d)", $cmd, $?));
	  for my $o(@outs) { $self->_error(sprintf("  %s", $o)); }
        }
      }
    }
  }
  
  if($self->{'_alert'}->{'sendemail'}) {
    $self->_notice("run: oh, no!  sending email!");
    $self->_send_alert();
  }
}

=head1 MAIN SUBROUTINES

=head2 B<main_version>()

=head2 B<main_help>()

=head2 B<main>()

These subroutines are called if the script is run directory from the 
commandline.  It specifies a default config location (or takes one
as an argument), provides version and help output upon request, and
fires off I<$self>->B<run>().

Basically, it does all the work so you don't have to.

=cut

sub main_version {
  printf("Ckxng::Client::LogCopy version %s\n", $VERSION);
  exit();
}

sub main_help {
  printf("Usage: %s [ --config=/etc/configfile ]\n", $0);
  exit();
}

main() unless caller();
sub main {
  use Getopt::Long;
  my $configfile = '/etc/clientlogcopy.cfg';
  GetOptions(
    "config:s", \$configfile,
    "version", sub { main_version(); },
    "help", sub { main_help(); },
  );
  my($app) = ZeroLag::NFL::LogCopy->new();
  $app->configfile($configfile);
  $app->run();
}
  
=head1 AUTHOR

Cameron King <http://cameronking.me>

=head1 COPYRIGHT AND LICENSE

Copyright 2012 Cameron C. King. All rights reserved.

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
