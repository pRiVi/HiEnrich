use strict;
use warnings;
use POE qw(Component::IRC Component::IRC::Plugin::AutoJoin Component::IRC::Plugin::NickServID Wheel::Run Component::Server::TCP);

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

my $port = 12345;
my $address = '127.0.0.1';

# Der Remote SSH Server hat folgende /root/.ssh/authorized_keys:
# command="/usr/sbin/arp -an",no-port-forwarding,no-X11-forwarding,no-pty ssh-rsa KEY.......
my $maccmd = ["/usr/bin/ssh", "-i", "/opt/HiEnrich/getmacs", "10.11.7.1"];

my $cmddef = [
   ['status', '^\.status$',  $maccmd],
   ['df',     '^\.df$',      ["/bin/df"]],
   ['uptime', '^\.uptime$',  ["/usr/bin/uptime"]],
   ['ping',   '^\.ping$',    ["ping", "-c", "4", "www.heise.de"]],
   ['ping2',  '^\.pingd?ns$',["ping", "-c", "4", "8.8.8.8"]],
];

my $irc = POE::Component::IRC->spawn(
   nick => $nickname,
   ircname => $ircname,
   server  => $server,
) or die "Oh noooo! $!";

die "Kein passwortfile oder kein Passwort darin!"
   unless $password;

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
         $irc->yield( privmsg => '#augsburg' => "Labstatus hat sich geaendert: ".handleMacResult($heap, $wheelid))
            if $report;
         $heap->{macs} = {};
         delete $heap->{trackdata}->{$wheelid};
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
               $irc->yield( privmsg => '#augsburg' => $client_input );
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
         $heap->{macs} = {};
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
   if($curentry->[3] =~ m,incomplete,) {
      push(@{$heap->{macs}->{resolving}}, $curentry)
   } elsif($curentry->[3] =~ m,54:04:a6:61:01:f0,) {
      push(@{$heap->{macs}->{server}}, $curentry);
   } elsif(($curentry->[3] =~ m,00:0d:b9:28:92:d2,) ||
           ($curentry->[3] =~ m,00:0d:b9:27:41:68,) ||
           ($curentry->[3] =~ m,64:70:02:39:6c:15,) ||
           ($curentry->[3] =~ m,24:a4:3c:44:c9:65,) ||
           ($curentry->[3] =~ m,00:24:1d:d1:30:c8,)) {
      push(@{$heap->{macs}->{freifunk}}, $curentry);
   } elsif($curentry->[1] =~ m,10\.11\.7\.,) {
      push(@{$heap->{macs}->{user}}, $curentry);
   } elsif($curentry->[2] =~ m,^at$,) {
      push(@{$heap->{macs}->{unknown}}, $curentry);
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
