#!/usr/bin/perl
#
# Module: dmvpn-config.pl
#

use strict;
use lib "/opt/vyatta/share/perl5";

use constant IKELIFETIME_DEFAULT => 28800;    # 8 hours
use constant ESPLIFETIME_DEFAULT => 3600;     # 1 hour
use constant REKEYMARGIN_DEFAULT => 540;      # 9 minutes
use constant REKEYFUZZ_DEFAULT   => 100;
use constant INVALID_LOCAL_IP    => 254;
use constant VPN_MAX_PROPOSALS   => 10;

use Vyatta::TypeChecker;
use Vyatta::VPN::Util;
use Getopt::Long;
use Vyatta::Misc;
use NetAddr::IP;
use Vyatta::VPN::vtiIntf;

my $config_file;
my $secrets_file;
my $init_script;
my $tunnel_context;
my $tun_id;
GetOptions(
    "config_file=s"  => \$config_file,
    "secrets_file=s" => \$secrets_file,
    "init_script=s"  => \$init_script,
    "tunnel_context" => \$tunnel_context,
    "tun_id=s"       => \$tun_id
);
my $CA_CERT_PATH     = '/etc/ipsec.d/cacerts';
my $CRL_PATH         = '/etc/ipsec.d/crls';
my $SERVER_CERT_PATH = '/etc/ipsec.d/certs';
my $SERVER_KEY_PATH  = '/etc/ipsec.d/private';
my $LOGFILE          = '/var/log/vyatta/ipsec.log';

my $vpn_cfg_err   = "VPN configuration error:";
my $clustering_ip = 0;
my $dhcp_if       = 0;
my $genout;
my $genout_secrets;

# Set $using_klips to 1 if kernel IPsec support is provided by KLIPS.
# Set it to 0 if using NETKEY.
my $using_klips = 0;

$genout         .= "# generated by $0\n\n";
$genout_secrets .= "# generated by $0\n\n";

#
# Prepare Vyatta::Config object
#
use Vyatta::Config;
my $vc    = new Vyatta::Config();
my $vcVPN = new Vyatta::Config();
$vcVPN->setLevel('vpn');

