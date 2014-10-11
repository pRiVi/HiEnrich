use strict;
use warnings;
use POE qw(Component::IRC Component::IRC::Plugin::AutoJoin Component::IRC::Plugin::NickServID Wheel::Run Component::Server::TCP Component::Server::HTTP Component::Client::HTTP);
use JSON;

$SIG{CHLD} = 'IGNORE';

my $nickname = 'HiEnrich';
my $ircname  = 'Flibble the Sailor Bot';
my $server   = 'irc.freenode.net';

# Nickserv
my $nickid = 'HiEnrich';
my $password = `cat /opt/HiEnrich/password.txt`;

# Interval we report a closing lab in maximum
my $secs = 60*5; # Seconds

my $channels = {
   '#test.privi'   => '',
   '#augsburg'     => '',
};

my $dstchannel = '#augsburg';

my $port = 12345;
my $address = '127.0.0.1';

# Der Remote SSH Server hat folgende /root/.ssh/authorized_keys:
# command="/usr/sbin/arp -an",no-port-forwarding,no-X11-forwarding,no-pty ssh-rsa KEY.......
my $maccmd = ["/usr/bin/ssh", "-i", "/opt/HiEnrich/getmacs", "10.11.7.16"];

my $cmddef = [
   ['status', '^\.status$',  $maccmd],
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
   nick => $nickname,
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
         print $line."\n";
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
         unless ($heap->{curstate} == $newstate) {
            if ($newstate) {
               $report++;
               $heap->{curstate} = $newstate;
            } else {
               if ($heap->{curcounttime}) {
                  if ((time()-$heap->{curcounttime}) > $secs) {
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
         if ($report) { 
            $irc->yield( privmsg => $dstchannel => "Labstatus hat sich geaendert: ".handleMacResult($heap, $wheelid));
            $poe_kernel->post('ua', 'request','send_to_muesli', HTTP::Request->new(POST => "http://10.11.8.116:12346/netstatus" => HTTP::Headers->new() => getStatusJSON()))
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
                  $poe_kernel->post('ua', 'request','send_to_muesli', HTTP::Request->new(POST => "http://10.11.8.116:12346/netstatus" => HTTP::Headers->new() => getStatusJSON()));
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
         print $line."\n";
         if ($trackdata->{curcmd}->[0] eq "status") {
            parseMacLine($line, $heap);
         } else { 
            $irc->yield( privmsg => $trackdata->{channel} => $line );
         }
      },
      got_child_close => sub {
         my $heap = $_[HEAP];
         my $wheelid = $_[ARG0];
         my $trackdata = $heap->{trackdata}->{$wheelid};
         if ($trackdata->{curcmd}->[0] eq "status") {
            $irc->yield( privmsg => $heap->{trackdata}->{$wheelid}->{channel} => handleMacResult($heap, $wheelid));
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
         if ($curip =~ m,10\.11\.7\.,) {
            push(@{$heap->{macs}->{user}}, $curentry);
         } elsif($curentry->[3] eq "lladdr") {
            push(@{$heap->{macs}->{unknown}}, $curentry);
         } else {
            push(@{$heap->{macs}->{bad}}, $curentry);
         }
      } elsif($curentry->[5] eq "DELAY") {
         push(@{$heap->{macs}->{resolving}}, $curip);
      #} elsif($curentry->[5] eq "STALE") {
      #   if ($curip =~ m,10\.11\.7\.,) {
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
   $heap->{macs}->{user} ||= [];
   my $count = scalar(@{$heap->{macs}->{user}});
   my $trackdata = $heap->{trackdata}->{$wheelid};
   print $count." MACs.\n";
   my $return = "".($count ? ($count." user") : "Lab geschlossen.")." [".join(" ", map { $_."[".scalar(@{$heap->{macs}->{$_}})."]" } sort { (scalar(@{$heap->{macs}->{$b}}) <=> scalar(@{$heap->{macs}->{$a}})) || ($a cmp $b) } keys %{$heap->{macs}})."]";
   return $return;
}
