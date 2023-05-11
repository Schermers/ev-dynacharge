#!/usr/bin/env perl

# PODNAME: ev-dynacharge.pl
# ABSTRACT: Dynamically adapt the charge current of an EV vehicle based on the total house energy balance
# VERSION

use strict;
use warnings;

use Net::MQTT::Simple;
use Log::Log4perl qw(:easy);
use Getopt::Long 'HelpMessage';
use Pod::Usage;
use JSON;

my ($verbose, $mqtt_host, $mqtt_username, $mqtt_password);

# Default values
$mqtt_host = 'broker';

GetOptions(
    'host=s'     => \$mqtt_host,
    'user=s'     => \$mqtt_username,
    'pass=s'     => \$mqtt_password,
    'help|?|h'   => sub { HelpMessage(0) },
    'man'        => sub { pod2usage( -exitstatus => 0, -verbose => 2 )},
    'v|verbose'  => \$verbose,
) or HelpMessage(1);

if ($verbose) {
	Log::Log4perl->easy_init($DEBUG);
} else {
   	Log::Log4perl->easy_init($INFO);
}

# Connect to the broker
my $mqtt = Net::MQTT::Simple->new($mqtt_host) || die "Could not connect to MQTT broker: $!";
INFO "MQTT logger client ID is " . $mqtt->_client_identifier();

# Depending if authentication is required, login to the broker
if($mqtt_username and $mqtt_password) {
    $mqtt->login($mqtt_username, $mqtt_password);
}


# Subscribe to topics:
my $set_topic = 'chargepoint/maxcurrent';
my $timers_topic = 'chargepoint/config/#';
#   for access to ..config/boostmode
#                 ..config/haltmode
my $mode = 'chargepoint/mode';
my $nr_phases_topic = 'chargepoint/nr_of_phases';

my $preferredCurrent_topic = 'chargepoint/config/preferredcurrent';
my $preferredNrPhases_topic = 'chargepoint/config/preferrednrofphases';
my $chargeMode_topic = 'chargepoint/config/chargemode';
my $log_topic = 'chargepoint/';
my $details_topic = 'chargepoint/details';

my $maxcurrent = 16;
my $nr_of_phases = 0;

$mqtt->subscribe('dsmr/reading/phase_currently_returned_l1',  \&mqtt_handler);
$mqtt->subscribe('dsmr/reading/phase_currently_returned_l2',  \&mqtt_handler);
$mqtt->subscribe('dsmr/reading/phase_currently_returned_l3',  \&mqtt_handler);
$mqtt->subscribe('dsmr/reading/phase_currently_delivered_l1',  \&mqtt_handler);
$mqtt->subscribe('dsmr/reading/phase_currently_delivered_l2',  \&mqtt_handler);
$mqtt->subscribe('dsmr/reading/phase_currently_delivered_l3',  \&mqtt_handler);
$mqtt->subscribe('dsmr/reading/electricity_currently_delivered',  \&mqtt_handler);
$mqtt->subscribe('dsmr/reading/electricity_currently_returned',  \&mqtt_handler);

$mqtt->subscribe('dsmr/meter-stats/electricity_tariff',  \&mqtt_handler);
$mqtt->subscribe('chargepoint/chargepointStatus',  \&mqtt_handler);
$mqtt->subscribe('chargepoint/voltage',  \&mqtt_handler);
$mqtt->subscribe($timers_topic,  \&mqtt_handler);
# Vars send to charger
my $offset = 0.05;
my $current = 0;
my $previous_current = 0;
my $curren_lastSet = time() - 30;

# Variables for current power
my $sunPowerAvailable = 0;
my $gridUsage = 0;
my $totalPower = 0;
my $l1power = 0;
my $l2power = 0;
my $l3power = 0;
my $difPerc = 0;
my $inSync = 0;

# Charging limits
my $mainfuse = 25;
my $safetyMarge = 2;

my $tariff = 0;
my $realistic_current = 0;

# Configurable variables through MQTT
my $boostmode_timer = 0;
my $preferred_current = 16;
my $preferred_nrPhases = 3;
my $chargepointStatus = 'charging';

# Vars for phase switching
my $phases_counter = 0;
my $phases_lastChecked = 1;
my $phases_lastSwitched = time() - 3600; # Set timer to an hour ago
my $phases_counterLimit = 300; # Limit before changing phases