# check to see if the config has changed.
# if it has not then exit
my $ipsecstatus = $vcVPN->isChanged('ipsec');
if ( $ipsecstatus && $tunnel_context ) {

    # no sence to do same update twice, will be done via vpn context
    exit 0;
}
if ( !$ipsecstatus ) {
    my $tun_ip_changed = 0;
    my @tuns           = $vc->listNodes('interfaces tunnel');
    my @profs          = $vcVPN->listNodes('ipsec profile');
    foreach my $prof (@profs) {
        my @tuns = $vcVPN->listNodes("ipsec profile $prof bind tunnel");
        foreach my $tun (@tuns) {
            my $lip_old =
              $vc->returnOrigValue("interfaces tunnel $tun local-ip");
            my $lip_new = $vc->returnValue("interfaces tunnel $tun local-ip");
            if ( !( "$lip_old" eq "$lip_new" ) ) {
                if ($tun_ip_changed) {

          # tunnel $tun_id is not the last tunnel with updated local-ip, so skip
                    exit 0;
                }
                if ( "$tun" eq "$tun_id" ) {
                    $tun_ip_changed = 1;
                }
            }
        }
    }
    if ( !$tun_ip_changed ) {
        exit 0;
    }
}
if ( $vcVPN->exists('ipsec') ) {

    #
    # Connection configurations
    #
    my @profiles     = $vcVPN->listNodes('ipsec profile');
    my $prev_profile = "";
    foreach my $profile (@profiles) {
        my $profile_ike_group =
          $vcVPN->returnValue("ipsec profile $profile ike-group");
        if ( !defined($profile_ike_group) || $profile_ike_group eq '' ) {
            vpn_die(
                [ "vpn", "ipsec", "profile", $profile, "ike-group" ],
"$vpn_cfg_err No IKE group specified for profile \"$profile\".\n"
            );
        }
        elsif ( !$vcVPN->exists("ipsec ike-group $profile_ike_group") ) {
            vpn_die(
                [ "vpn", "ipsec", "profile", $profile, "ike-group" ],
"$vpn_cfg_err The IKE group \"$profile_ike_group\" specified for profile "
                  . "\"$profile\" has not been configured.\n"
            );
        }

        my $authid =
          $vcVPN->returnValue("ipsec profile $profile authentication id");

        #
        # ESP group
        #
        my $profile_esp_group =
          $vcVPN->returnValue("ipsec profile $profile esp-group");
        if ( !defined($profile_esp_group) || $profile_esp_group eq '' ) {
            vpn_die(
                [ "vpn", "ipsec", "profile", $profile, "esp-group" ],
"$vpn_cfg_err No ESP group specified for profile \"$profile\".\n"
            );
        }
        elsif ( !$vcVPN->exists("ipsec esp-group $profile_esp_group") ) {
            vpn_die(
                [ "vpn", "ipsec", "profile", $profile, "esp-group" ],
                "$vpn_cfg_err The ESP group \"$profile_esp_group\" specified "
                  . "for profile \"$profile\" has not been configured.\n"
            );
        }

        #
        # Authentication mode
        #
        #
        # Write shared secrets to ipsec.secrets
        #
        my $auth_mode =
          $vcVPN->returnValue("ipsec profile $profile authentication mode");
        my $psk = '';
        if ( !defined($auth_mode) || $auth_mode eq '' ) {
            vpn_die(
                [ "vpn", "ipsec", "profile", $profile, "authentication" ],
"$vpn_cfg_err No authentication mode for profile \"$profile\" specified.\n"
            );
        }
        elsif ( defined($auth_mode) && ( $auth_mode eq 'pre-shared-secret' ) ) {
            $psk = $vcVPN->returnValue(
                "ipsec profile $profile authentication pre-shared-secret");
            my $orig_psk = $vcVPN->returnOrigValue(
                "ipsec profile $profile authentication pre-shared-secret");
            $orig_psk = "" if ( !defined($orig_psk) );
            if ( $psk ne $orig_psk && $orig_psk ne "" ) {
                print
"WARNING: The pre-shared-secret will not be updated until the next re-keying interval\n";
                print "To force the key change use: 'reset vpn ipsec-peer'\n";
            }
            if ( !defined($psk) || $psk eq '' ) {
                vpn_die(
                    [ "vpn", "ipsec", "profile", $profile, "authentication" ],
"$vpn_cfg_err No 'pre-shared-secret' specified for profile \"$profile\""
                      . " while 'pre-shared-secret' authentication mode is specified.\n"
                );
            }
        }
        else {
            vpn_die(
                [ "vpn", "ipsec", "profile", $profile, "authentication" ],
"$vpn_cfg_err Unknown/unsupported authentication mode \"$auth_mode\" for profile "
                  . "\"$profile\" specified.\n"
            );
        }

        my @tunnels = $vcVPN->listNodes("ipsec profile $profile bind tunnel");

        foreach my $tunnel (@tunnels) {

            #
            # Check whether this tunnel is already in some profile
            #
            foreach my $prof (@profiles) {
                if ( $prof != $profile ) {
                    if (
                        $vcVPN->exists(
                            "ipsec profile $prof bind tunnel $tunnel")
                      )
                    {
                        vpn_die(
                            [
                                "vpn",  "ipsec",  "profile", $profile,
                                "bind", "tunnel", $tunnel
                            ],
"$vpn_cfg_err Tunnel \"$tunnel\" is already configured in profile \"$prof\"."
                        );
                    }
                }
            }

            my $needs_passthrough = 'false';
            my $tunKeyword        = 'tunnel ' . "$tunnel";

            my $conn_head = "conn vpnprof-tunnel-$tunnel\n";
            $genout .= $conn_head;

            my $lip = $vc->returnValue("interfaces tunnel $tunnel local-ip");
            my $leftsourceip = undef;

            $genout .= "\tleft=$lip\n";
            $leftsourceip = "\tleftsourceip=$lip\n";
            $genout .= "\tleftid=$authid\n" if defined $authid;

            my $right    = '%any';
            my $any_peer = 1;

            $genout .= "\tright=$right\n";
            if ($any_peer) {
                $genout .= "\trekey=no\n";
            }

            #
            # Protocol/port
            #
            my $protocol   = "gre";
            my $lprotoport = '';
            if ( defined($protocol) ) {
                $lprotoport .= $protocol;
            }
            if ( not( $lprotoport eq '' ) ) {
                $genout .= "\tleftprotoport=$lprotoport\n";
            }

            my $rprotoport = '';
            if ( defined($protocol) ) {
                $rprotoport .= $protocol;
            }
            if ( not( $rprotoport eq '' ) ) {
                $genout .= "\trightprotoport=$rprotoport\n";
            }

            #
            # Write IKE configuration from group
            #
            my $ikelifetime = IKELIFETIME_DEFAULT;
            $genout .= "\tike=";
            my $ike_group =
              $vcVPN->returnValue("ipsec  profile $profile ike-group");
            if ( defined($ike_group) && $ike_group ne '' ) {
                my @ike_proposals =
                  $vcVPN->listNodes("ipsec ike-group $ike_group proposal");

                my $first_ike_proposal = 1;
                foreach my $ike_proposal (@ike_proposals) {

                    #
                    # Get encryption, hash & Diffie-Hellman  key size
                    #
                    my $encryption = $vcVPN->returnValue(
"ipsec ike-group $ike_group proposal $ike_proposal encryption"
                    );
                    my $hash = $vcVPN->returnValue(
                        "ipsec ike-group $ike_group proposal $ike_proposal hash"
                    );
                    my $dh_group = $vcVPN->returnValue(
"ipsec ike-group $ike_group proposal $ike_proposal dh-group"
                    );

                    #
                    # Write separator if not first proposal
                    #
                    if ($first_ike_proposal) {
                        $first_ike_proposal = 0;
                    }
                    else {
                        $genout .= ",";
                    }

                    #
                    # Write values
                    #
                    if ( defined($encryption) && defined($hash) ) {
                        $genout .= "$encryption-$hash";
                        if ( defined($dh_group) ) {
                            if ( $dh_group eq '2' ) {
                                $genout .= '-modp1024';
                            }
                            elsif ( $dh_group eq '5' ) {
                                $genout .= '-modp1536';
                            }
                            elsif ( $dh_group ne '' ) {
                                vpn_die(
                                    [
                                        "vpn",     "ipsec",
                                        "profile", $profile,
                                        "bind",    "tunnel",
                                        $tunnel
                                    ],
"$vpn_cfg_err Invalid 'dh-group' $dh_group specified in "
                                      . "profile \"$profile\" for $tunKeyword.  Only 2 or 5 accepted.\n"
                                );
                            }
                        }
                    }
                }

                #why we always set strict mode?
                $genout .= "!\n";

                my $t_ikelifetime =
                  $vcVPN->returnValue("ipsec ike-group $ike_group lifetime");
                if ( defined($t_ikelifetime) && $t_ikelifetime ne '' ) {
                    $ikelifetime = $t_ikelifetime;
                }
                $genout .= "\tikelifetime=$ikelifetime" . "s\n";

                #
                # Check for Dead Peer Detection DPD
                #
                my $dpd_interval = $vcVPN->returnValue(
                    "ipsec ike-group $ike_group dead-peer-detection interval");
                my $dpd_timeout = $vcVPN->returnValue(
                    "ipsec ike-group $ike_group dead-peer-detection timeout");
                my $dpd_action = $vcVPN->returnValue(
                    "ipsec ike-group $ike_group dead-peer-detection action");
                if (   defined($dpd_interval)
                    && defined($dpd_timeout)
                    && defined($dpd_action) )
                {
                    $genout .= "\tdpddelay=$dpd_interval" . "s\n";
                    $genout .= "\tdpdtimeout=$dpd_timeout" . "s\n";
                    $genout .= "\tdpdaction=$dpd_action\n";
                }
            }

            #
            # Write ESP configuration from group
            #
            my $esplifetime = ESPLIFETIME_DEFAULT;
            $genout .= "\tesp=";
            my $esp_group =
              $vcVPN->returnValue("ipsec profile $profile esp-group");
            if ( defined($esp_group) && $esp_group ne '' ) {
                my @esp_proposals =
                  $vcVPN->listNodes("ipsec esp-group $esp_group proposal");
                my $first_esp_proposal = 1;
                foreach my $esp_proposal (@esp_proposals) {

                    #
                    # Get encryption, hash
                    #
                    my $encryption = $vcVPN->returnValue(
"ipsec esp-group $esp_group proposal $esp_proposal encryption"
                    );
                    my $hash = $vcVPN->returnValue(
                        "ipsec esp-group $esp_group proposal $esp_proposal hash"
                    );

                    #
                    # Write separator if not first proposal
                    #
                    if ($first_esp_proposal) {
                        $first_esp_proposal = 0;
                    }
                    else {
                        $genout .= ",";
                    }

                    #
                    # Write values
                    #
                    if ( defined($encryption) && defined($hash) ) {
                        $genout .= "$encryption-$hash";
                    }
                }
                $genout .= "!\n";

                my $t_esplifetime =
                  $vcVPN->returnValue("ipsec esp-group $esp_group lifetime");
                if ( defined($t_esplifetime) && $t_esplifetime ne '' ) {
                    $esplifetime = $t_esplifetime;
                }
                $genout .= "\tkeylife=$esplifetime" . "s\n";

                my $lower_lifetime = $ikelifetime;
                if ( $esplifetime < $ikelifetime ) {
                    $lower_lifetime = $esplifetime;
                }

                #
                # The lifetime values need to be greater than:
                #   rekeymargin*(100+rekeyfuzz)/100
                #
                my $rekeymargin = REKEYMARGIN_DEFAULT;
                if ( $lower_lifetime <= ( 2 * $rekeymargin ) ) {
                    $rekeymargin = int( $lower_lifetime / 2 ) - 1;
                }
                $genout .= "\trekeymargin=$rekeymargin" . "s\n";

                #
                # Mode (tunnel or transport)
                #
                my $espmode =
                  $vcVPN->returnValue("ipsec esp-group $esp_group mode");
                if ( !defined($espmode) || $espmode eq '' ) {
                    $espmode = "tunnel";
                }
                $genout .= "\ttype=$espmode\n";

                #
                # Perfect Forward Secrecy
                #
                my $pfs = $vcVPN->returnValue("ipsec esp-group $esp_group pfs");
                if ( defined($pfs) ) {
                    if ( $pfs eq 'enable' ) {
                        $genout .= "\tpfs=yes\n";
                    }
                    elsif ( $pfs eq 'dh-group2' ) {
                        $genout .= "\tpfs=yes\n";
                        $genout .= "\tpfsgroup=modp1024\n";
                    }
                    elsif ( $pfs eq 'dh-group5' ) {
                        $genout .= "\tpfs=yes\n";
                        $genout .= "\tpfsgroup=modp1536\n";
                    }
                    else {
                        $genout .= "\tpfs=no\n";
                    }
                }

                #
                # Compression
                #
                my $compression =
                  $vcVPN->returnValue("ipsec esp-group $esp_group compression");
                if ( defined($compression) ) {
                    if ( $compression eq 'enable' ) {
                        $genout .= "\tcompress=yes\n";
                    }
                    else {
                        $genout .= "\tcompress=no\n";
                    }
                }
            }

            #
            # Authentication
            #
            $right = '%any';
            if ( not( $prev_profile eq $profile ) ) {
                $genout_secrets .= "\n$lip $right ";
                if ( defined($authid) ) {
                    $genout_secrets .= "$authid ";
                }
                $genout_secrets .= ": PSK \"$psk\" ";
            }
            $prev_profile = $profile;
            if ( defined($auth_mode) && ( $auth_mode eq 'pre-shared-secret' ) )
            {
                $genout .= "\tauthby=secret\n";
            }

            #
            # Start automatically
            #
            if ($any_peer) {
                $genout .= "\tauto=add\n";
                $genout .= "\tkeyingtries=%forever\n";
            }
            else {
                $genout .= "\tauto=start\n";
            }
            $genout .= "#$conn_head"; # to identify end of connection definition
                                      # used by clear vpn op-mode command
        }
    }

}
else {

    #
    # remove any previous config lines, so that when "clear vpn ipsec-process"
    # is called it won't find the vyatta keyword and therefore will not try
    # to start the ipsec process.
    #
    $genout = '';
    $genout         .= "# No VPN configuration exists.\n";
    $genout_secrets .= "# No VPN configuration exists.\n";
}

