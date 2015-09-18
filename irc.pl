use strict;
use warnings;
use POE qw(Component::IRC Component::IRC::Plugin::AutoJoin Component::IRC::Plugin::NickServID Wheel::Run Component::Server::TCP Component::Server::HTTP Component::Client::HTTP);
use JSON;
use RRD::Simple;

$SIG{CHLD} = 'IGNORE';

my $nickname = 'HiEnrich';
my $ircname  = 'Flibble the Sailor Bot';
my $server   = 'irc.freenode.net';

my $rrdfile = "/opt/HiEnrich/lab.rrd";
my $rrdfile2 = "/opt/HiEnrich/labnet.rrd";
my $rrd = RRD::Simple->new( file => $rrdfile );
my $rrd2 = RRD::Simple->new( file => $rrdfile2 );
my $locked = undef;

unless (-f $rrdfile) {
   $rrd->create($rrdfile, 
      "3years",
      macs => "GAUGE",
      open => "GAUGE",
   );
}
unless (-f $rrdfile2) {
   $rrd2->create($rrdfile2,
      "3years",
      nettx   => "COUNTER",
      netrx   => "COUNTER",
      netbw   => "COUNTER",
   );
}


# Nickserv
my $nickid = 'HiEnrich';
my $password = `cat /opt/HiEnrich/password.txt`;

# Interval we report a closing lab in maximum
my $secs = 60*5; # Seconds
my $cursecs = $secs;

my $channels = {
   '#test.privi'   => '',
   #'#augsburg'     => '',
};

my $dstchannel = '#test.privi'; # '#augsburg';

my $port = 12345;
my $address = '127.0.0.1';

# Der Remote SSH Server hat folgende /root/.ssh/authorized_keys:
# command="/usr/sbin/arp -an",no-port-forwarding,no-X11-forwarding,no-pty ssh-rsa KEY.......
my $maccmd = ["/usr/bin/ssh", "-i", "/opt/HiEnrich/getmacs", "172.16.16.2"];

my $cmddef = [
   ['status', '^\.status$',  $maccmd],
   ['bigstatus', '^\.bigstatus$',  $maccmd],
   ['muesli', '^\.muesli$',  []],
   ['df',     '^\.df$',      ["/bin/df"]],
   ['uptime', '^\.uptime$',  ["/usr/bin/uptime"]],
   ['ping',   '^\.ping$',    ["ping", "-c", "4", "www.heise.de"]],
   ['ping2',  '^\.pingd?ns$',["ping", "-c", "4", "8.8.8.8"]],
];

my $rules = {};

open(RULES, "<", "rules.txt") || die("cannot open rules.txt: ".$!);
while(<RULES>) {
   chomp;
   s,\#.*$,,;
   my $line = [split(/\s+/)];
   next if m,^\s*$,;
   unless (scalar(@$line) == 3) {
      print "Bad rule columns number: ".scalar(@$line)."\n";
      next;
   }
   if (($line->[0] eq "mac")||($line->[0] eq "ip")) {
      push(@{$rules->{$line->[0]}->{$line->[1]}}, $line->[2]);
      print "TYPE:".$line->[0].":".$line->[1]." = ".$line->[2]."\n";
   } else {
      print "Bad rule type: ".$line->[0]."\n";
   }
}

my $irc = POE::Component::IRC->spawn(
   nick    => $nickname,
   ircname => $ircname,
   server  => $server,
) or die "Oh noooo! $!";

die "Kein passwortfile oder kein Passwort darin!"
   unless $password;

my $livedata = {};
my $livedatatimestamp = 0;

POE::Component::Client::HTTP->spawn(
   Alias     => 'ua',                  # defaults to 'weeble'
   Timeout   => 20,                    # defaults to 180 seconds
   MaxSize   => 16384,                 # defaults to entire response
   FollowRedirects => 2                # defaults to 0 (off)
);

my $aliases = POE::Component::Server::HTTP->new(
   Address => "0.0.0.0",
   Port => 4716,
   ContentHandler => {
      '/.status' => sub {
         my ($request, $response) = @_;
         $response->code(RC_OK);
         $response->content(getStatusJSON());
         return RC_OK;
      },
   }
);

