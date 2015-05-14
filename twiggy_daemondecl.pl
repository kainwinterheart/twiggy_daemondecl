#!/usr/bin/perl -w

use strict;
use warnings;

BEGIN {

    require Carp;

    $SIG{ __DIE__ } = \&Carp::confess;
    $SIG{ __WARN__ } = \&Carp::cluck;
};

use JSON 'decode_json';
use AnyEvent ();
use Getopt::Long 'GetOptions';
use Scalar::Util 'blessed';
use Plack::Request ();
use Twiggy::Server ();
use AnyEvent::Handle ();
use Salvation::DaemonDecl;

my $host = undef;
my $port = undef;
my $backlog = 256;
my $workers = 10;

GetOptions(
    'host=s', \$host,
    'port=i', \$port,
    'backlog=i', \$backlog,
    'workers=i', \$workers,
);

die( 'Host is not specified' ) unless defined $host;
die( 'Port is not specified' ) unless defined $port;

my $err = *STDERR{ 'GLOB' };

worker {
    name 'main',
    max_instances 1,
    log {
        warn @_;
    },
    main {
        my $server = undef;
        my %sockets = ();
        my $global_cv = AE::cv;

        worker {
            name 'worker',
            max_instances $workers,
            log {
                warn @_;
            },
            main {
                my ( $worker ) = @_;
                
                if( defined $server ) {

                    # magic
                    $server -> { 'exit_guard' } -> send();
                    undef( $server );
                }

                my $out = undef;
                my $cv = AnyEvent -> condvar();
                my $read_cv = $worker -> read_from_parent( 4, sub {
                
                    my ( $len ) = @_;
                    $len = unpack( 'N', $len );

                    my $read_cv = $worker -> read_from_parent( $len, sub {
                    
                        my ( $data ) = @_;
                        $data = decode_json( $data );

                        my $request = Plack::Request -> new( @$data );

                        $out = $request -> parameters() -> get( 'echo' );
                    } );

                    $read_cv -> cb( sub { $cv -> send() } );
                } );

                $read_cv -> cb( sub {
                
                    if( my $v = $read_cv -> recv() ) {

                        $cv -> send();
                    }
                } );

                $cv -> cb( sub {
                
                    if( length( $out //= '' ) > 0 ) {

                        $worker -> write_to_parent( pack( 'N', length( $out ) ) . $out );
                    }
                } );

                wait_cond( $cv );
            },
            reap {
                my ( $finish, $pid ) = @_;
                my $socket = delete( $sockets{ $pid } );

                my $read_cv = read_from( $pid, 4, sub {
                
                    my ( $len ) = @_;
                    $len = unpack( 'N', $len );

                    my $read_cv = read_from( $pid, $len, sub {
                    
                        my ( $data ) = @_;

                        $socket -> push_write( $data . "\n" ) if defined $socket;
                    } );

                    $read_cv -> cb( sub {

                        $socket -> push_shutdown();
                        $finish -> ();
                    } );
                } );

                $read_cv -> cb( sub {

                    if( $read_cv -> recv() ) {

                        $socket -> push_shutdown();
                        $finish -> ();
                    }
                } );
            },
            rw,
        };

        my @pids = ();
        my $start = sub {

            my $server = Twiggy::Server -> new( host => $host, port => $port, backlog => $backlog );

            $server -> register_service( sub {

                my ( $env, @rest ) = @_;

                while( can_spawn_worker( 'worker' ) ) {

                    my $pid = spawn_worker( 'worker' );
                    push( @pids, $pid );
                }

                $env = { %$env };
                delete( @$env{ 'psgi.errors', 'psgix.io', 'psgi.input' } ); # magic

                my $data = eval{ JSON -> new() -> utf8() -> allow_blessed() -> convert_blessed() -> encode( [ $env, @rest ] ) };

                if( $@ ) {

                    $err -> print( $@ );

                } else {

                    return sub {
                    
                        my ( undef, $socket ) = @_;
                        my $pid = undef;

                        while( scalar( @pids ) > 0 ) {

                            my $local_pid = shift( @pids );

                            if( kill( 0, $local_pid ) ) {

                                $pid = $local_pid;
                                last;

                            } else {

                                delete( $sockets{ $local_pid } );
                            }
                        }

                        if( ! defined $pid && can_spawn_worker( 'worker' ) ) {

                            $pid = spawn_worker( 'worker' );
                        }

                        if( defined $pid ) {

                            $sockets{ $pid } = AnyEvent::Handle -> new( fh => $socket );
                            eval{ write_to( $pid, pack( 'N', length( $data ) ) . $data ) };

                            if( $@ ) {

                                $err -> print( $@ );
                                delete( $sockets{ $pid } );
                                $socket -> close();
                            }

                        } else {

                            $socket -> close();
                        }

                        return;
                    };
                }
            } );

            return $server;
        };

        $server //= $start -> ();
        wait_cond( AnyEvent -> condvar() );
#         my $stahp = 0;
#         my @sig = map( { AnyEvent -> signal( signal => $_, cb => sub { $stahp = 1; } ) } ( 'TERM', 'INT', 'ABRT', 'HUP' ) );
# 
#         until( $stahp ) {
# 
#             unless( can_spawn_worker( 'worker' ) ) {
# 
#                 $server //= $start -> ();
#                 wait_worker_slot( 'worker' );
#             }
# 
#             last if $stahp;
#             next unless can_spawn_worker( 'worker' );
# 
#             my $pid = spawn_worker( 'worker' );
#             push( @pids, $pid );
#         }
    },
};

daemon_main 'main';

exit 0;

__END__
