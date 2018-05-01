#!/usr/bin/perl

######################################################################
# script to poll pagerduty for new acks to alerts generated by pagerduty_nagios.pl
# https://github.com/PagerDuty/pagerduty-nagios-pl
#
# it's handy to ack nagios alerts from pagerduty's sms or phone
# interface the same way you might for an email alert.  this will get
# acks to nagios alerts fed back to nagios
#
# also a resolve in pagerduty will create an ack in nagios
######################################################################

######################################################################
#Permission is hereby granted, free of charge, to any person
#obtaining a copy of this software and associated documentation
#files (the "Software"), to deal in the Software without
#restriction, including without limitation the rights to use,
#copy, modify, merge, publish, distribute, sublicense, and/or sell
#copies of the Software, and to permit persons to whom the
#Software is furnished to do so, subject to the following
#conditions:
#
#The above copyright notice and this permission notice shall be
#included in all copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
#EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
#OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
#NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
#HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
#WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
#FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
#OTHER DEALINGS IN THE SOFTWARE.
######################################################################

use Getopt::Long;
use JSON;
use Data::Dumper;
use strict;

my(%opts);
my(@opts)=('debug',
           'nagios_status_file|s=s',
           'nagios_command_pipe|c=s',
           'pagerduty_token|p=s',
           'pagerduty_subdomain|u=s',
           'pagerduty_service|n=s',
           'last_id_file|l=s',
           'last_id=i',
           'help|h',
    );

die unless GetOptions(\%opts,@opts);

if($opts{help}){
  print <<EOT;
$0: pass pagerduty acknowledgements into nagios

options:

 --debug | -d
 --nagios_status_file <_file> | -s <_file> (default /var/cache/nagios/status.dat)
 --nagios_command_pipe <_file> | -c <_file> (default /var/spool/nagios/cmd/nagios.cmd)
 --pagerduty_token <_token> | -p <_token>
 --pagerduty_subdomain <_subdomain> | -u <_subdomain>
 --pagerduty_service <_service> | -n <_service> (limit to a comma separated list of service ids)
 --last_id_file <_file> | -l <_file> (default /tmp/pd_ack_to_nagios_ack_poller.last_id)
 --last_id <_id> (overrides and skips saving to last_id_file)
 --help | -h (this message)
EOT
exit 0;
}

$opts{nagios_status_file} ||= '/var/cache/nagios/status.dat';
$opts{nagios_command_pipe} ||= '/var/spool/nagios/cmd/nagios.cmd';
$opts{last_id_file} ||= '/tmp/pd_ack_to_nagios_ack_poller.last_id';

die "can't access last_id_file $opts{last_id_file}"
   if(!defined($opts{last_id}) &&
      (-e $opts{last_id_file}) && !(-w $opts{last_id_file}));
die "can't access pipe $opts{nagios_command_pipe}" if(!(-w $opts{nagios_command_pipe}));
die "--pagerduty_token|-p required" unless($opts{pagerduty_token});
die "--pagerduty_subdomain|-u required" unless($opts{pagerduty_subdomain});

# optionally specify service id(s)
my($svcparam) = "";
if(defined($opts{pagerduty_service})){
    $svcparam = "&service=$opts{pagerduty_service}";
}

# retrieve all resolved anbd acknowledged incidents from pagerduty in reverse order by id
my($j, $cmd);
$cmd = "curl -s -H 'Authorization: Token token=$opts{pagerduty_token}' " .
    "'https://api.pagerduty.com/incidents?fields=incident_number,id" .
    "${svcparam}&statuses%5B%5D=acknowledged&statuses%5B%5D=resolved&sort_by=incident_number:desc'";
print "$cmd\n" if($opts{debug});
$j = scalar(`$cmd`);
my($i) = from_json($j, {allow_nonref=>1});
my($last) = $opts{last_id};
$last ||= (`touch $opts{last_id_file};cat $opts{last_id_file}` + 0);

# retrieve all services with problems from the Nagios status file
my($nagstat) = {};
$cmd = "cat $opts{nagios_status_file} | grep -A50 'servicestatus {'" .
    "| egrep 'servicestatus|host_name|service_description|current_problem_id|problem_has_been_acknowledged' " .
    "| cut -d= -f2";
print "$cmd\n" if($opts{debug});
my(@statcat) = `$cmd`;
print "@statcat\n" if($opts{debug});

# build a map with key hostname-service and the Nagios problem id
while(@statcat){
  chomp(my(undef, $h, $s, $pi, $a) = (shift(@statcat), shift(@statcat), shift(@statcat), shift(@statcat), shift(@statcat)));
  next if($a != 0);
  next if($pi == 0);
      print "$h\n" if($opts{debug});
      print "$s\n" if($opts{debug});
      print "$pi\n" if($opts{debug});
      print "$a\n" if($opts{debug});
  $nagstat->{$h}{$s} = $pi;
}

# retrieve all hosts with problems from the Nagios status file
$cmd = "cat $opts{nagios_status_file} | grep -A50 'hoststatus {'" .
    "| egrep 'host_name|current_problem_id|problem_has_been_acknowledged' " .
    "| cut -d= -f2";
print "$cmd\n" if($opts{debug});
my(@statcat) = `$cmd`;
print "@statcat\n" if($opts{debug});