if (
    !(
           defined($config_file)
        && ( $config_file ne '' )
        && defined($secrets_file)
        && ( $secrets_file ne '' )
    )
  )
{
    print "Regular config file output would be:\n\n$genout\n\n";
    print "Secrets config file output would be:\n\n$genout_secrets\n\n";
    exit(0);
}

write_config( $genout, $config_file, $genout_secrets, $secrets_file );

my $update_interval      = $vcVPN->returnValue("ipsec auto-update");
my $update_interval_orig = $vcVPN->returnOrigValue("ipsec auto-update");
$update_interval_orig = 0 if !defined($update_interval_orig);
if ( is_vpn_running() ) {
    vpn_exec( 'ipsec rereadall >&/dev/null', 're-read secrets and certs' );
    vpn_exec( 'ipsec update >&/dev/null',    'update changes to ipsec.conf' );
}
else {
    if ( !defined($update_interval) ) {
        vpn_exec( 'ipsec start >&/dev/null', 'start ipsec' );
    }
    else {
        vpn_exec(
            'ipsec start --auto-update ' . $update_interval . ' >&/dev/null',
            'start ipsec with auto-update $update_interval' );
    }
}

#
# Return success
#
exit 0;

sub vpn_die {
    my ( @path, $msg ) = @_;
    Vyatta::Config::outputError( @path, $msg );
    exit 1;
}