my $chargingPower = 0;
my $voltage = 0.23;
my $topicUpdated = 0;
my $resetOnDisconnect = 0;

my $chargeMode = 'sunOnly'; # sunOnly, offPeakOnly, sunAndOffPeak, boostUntillDisconnect
my $timestamp = 0;
my $timer_startedCharging = time() - 60; # Set timer to a minute ago

while (1) {
	$mqtt->tick();
	# Check if energy value has been uupdated, and only update if charger is in use
	if ($topicUpdated >= 4 && ($chargepointStatus =~ /connected/ || $chargepointStatus =~ /charging/)) {
		$topicUpdated = 0;
		$previous_current = $current;

		# Determine total power
		$gridUsage = $l1power + $l2power + $l3power;
		$difPerc = $gridUsage/$totalPower*100;
		if ($difPerc < 97 || $difPerc > 103) {
			if ($inSync == 0){
				$topicUpdated++;
				INFO "WARNING | MQTT readings not in sync with total power. Adding value to topicUpdate";
			}
			INFO "WARNING | Sum phases: $gridUsage totalPower: $totalPower (difference: $difPerc %)";
			$gridUsage = $totalPower;
		} else {
			#INFO "Phase power: $gridUsage is the same as totalPower: $totalPower (difference: $difPerc %)";
			if ($inSync == 0 && $difPerc == 100){
				#INFO "MQTT readings are now in sync with total power.";
				$inSync = 1;
			}
		}
		$sunPowerAvailable = $gridUsage * - 1;
		
		# Determine maximum load to avoid switch of the main fuse
		if($chargepointStatus =~ /charging/) {
			$realistic_current = get_maximumCurrent($preferred_current, $current);
		} else {
			$realistic_current = get_maximumCurrent($preferred_current, 0);
		}
		
		if ($maxcurrent == 0) {
			$current = 0;
			INFO "** Current is set to 0, not charging";
		} elsif ($boostmode_timer > 0) {
			if($timestamp == 0) {
				$timestamp = midnight_seconds();
			} else {
				$boostmode_timer = $boostmode_timer - (midnight_seconds() - $timestamp);
				$timestamp = midnight_seconds();
			}
			if($boostmode_timer < 1) {
				$boostmode_timer = 0;
				$timestamp = 0;
			}
			$current = $realistic_current;
			INFO "Boosttimer |  Current boost charge mode active at $realistic_current A - " . $boostmode_timer . " seconds remaining" ;
			$mqtt->publish("chargepoint/status/boostmode_countdown_timer", $boostmode_timer);
		} elsif ($chargeMode =~ /sunOnly/ || $chargeMode =~ /sunAndOffPeak/) {
		
			# 1 phase
			# 1380 min
			# 3680 max
			
			# 3 phases
			# 4140 min
			# 11040 max
			if ($tariff == 1 && $chargeMode =~ /sunAndOffPeak/) {
				$current = $realistic_current;
				set_nrOfPhases($preferred_nrPhases);
			} else {
				# Determine netto energy balance when charging is active - Ignore this if phases just has been switched
				if ($chargepointStatus =~ /charging/ && (time() - $phases_lastSwitched > 12)) {
					DEBUG "Reading of energy balance: $sunPowerAvailable kW";
					$chargingPower = ($nr_of_phases * $current * $voltage);
					$sunPowerAvailable = $sunPowerAvailable + $chargingPower;
					DEBUG "Netto energy balance (including current charging): $sunPowerAvailable kW. Charging at $chargingPower kW";
				}
				
				# Determine amount of phases
				# if ($sunPowerAvailable > (0.0+$offset) && $sunPowerAvailable < (4.0-$offset)) {
				if ($sunPowerAvailable < (4.0-$offset)) {
					# If current number of phases is not equal, update timer
					if ($nr_of_phases != 1) {
						# Update last checked to current time if empty
						if($phases_lastChecked == 0) {
							$phases_lastChecked = time();
							$phases_counter = 0;
						}
						# Update counter
						$phases_counter = time() - $phases_lastChecked;

						# Switch if limit is reached to switch in nr of phases
						if ($phases_counter > $phases_counterLimit || $nr_of_phases == 0) {
							set_nrOfPhases(1);
						}
						else {
							INFO "Wait for switch to 1 phase. Current counter: $phases_counter s (of $phases_counterLimit s)";
						}
					} else {
						# Reset counter if current nr of phases is correct and timer was used
						if($phases_lastChecked != 0 && $chargepointStatus =~ /charging/){
							$phases_lastChecked = 0;
						}
					}
				} elsif ($sunPowerAvailable > (4.14+$offset)) {
					if ($nr_of_phases != 3) {
						# Update last checked to current time if empty
						if($phases_lastChecked == 0) {
							$phases_lastChecked = time();
							$phases_counter = 0;
						}
						# Update counter
						$phases_counter = time() - $phases_lastChecked;
						
						# Switch if limit is reached to switch in nr of phases
						if($phases_counter > $phases_counterLimit || $nr_of_phases == 0) {
							set_nrOfPhases(3);
						}
						else {
							#INFO "Wait for switch to 3 phases. Current counter: $phases_counter s (of $phases_counterLimit s)";
						}
					} else {
						# Reset counter if current nr of phases is correct and timer was used
						if($phases_lastChecked != 0 && $chargepointStatus =~ /charging/){
							$phases_lastChecked = 0;
						}
					}
				} elsif ($nr_of_phases == 0) {
					#INFO "Switching to one-phase charging (not set yet)";
					set_nrOfPhases(1);
				}
				
				# Keep current as is if started charging
				# if ($chargepointStatus =~ /connected/ && (time() - $timer_startedCharging) < 30) {
				if ((time() - $timer_startedCharging) < 30) {
					# Keep current as is
				} else {
					$current = int($sunPowerAvailable / ($voltage * $nr_of_phases));
				}

				$current = $maxcurrent if ($current > $maxcurrent);
				$current =  0 if ($current < 6 && $nr_of_phases == 1);
				if ($current < 3 && $nr_of_phases == 3) {
					$current =  6;
				} elsif ($current < 6 && $nr_of_phases == 3) {
					$current =  6;
				}
			}
			#INFO "$chargeMode | Current is now $current based on available sunpower: $sunPowerAvailable kW with $nr_of_phases phase(s) (current grid usage: $gridUsage)";
		} elsif ($chargeMode =~ /offPeakOnly/) {
			# Off-peak is 1, Normal = 2
			if($tariff == 1) {
				#INFO "$chargeMode selected, charging at $realistic_current A since it is off-Peak";
				$current = $realistic_current;
				set_nrOfPhases($preferred_nrPhases);
			} else {
				#INFO "$chargeMode selected, currently it is normal rate. No charging.";
				$current = 0;
			}
		} elsif ($chargeMode =~ /boostUntillDisconnect/) {
			INFO "$chargeMode | Charging at $realistic_current A.";
			set_nrOfPhases($preferred_nrPhases);
			$current = $realistic_current;
		} elsif ($chargeMode =~ /noCharging/) {
			#INFO "$chargeMode | Charging at 0 A.";
			$current = 0;
		} else {
			INFO "Non valid chargemode selected ($chargeMode), reverting it to default 'sunOnly'. Valid values: sunOnly, offPeakOnly, sunAndOffPeak, boostUntillDisconnect";
			$mqtt->publish($chargeMode_topic, 'sunOnly');
			$current = 0;
		}
		
		# Update new current
		if(time() - $phases_lastSwitched <= 12) {
			#Phases just switched, wait before updating the current
		} elsif($previous_current == $current && (time()-$curren_lastSet) < 30) {
			# Do nothing
			#INFO "Current is update within last 30 seconds. ignore this one.";
		} elsif((time()-$curren_lastSet) < 5) {
			# Give the charger time to react on the previous update
		} else {
			#INFO "Updating current from $previous_current to $current";
			$curren_lastSet = time();
			INFO "$chargeMode | $current A | Grid: $gridUsage | SunPower: $sunPowerAvailable | Max current: $realistic_current | Phases switched: $phases_lastSwitched | Phases counter: $phases_counter | #Phases: $nr_of_phases | Current last set: $curren_lastSet | Volt: $voltage";
			update_loadcurrent($current);
			update_details();
		}

	} else {
		if ($nr_of_phases != 1 && $chargepointStatus =~ /available/) {
			INFO "Reset number of phases to 1 (Current: $nr_of_phases)";
			set_nrOfPhases(1);
			#$nr_of_phases = 0;
			update_details();
		}
	}
	sleep(1);
}