sub getStatusJSON {
   $livedata->{macs}->{user} ||= [];
   $livedata->{macs}->{freifunk} ||= [];
   if ($livedata->{macs}) {
      my $stats = {};
      foreach my $type (keys %{$livedata->{macs}}) {
         $stats->{$type} = scalar (@{$livedata->{macs}->{$type}});
      }
      #$stats->{user} .= '(Fuer Phjlipp: Das funktioniert im Moment nicht)';
      return JSON->new->utf8->encode({ result => "ok", error => undef, stats => $stats, delay => (time()-$livedatatimestamp)});
   } else {
      return JSON->new->utf8->encode({ result => "fail", error => "no live data" });
   }
}

POE::Session->create(
   inline_states => {
      _start => sub {
         print "Session ", $_[SESSION]->ID, " has started.\n";
         $_[HEAP]->{count} = 0;
         $_[KERNEL]->yield("count");
         $_[HEAP]->{curstate} = 0;
      },
      _stop => sub {
         print "Session ", $_[SESSION]->ID, " has stopped.\n";
      },
      count => sub {
         my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
         my $session_id = $_[SESSION]->ID;
         $heap->{child} = POE::Wheel::Run->new(
            Program => $maccmd,
            StdoutEvent  => "got_child_stdout",
            StderrEvent  => "got_child_stdout",
            CloseEvent   => "got_child_close",
         );
      },
      got_child_stdout => sub {
         my $heap = $_[HEAP];
         my $line = $_[ARG0];
         my $wheelid = $_[ARG1];
         my $trackdata = $heap->{trackdata}->{$wheelid};
         #print $line."\n";
         parseMacLine($line, $heap);
      },
      send_to_muesli => sub {
         my ($kernel, $session, $heap, $request_packet, $response_packet) = @_[ KERNEL, SESSION, HEAP, ARG0, ARG1];
         my $request_object  = $request_packet->[0];
         my $response_object = $response_packet->[0];
         #$irc->yield( privmsg => $dstchannel => "RESULT: [REQUEST] url=".$request_object->uri." content=".$request_object->content." [RESPONSE] code=".$response_object->code." content=".$response_object->content().":\n");
      },
      got_child_close => sub {
         my $heap = $_[HEAP];
         my $wheelid = $_[ARG0];
         $heap->{macs}->{user} ||= [];
         my $newstate = (scalar(@{$heap->{macs}->{user}}) ? 1 : 0);
         delete $heap->{curcounttime}
            if ($newstate);
         my $report = 0;
         $cursecs = $secs
            if ((scalar(@{$heap->{macs}->{user}}) > 1) && ($cursecs > $secs));
         unless ($heap->{curstate} == $newstate) {
            if ($newstate) {
               $report++;
               $heap->{curstate} = $newstate;
               $cursecs = $secs;
               $cursecs = $secs * 10
                  unless (scalar(@{$heap->{macs}->{user}}) > 1);
            } else {
               if ($heap->{curcounttime}) {
                  if ((time()-$heap->{curcounttime}) > $cursecs) {
                     delete $heap->{curcounttime};
                     $report++;
                     $heap->{curstate} = $newstate;
                  }
               } else {
                  $heap->{curcounttime} = time();
               }
            }
         }
         $livedata->{macs} = $heap->{macs};
         $livedatatimestamp = time();
         $heap->{macs} = {};
         delete $heap->{trackdata}->{$wheelid};
         delete $heap->{child};
         my $val = handleMacResult($heap, $wheelid);
         if ($report) { 
            $irc->yield( privmsg => $dstchannel => "Labstatus hat sich geaendert: ".$val);
            $poe_kernel->post('ua', 'request','send_to_muesli', HTTP::Request->new(POST => "http://172.16.16.116:12346/netstatus" => HTTP::Headers->new() => getStatusJSON()))
         }
         $poe_kernel->delay("count" => 5);
      } 
   }
);