sub write_config {
    my ( $genout, $config_file, $genout_secrets, $secrets_file ) = @_;

    open my $output_config, '>', $config_file
      or die "Can't open $config_file: $!";
    print ${output_config} $genout;
    close $output_config;

    open my $output_secrets, '>', $secrets_file
      or die "Can't open $secrets_file: $!";
    print ${output_secrets} $genout_secrets;
    close $output_secrets;
}

sub vpn_exec {
    my ( $command, $desc ) = @_;

    open my $logf, '>>', $LOGFILE
      or die "Can't open $LOGFILE: $!";

    use POSIX;
    my $timestamp = strftime( "%Y-%m-%d %H:%M.%S", localtime );

    print ${logf} "$timestamp\nExecuting: $command\nDescription: $desc\n";

    my $cmd_out = qx($command);
    my $rval    = ( $? >> 8 );
    print ${logf} "Output:\n$cmd_out\n---\n";
    print ${logf} "Return code: $rval\n";
    if ($rval) {
        if ( $command =~ /^ipsec.*--asynchronous$/
            && ( $rval == 104 || $rval == 29 ) )
        {
            print ${logf} "OK when bringing up VPN connection\n";
        }
        else {

            #
            # We use to consider the commit failed if we got a error
            # from the call to ipsec, but this causes the configuration
            # to not get included in the running config.  Now that
            # we support dynamic interface/address (e.g. dhcp, pppoe)
            # we want a valid config to get committed even if the
            # interface doesn't exist yet.  That way we can use
            # "clear vpn ipsec-process" to bring up the tunnel once
            # the interface is instantiated.  For pppoe we will add
            # a script to /etc/ppp/ip-up.d to bring up the vpn
            # tunnel.
            #
            print ${logf}
              "VPN commit error.  Unable to $desc, received error code $?\n";

            #
            # code 768 is for a syntax error in the secrets file
            # this happens when a dhcp interface is configured
            # but no address is assigned yet.
            # only the line that has the syntax error is not loaded
            # So we can safely ignore this error since our code generates
            # secrets file.
            #
            if ( $? ne '768' ) {
                print "Warning: unable to [$desc], received error code $?\n";
                print "$cmd_out\n";
            }
        }
    }
    print ${logf} "---\n\n";
    close $logf;
}

sub printTree {
    my ( $vc, $path, $depth ) = @_;

    my @children = $vc->listNodes($path);
    foreach my $child (@children) {
        print '    ' x $depth;
        print $child . "\n";
        printTree( $vc, "$path $child", $depth + 1 );
    }
}

sub printTreeOrig {
    my ( $vc, $path, $depth ) = @_;

    my @children = $vc->listOrigNodes($path);
    foreach my $child (@children) {
        print '    ' x $depth;
        print $child . "\n";
        printTreeOrig( $vc, "$path $child", $depth + 1 );
    }
}

# end of file