sub mqtt_handler {
	my ($topic, $data) = @_;


	TRACE "Got '$data' from $topic";
		
	if ($topic =~ /phase_currently_returned_l1/) {
		return if ($data == 0); # Do not process empty values
		$l1power = $data * - 1;
		$topicUpdated++;
	} elsif ($topic =~ /phase_currently_returned_l2/) {
		return if ($data == 0); # Do not process empty values
		$l2power = $data * - 1;
		$topicUpdated++;
	} elsif ($topic =~ /phase_currently_returned_l3/) {
		return if ($data == 0); # Do not process empty values
		$l3power = $data * - 1;
		$topicUpdated++;
	} elsif ($topic =~ /phase_currently_delivered_l1/) {
		return if ($data == 0); # Do not process empty values
		$l1power = $data;
		$topicUpdated++;
	} elsif ($topic =~ /phase_currently_delivered_l2/) {
		return if ($data == 0); # Do not process empty values
		$l2power = $data;
		$topicUpdated++;
	} elsif ($topic =~ /phase_currently_delivered_l3/) {
		return if ($data == 0); # Do not process empty values
		$l3power = $data;
		$topicUpdated++;
	} elsif ($topic =~ /electricity_currently_delivered/) {
		return if ($data == 0); # Do not process empty values
		$totalPower = $data;
		$topicUpdated++;
	} elsif ($topic =~ /electricity_currently_returned/) {
		return if ($data == 0); # Do not process empty values
		$totalPower = $data * - 1;
		$topicUpdated++;
	} elsif ($topic =~ /boostperiod/) {
		INFO "Setting boostperiod timer to $data seconds";
		$boostmode_timer = $data;
	} elsif ($topic =~ /maxcurrent/) {
		if ($data > 0 && $data < 16) {
			$maxcurrent = $data;
			INFO "Maximum current is now $maxcurrent A";
		} else {
			WARN "Refuse to set invalid maximum current: '$data'";
		}
	} elsif ($topic =~ /preferredcurrent/) {
		if ($data > 0 && $data < 16) {
			$preferred_current = $data;
			INFO "Preferred current is now $preferred_current A";
		} else {
			WARN "Refuse to set invalid maximum current: '$data'";
		}
	} elsif ($topic =~ /preferrednrofphases/) {
		if ($data == 1 || $data == 3) {
			$preferred_nrPhases = $data;
			INFO "Preferred nr of phases is now $preferred_nrPhases";
		} else {
			WARN "Refuse to set invalid phases number: '$data'";
		}
	} elsif ($topic =~ /electricity_tariff/) {
		return if ($data == 0); # Do not process empty values
		$tariff = $data;
	} elsif ($topic =~ /chargepointStatus/) {
		$chargepointStatus = $data;
		INFO "Chargepoint status: $data";
		if ($chargepointStatus =~ /available/) {
			if ($resetOnDisconnect == 1) {
				INFO "Resetting counters";
				$mqtt->publish($chargeMode_topic, 'sunOnly');
				$mqtt->publish($preferredCurrent_topic, 16);
				$mqtt->publish($preferredNrPhases_topic, 3);
			}
		}
		elsif ($chargepointStatus =~ /charging/) {
			$timer_startedCharging = time();
		}
	} elsif ($topic =~ /chargemode/) {
		$chargeMode = $data;
		INFO "Chargepoint modus: $data";
	} elsif ($topic =~ /voltage/) {
		return if ($data == 0); # Do not process empty values
		$voltage = ($data / 1000);
		#INFO "Current voltage: $voltage"
	} else {
		WARN "Invalid message received from topic " . $topic;
		return;
	}
	
	DEBUG "Energy balance is now " . $sunPowerAvailable . "kW";
}