POE::Session->create(
   inline_states => {
      _start => sub {
         my $heap = $_[HEAP];
         POE::Component::Server::TCP->new(
            Port => $port,
            Address => $address,
            ClientInput => sub {
               my $client_input = $_[ARG0];
               $irc->yield( privmsg => $dstchannel => $client_input );
            }
         );
         $heap->{irc}->yield( register => 'all' );
         $heap->{irc}->yield( connect => { } );
         $heap->{irc}->plugin_add( $nickid, POE::Component::IRC::Plugin::NickServID->new(
            Password => $password
         ));
         $heap->{irc}->plugin_add('AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => $channels, RejoinOnKick => 1, Retry_when_banned => 1,  ));
      },
      irc_public => sub {
          my ($heap, $sender, $who, $where, $what) = @_[HEAP, SENDER, ARG0 .. ARG2];
          my $nick = ( split /!/, $who )[0];
          my $channel = $where->[0];
          foreach my $curcmd (@$cmddef) {
             my $trigger = $curcmd->[1];
             if ($what =~ m,$trigger,) {
               if ($what =~ m,muesli,i) {
                  $poe_kernel->post('ua', 'request','send_to_muesli', HTTP::Request->new(POST => "http://172.16.16.116:12346/netstatus" => HTTP::Headers->new() => getStatusJSON()));
                  print "MUSLI!!!\n";
                  return;
               }
               my $cmd = $curcmd->[2];
               print "Running ".join(" ", @$cmd)."\n";
               $heap->{child} = POE::Wheel::Run->new(
                  Program => $cmd,
                  StdoutEvent  => "got_child_stdout",
                  StderrEvent  => "got_child_stdout",
                  CloseEvent   => "got_child_close",
               );
               $heap->{trackdata}->{$heap->{child}->ID()}->{channel} = $channel;
               $heap->{trackdata}->{$heap->{child}->ID()}->{curcmd} = $curcmd;
            }
         }
         return;
      },
      _default => sub {
         my ($event, $args) = @_[ARG0 .. $#_];
         my @output = ( "$event: " );
         for my $arg (@$args) {
            if (ref $arg eq 'ARRAY') {
               push( @output, '[' . join(', ', @$arg ) . ']' );
            } else {
               push ( @output, "'$arg'" );
            }
         }
         print join ' ', @output, "\n";
         return;
      },
      got_child_stdout => sub {
         my $heap = $_[HEAP];
         my $line = $_[ARG0];
         my $wheelid = $_[ARG1];
         my $trackdata = $heap->{trackdata}->{$wheelid};
         if ($trackdata->{curcmd}->[0] eq "status") {
            print $line."\n";
            parseMacLine($line, $heap);
         } elsif ($trackdata->{curcmd}->[0] eq "status") {
            print $line."\n";
            parseMacLine($line, $heap, 1);
         } else { 
            $irc->yield( privmsg => $trackdata->{channel} => $line );
         }
      },
      got_child_close => sub {
         my $heap = $_[HEAP];
         my $wheelid = $_[ARG0];
         my $trackdata = $heap->{trackdata}->{$wheelid};
         if ($trackdata->{curcmd}->[0] eq "bigstatus") {
            $irc->yield( privmsg => $heap->{trackdata}->{$wheelid}->{channel} => handleMacResult($heap, $wheelid, 1));
         }
         if ($trackdata->{curcmd}->[0] eq "status") {
            #$irc->yield( privmsg => $heap->{trackdata}->{$wheelid}->{channel} => handleMacResult($heap, $wheelid));
            $irc->yield( privmsg => $heap->{trackdata}->{$wheelid}->{channel} => "+++ LAB-STATUS: ".(($locked eq "UNLOCKED") ? "offen" : ($locked eq "LOCKED") ? "abgesperrt" : "unbekannt").". +++" );
            $irc->yield( privmsg => $heap->{trackdata}->{$wheelid}->{channel} => "+++ Netzwerk-Status - Freifunk: 0, Lab: ".scalar(@{$livedata->{macs}->{"user"}}) );
         }
         $livedata->{macs} = $heap->{macs};
         $livedatatimestamp = time();
         $heap->{macs} = {};
         delete $heap->{child};
         delete $heap->{trackdata}->{$wheelid};
      },
   },
   heap => { irc => $irc },
);

$poe_kernel->run();

sub parseMacLine {
   my $line = shift;
   my $heap = shift;
   my $long = shift;
   my $curentry = [split(/\s+/, $line)];
   my $curip = $curentry->[0];
   if ($curentry->[3] eq "lladdr") {
      my $curmac = $curentry->[4];
      if (($curentry->[5] eq "REACHABLE") || ($curentry->[5] eq "STALE")) {
         foreach my $curname (keys %{$rules->{mac}}) {
            return push(@{$heap->{macs}->{$curname}}, $curentry)
               if (grep { lc($curmac) eq lc($_) } @{$rules->{mac}->{$curname}});
         }
         foreach my $curname (keys %{$rules->{ip}}) {
            return push(@{$heap->{macs}->{$curname}}, $curentry)
               if (grep { lc($curip) eq "(".lc($_).")" } @{$rules->{ip}->{$curname}});
         }
         if ($curip =~ m,172\.16\.0\.,) {
            push(@{$heap->{macs}->{user}}, $curentry);
         } elsif($curentry->[3] eq "lladdr") {
            push(@{$heap->{macs}->{unknown}}, $curentry);
         } else {
            push(@{$heap->{macs}->{bad}}, $curentry);
         }
      } elsif($curentry->[5] eq "DELAY") {
         push(@{$heap->{macs}->{resolving}}, $curip);
      #} elsif($curentry->[5] eq "STALE") {
      #   if ($curip =~ m,172\.16\.0\.,) {
      #      push(@{$heap->{macs}->{cached}}, $curip);
      #   } else {
      #      push(@{$heap->{macs}->{cachedbad}}, $curip);
      #   }
      } else {
         push(@{$heap->{macs}->{cachedunknown}}, $curentry);
      }
   } elsif(($curentry->[3] eq "") && ($curentry->[4] eq "FAILED")) {
      push(@{$heap->{macs}->{resolving}}, $curip);
   } else {
      push(@{$heap->{macs}->{badbad}}, $curip);
   }
}

sub handleMacResult {
   my $heap = shift;
   my $wheelid = shift;
   my $long = shift;
   $heap->{macs}->{user} ||= [];
   my $count = @{$livedata->{macs}->{"user"}}; #scalar(@{$heap->{macs}->{user}});
   my $trackdata = $heap->{trackdata}->{$wheelid};
   print $count." MACs.\n";
   $locked = `wget --timeout=5 --no-check-certificate https://labctl.ffa/sphincter/?action=state -O - 2>/dev/null`;
   my $netstat = `ssh -o "BatchMode=yes" -i /opt/HiEnrich.config/netstat 172.16.16.2`;
   chomp($netstat);
   my $net = [split(":", $netstat)];
   print "RX:".$net->[0]." TX:".$net->[1]." BW:".$net->[2]."\n";
   #$rrd->update(
   #   macs => $count,
   #   open => ($locked eq "UNLOCKED") ? "1" : ($locked eq "LOCKED") ? 0 : undef,
   #);
   print $count." MACs and ".$locked.".\n";
   print $rrd2;
   #print $rrd2->update(
   #   $rrdfile2,
   #   time(),
   #   netrx => $net->[0],
   #   nettx => $net->[1],
   #   netbw => $net->[2],
   #);
   print "RX:".$net->[0].": TX:".$net->[1].": BW:".$net->[2].":\n";
   #my %rtn = $rrd->graph(
   #   periods => [ qw(week month daily hour annual) ],
   #   destination => "/var/www/labstat.tmp/",
   #   title => "User statistics on WLAN",
   #   vertical_label => "Uniq MACs",
   #   interlaced => "",
   #   width => 1000,
   #);
   #printf("Created %s\n",join(", ",map { $rtn{$_}->[0] } keys %rtn));
   #my %rtn2 = $rrd2->graph(
   #   periods => [ qw(week month daily hour annual) ],
   #   basename => "network",
   #   destination => "/var/www/labstat.tmp/",
   #   title => "Internet traffic statistics",
   #   vertical_label => "Bandwidth in bytes/sec",
   #   interlaced => "",
   #   width => 1000,
   #   #height => 300,
   #);
   #printf("Created %s\n",join(", ",map { $rtn2{$_}->[0] } keys %rtn2));
   system("bash", "-c", "/bin/mv /var/www/labstat.tmp/* /var/www/labstat/");
   my $return = "".($count ? ($count." user") : "Lab geschlossen.");
   $return .= " [".join(" ", map { $_."[".scalar(@{$heap->{macs}->{$_}})."]" } sort { (scalar(@{$heap->{macs}->{$b}}) <=> scalar(@{$heap->{macs}->{$a}})) || ($a cmp $b) } keys %{$heap->{macs}})."]"
      if $long;
   return $return;
}
