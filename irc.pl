 use strict;
 use warnings;
 use POE qw(Component::IRC Component::IRC::Plugin::AutoJoin Component::IRC::Plugin::NickServID Wheel::Run);

 my $nickname = 'HiEnrich';
 my $ircname  = 'Flibble the Sailor Bot';
 my $server   = 'irc.freenode.net';

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
         main => [ qw(_default _start irc_001 irc_public) ],
     ],
     inline_states => {
         got_child_stdout => sub {
            my $heap = $_[HEAP];
            my $line = $_[ARG0];
            print $line."\n";
            my $curentry = [split(/\s+/, $line)];
            push(@{$heap->{lastmacs}}, $curentry)
               if (($curentry->[1] =~ m,10\.11\.7\.,) &&
                   ($curentry->[3] !~ m,incomplete,) &&
                   ($curentry->[3] !~ m,54:04:a6:61:01:f0,) &&
                   ($curentry->[3] !~ m,00:0d:b9:28:92:d2,) &&
                   ($curentry->[3] !~ m,00:0d:b9:27:41:68,) &&
                   ($curentry->[3] !~ m,00:24:1d:d1:30:c8,));
         },
         got_child_close => sub {
            my $heap = $_[HEAP];
            my $wheelid = $_[ARG0];
            my $count = scalar(@{$heap->{lastmacs}});
            print $count." MACs.\n";
            $irc->yield( privmsg => $heap->{channel}->{$wheelid} => $count ? ($count." user") : "Lab geschlossen." );
            $heap->{lastmacs} = [];
            delete $heap->{channel}->{$wheelid};
         },
     },
     heap => { irc => $irc },
 );

 $poe_kernel->run();

 sub _start {
     my $heap = $_[HEAP];

     # retrieve our component's object from the heap where we stashed it
     my $irc = $heap->{irc};

     $irc->yield( register => 'all' );
     $irc->yield( connect => { } );
     $irc->plugin_add( 'HiEnrich2014', POE::Component::IRC::Plugin::NickServID->new(
        Password => 'Aish9mei'
     ));
     $irc->plugin_add('AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => \%channels, RejoinOnKick => 1, Retry_when_banned => 1,  ));
     return;
 }

 sub irc_001 {
     my $sender = $_[SENDER];

     # Since this is an irc_* event, we can get the component's object by
     # accessing the heap of the sender. Then we register and connect to the
     # specified server.
     my $irc = $sender->get_heap();

     print "Connected to ", $irc->server_name(), "\n";

     # we join our channels
     #$irc->yield( join => $_ ) for @channels;
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
