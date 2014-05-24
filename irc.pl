 use strict;
 use warnings;
 use POE qw(Component::IRC Component::IRC::Plugin::AutoJoin Component::IRC::Plugin::NickServID Wheel::Run Component::Server::TCP);

 my $nickname = 'HiEnrich';
 my $ircname  = 'Flibble the Sailor Bot';
 my $server   = 'irc.freenode.net';

my $password = `cat /opt/HiEnrich/password.txt|head -1`;

die "Kein passwortfile oder kein Passwort darin!"
   unless $password;

# my @channels = ('#test.privi');
 
my %channels = (
     '#test.privi'   => '',
     '#augsburg'     => '',
 );

 # We create a new PoCo-IRC object
 my $irc = POE::Component::IRC->spawn(
    nick => $nickname,
    ircname => $ircname,
    server  => $server,
 ) or die "Oh noooo! $!";

 POE::Session->create(
     package_states => [
         main => [ qw(_default _start irc_public) ],
     ],
     inline_states => {
         got_child_stdout => sub {
            my $heap = $_[HEAP];
            my $line = $_[ARG0];
            print $line."\n";
            my $curentry = [split(/\s+/, $line)];
            if($curentry->[3] =~ m,incomplete,) {
               push(@{$heap->{macs}->{resolving}}, $curentry)
            } elsif($curentry->[3] =~ m,54:04:a6:61:01:f0,) {
               push(@{$heap->{macs}->{server}}, $curentry);
            } elsif(($curentry->[3] =~ m,00:0d:b9:28:92:d2,) ||
                    ($curentry->[3] =~ m,00:0d:b9:27:41:68,) ||
                    ($curentry->[3] =~ m,00:24:1d:d1:30:c8,)) {
               push(@{$heap->{macs}->{freifunk}}, $curentry);
            } elsif($curentry->[1] =~ m,10\.11\.7\.,) {
               push(@{$heap->{macs}->{user}}, $curentry);
            } else {
               push(@{$heap->{macs}->{unknown}}, $curentry);
            }
         },
         got_child_close => sub {
            my $heap = $_[HEAP];
            my $wheelid = $_[ARG0];
            $heap->{macs}->{user} ||= [];
            my $count = scalar(@{$heap->{macs}->{user}});
            print $count." MACs.\n";
            $irc->yield( privmsg => $heap->{channel}->{$wheelid} => "".($count ? ($count." user") : "Lab geschlossen.")." (".join(", ", map { $_."=".scalar(@{$heap->{macs}->{$_}}) } sort { $a cmp $b } keys %{$heap->{macs}}).")");
            $heap->{macs} = {};
            delete $heap->{channel}->{$wheelid};
         },
     },
     heap => { irc => $irc },
 );

 $poe_kernel->run();

 sub _start {
     my $heap = $_[HEAP];


POE::Component::Server::TCP->new(
    Port => 12345,
    Address => '127.0.0.1',
    ClientInput => sub {
      my $client_input = $_[ARG0];
      $irc->yield( privmsg => "#augsburg" => $client_input );
    }
);

     # retrieve our component's object from the heap where we stashed it
     my $irc = $heap->{irc};

     $irc->yield( register => 'all' );
     $irc->yield( connect => { } );
     $irc->plugin_add( 'HiEnrich2014', POE::Component::IRC::Plugin::NickServID->new(
        Password => $password
     ));
     $irc->plugin_add('AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => \%channels, RejoinOnKick => 1, Retry_when_banned => 1,  ));
     return;
 }

 sub irc_public {
     my ($heap, $sender, $who, $where, $what) = @_[HEAP, SENDER, ARG0 .. ARG2];
     my $nick = ( split /!/, $who )[0];
     my $channel = $where->[0];

     #if ( my ($rot13) = $what =~ /^rot13 (.+)/ ) {
     #    $rot13 =~ tr[a-zA-Z][n-za-mN-ZA-M];
     #    $irc->yield( privmsg => $channel => "$nick: $rot13" );
     #}
     if ($what =~ m,^\.status$,) {
        my $cmd = ["/usr/bin/ssh", "-i", "/opt/HiEnrich/getmacs", "10.11.7.1"];
        print "Running ".join(" ", @$cmd)."\n";
        $heap->{child} = POE::Wheel::Run->new(
           Program => $cmd,
           StdoutEvent  => "got_child_stdout",
           #StderrEvent  => "got_child_stderr",
           CloseEvent   => "got_child_close",
        );
        $heap->{channel}->{$heap->{child}->ID()} = $channel;
     }
     return;
 }
 # We registered for all events, this will produce some debug info.
 sub _default {
     my ($event, $args) = @_[ARG0 .. $#_];
     my @output = ( "$event: " );

     for my $arg (@$args) {
         if ( ref $arg eq 'ARRAY' ) {
             push( @output, '[' . join(', ', @$arg ) . ']' );
         }
         else {
             push ( @output, "'$arg'" );
         }
     }
     print join ' ', @output, "\n";
     return;
 }