# Function to update EV details
sub update_details {
	my $details = {
		'current'   => $current,
		'nr_of_phases' => $nr_of_phases,
		'previous_current' => $previous_current,
		'sunPowerAvailable' => $sunPowerAvailable,
		'chargingPower' => $chargingPower,
		'gridUsage' => $gridUsage,
		'realistic_current' => $realistic_current,
		'phases_counter' => $phases_counter,
		'phases_lastChecked' => $phases_lastChecked,
		'curren_lastSet' => $curren_lastSet
	};
	
	# Create the json struct
	my $jsonDetails = encode_json($details);
	$mqtt->publish($details_topic, $jsonDetails);
}

sub update_loadcurrent {
	
	my $current = shift();
	
	#my $original_float = $current;
    my $network_long = unpack 'L', pack 'f', $current;


    #my $pack_float = pack 'f', $original_float;
    #my $unpack_long = unpack 'L', $pack_float;


    #print $network_long . "\n";


	my $parameters = {
		'value_msb' => $network_long / 2**16,
		'value_lsb' => $network_long % 2**16,
		'current'   => $current
	};

    #my $value_lsb = $network_long % 2**16;
    #my $value_msb = $network_long / 2**16;
    
	#my $client = Device::Modbus::TCP::Client->new( host => '192.168.3.144');
	#my $client = Device::Modbus::TCP::Client->new( host => '192.168.1.142');
	#my $req1 = $client->write_multiple_registers(
	#	unit => 1, address => 1210,
	#	values => [$val2, $val1]);
	#my $req2 = $client->write_multiple_registers(
	#	unit => 2, address => 1210,
    #	values => [$val2, $val1]);
	#
	#$client->send_request($req1) || die "Send error: $!";
	#$client->send_request($req2) || die "Send error: $!";
	#sleep(5);
	#$client->disconnect();
	
	# Create the json struct
	my $json = encode_json($parameters);
	$mqtt->publish($set_topic, $json);
	
}