# build a map with key hostname-HOST and the Nagios problem id
while(@statcat){
  chomp(my($h, $pi, $a) = (shift(@statcat), shift(@statcat), shift(@statcat)));
  next if($a != 0);
  next if($pi == 0);
      print "$h\n" if($opts{debug});
      print "$pi\n" if($opts{debug});
      print "$a\n" if($opts{debug});
  $nagstat->{$h}{HOST} = $pi;
}
print Dumper $nagstat if($opts{debug});

# loop over PagerDuty incidents retrieved earlier, if any have an ack'd or resolved Nagios log entry, check if the problem ids match and then ack in Nagios
for(reverse(@{$i->{incidents}})){
  my($in) = $_->{incident_number};
  my($iid) = $_->{id};
  print "Comparing in=$in to last=$last\n" if($opts{debug});
  if($in > $last){ # Skip to the last incident id from file or command line
    {
      print "$in\n" if($opts{debug});

      # retrieve the log entries for the incident
      $cmd = "curl -s -H 'Authorization: Token token=$opts{pagerduty_token}' ".
          "'https://api.pagerduty.com/incidents/$iid/log_entries'";
      print "$cmd\n" if($opts{debug});
      $j = scalar(`$cmd`);
      my($ls) = from_json($j, {allow_nonref=>1});
      print Dumper $ls if($opts{debug});

      # skip if this is not a nagios alert
      last unless($ls->{log_entries}[$#{$ls->{log_entries}}]{channel}{type} eq 'nagios');
      print "Passed type=nagios\n"  if($opts{debug});

      # filter out non-ack/resolve
      my($lf) = [grep {$_->{type} =~ /^(resolve_log_entry|acknowledge_log_entry)/} @{$ls->{log_entries}}];
      print "Passed not ack or resolve\n"  if($opts{debug});

      # skip if nagios ack/resolution came from nagios
      last if($lf->[0]{channel}{type} eq 'nagios');
      print "Passed ackd or resolved from Nagios\n"  if($opts{debug});

      # skip if resolution was a timeout
      last if($lf->[0]{channel}{type} eq 'timeout');
      print "Passed not a timeout\n"  if($opts{debug});

      my($u) = $lf->[0]{agent}{summary};
      # my($u) = $lf->[0]{agent}{email} =~ /^([^\@]*)\@/;
      my($c) = $lf->[0]{channel}{type};
      my($lt) = $lf->[0]{type};
      my($li) = $ls->{log_entries}[$#{$ls->{log_entries}}]{id};

      # Get the channel data for this log entry which contains the custom fields
      $cmd = "curl -s -H 'Authorization: Token token=$opts{pagerduty_token}' " .
          "'https://api.pagerduty.com/log_entries/$li?include%5B%5D=channels'";
      print "$cmd\n" if($opts{debug});
      $j = scalar(`$cmd`);
      my($raw) = from_json($j, {allow_nonref=>1});
      print Dumper $raw->{log_entry}{channel}{details} if($opts{debug});

      # get the HOST and SERVICE info
      my($h) = $raw->{log_entry}{channel}{details}{HOSTDISPLAYNAME};
      my($s) = $raw->{log_entry}{channel}{details}{SERVICEDISPLAYNAME};
      my($hpi) = $raw->{log_entry}{channel}{details}{HOSTPROBLEMID};
      my($spi) = $raw->{log_entry}{channel}{details}{SERVICEPROBLEMID};

      # skip if there's no problem id in nagios (meaning service is
      # already recovered), or if the problem id is more recent than
      # the one in the raw pagerduty entry.
      print "host name=$h\n" if($opts{debug});
      print "service name=$s\n" if($opts{debug});
      print "host problem id from Nagios=$nagstat->{$h}{HOST}\n" if($opts{debug});
      print "host problem id from PagerDuty=$hpi\n" if($opts{debug});

      # first check for any host problems
      if($nagstat->{$h}{HOST} && ($nagstat->{$h}{HOST} <= $hpi)){
        my($t) = time;
        #ACKNOWLEDGE_HOST_PROBLEM;<host_name>;<sticky>;<notify>;<persistent>;<author>;<comment>
        $cmd = "echo '[$t] ACKNOWLEDGE_HOST_PROBLEM;$h;1;0;1;$u;pd event $in $lt by $u via $c' >$opts{nagios_command_pipe}";
        print "$cmd\n" if($opts{debug});
        # call the command line executable to acknowledge in Nagios
        `$cmd`;
      }
      print "service problem id from Nagios=$nagstat->{$h}{$s}\n" if($opts{debug});
      print "service problem id from PagerDuty=$spi\n" if($opts{debug});

      # then check for any service problems
      if($nagstat->{$h}{$s} && ($nagstat->{$h}{$s} <= $spi)){
        my($t) = time;
        #ACKNOWLEDGE_SVC_PROBLEM;<host_name>;<service_description>;<sticky>;<notify>;<persistent>;<author>;<comment>
        $cmd = "echo '[$t] ACKNOWLEDGE_SVC_PROBLEM;$h;$s;1;0;1;$u;pd event $in $lt by $u via $c' >$opts{nagios_command_pipe}";
        print "$cmd\n" if($opts{debug});
        # call the command line executable to acknowledge in Nagios
        `$cmd`;
      }
    }

    `echo $in >$opts{last_id_file}` unless($opts{last_id});
  }
}