sub midnight_seconds {
   my @time = localtime();
   my $secs = ($time[2] * 3600) + ($time[1] * 60) + $time[0];

   return $secs;
}

sub set_nrOfPhases {
	my ( $arg1 ) = @_;
	if ($arg1 != $nr_of_phases) {
		INFO "Switching to $arg1 phase charging";
		$nr_of_phases = $arg1;
		$mqtt->publish($nr_phases_topic, $nr_of_phases);
		$phases_counter = 0;
		$phases_lastSwitched = time();
	}
}

sub get_maximumCurrent {
	my ( $pref_current, $charging_current ) = @_;
	my $newChargingCurrent = 0;
	my $highestCurrent = 0;
	
	# Determine the highest phase usage
	if ($nr_of_phases == 1) {
		$highestCurrent = $l1power;
	} else {
		if ($l1power >= $l2power && $l1power >= $l3power) {
			$highestCurrent = $l1power;
		} elsif ($l2power >= $l1power && $l2power >= $l3power) {
			$highestCurrent = $l2power;
		} elsif ($l3power >= $l1power && $l3power >= $l2power) {
			$highestCurrent = $l3power;
		}
	}
	
	# Calculate the highest current based on power
	$highestCurrent = ($highestCurrent / $voltage);
	# Calculate the maximum charging current based on current usage and chargingpower
	$newChargingCurrent = int($charging_current + ($mainfuse - $safetyMarge) - $highestCurrent);
		
	# Limit the charging current if it is higher than the maxcurrent	
	$newChargingCurrent = $maxcurrent if ($newChargingCurrent > $maxcurrent);
	# Limit the charging current if it is higher than the preferred current
	$newChargingCurrent = $pref_current if ($newChargingCurrent > $pref_current);
	# Limit the charging current if it is lower than the minimum current (6A)
	$newChargingCurrent = 0 if ($newChargingCurrent < 6);
	
	#INFO "Highest load: $highestCurrent A, current chargingcurrent: $charging_current A";
	#INFO "New charging current: $newChargingCurrent based on current load: L1: $l1power L2: $l2power L3: $l3power";
	return $newChargingCurrent;
}

=head1 NAME

ev-dynacharge.pl - Dynamically charge an electric vehicle based on the energy budget of the house

=head1 SYNOPSIS

    ./ev-dynacharge.pl [--host <MQTT server hostname...> ]
    
=head1 DESCRIPTION

This script allows to dynamically steer the charging process of an electric vehicle. It fetches energy 
consumption values over MQTT and based on the balance and the selected operating mode it will set the 
charge current of the chargepoint where the vehicle is connected to.

This is very much a work in progress, additional documentation and howto information will be added
after the intial field testing is done.

=head1 Using docker to run this script in a container

This repository contains all required files to build a minimal Alpine linux container that runs the script.
The advantage of using this method of running the script is that you don't need to setup the required Perl
environment to run the script, you just bring up the container.

To do this check out this repository, configure the MQTT broker host, username and password in the C<.env> file and run:

C<docker compose up -d>.

=head1 Updating the README.md file

The README.md file in this repo is generated from the POD content in the script. To update it, run

C<pod2github bin/ev-dynacharge.pl E<gt> README.md>

=head1 AUTHOR

Lieven Hollevoet C<hollie@cpan.org>

=head1 LICENSE

CC BY-NC-SA

=cut