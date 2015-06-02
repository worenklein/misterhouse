# $Date$
# $Revision$

use strict;

package Serial_Item;

use X10_Interface;

our $mainHash=\%::Serial_Ports;

@Serial_Item::ISA = ('X10_Interface');
our @supported_interfaces=qw!cm11 BX24 Homevision HomeBase Stargate HouseLinc
	Marrick cm17 2412n Lynx10PLC weeder wish ti103 ncpuxa!;

sub new {
	my ($class, $id, $state, $device_name) = @_;
	my $self = X10_Interface->new($id, $state, $device_name);
	bless ($self, $class);
	$self->{mainHash}=$mainHash;
	$self->set_standard_config;
	$self->set_interface($device_name) if $id and $id =~ /^X/;
	$self->state_overload('off'); # By default, do not process ~;: strings as substate/multistate

	return $self;
}

sub do_start {
	my ($self) = @_;

	return &::serial_port_open($self->{device_name});
}

sub stop {
    my ($self) = @_;
    my $port_name = $self->{port_name};
    my $sp_object = $main::Serial_Ports{$port_name}{object};
    if ($sp_object) {

        my $port = $main::Serial_Ports{$port_name}{port};
#       &Win32::SerialPort::debug(1);
        if ($sp_object->close) {
            print "Port $port_name on port $port was closed\n";
        }
        else {
            print "Serial_Item stop failed for port $port_name\n";
        }
                                # Delete the ports, even if it didn't close, so we can do
                                # starts again without a 'port reuse' message.
        delete $main::Serial_Ports{$port_name}{object};
        delete $main::Serial_Ports{object_by_port}{$port};
#       &Win32::SerialPort::debug(0);
    }
    else {
        print "Error in Serial_Item stop for port $port_name: Port is not started\n";
    }
}

sub set_dtr {
    my ($self, $state) = @_;
    my $port_name = $self->{port_name};
    if (my $serial_port = $main::Serial_Ports{$port_name}{object}) {
        $main::Serial_Ports{$port_name}{object}->dtr_active($state);
        print "Serial_port $port_name dtr set to $state\n" if $main::Debug{serial};
    }
    else {
        print "Error, serial port set_dtr for $port_name failed, port has not been set\n";
    }
}
sub set_rts {
    my ($self, $state) = @_;
    my $port_name = $self->{port_name};
    if (my $serial_port = $main::Serial_Ports{$port_name}{object}) {
        $main::Serial_Ports{$port_name}{object}->rts_active($state);
        print "Serial_port $port_name rts set to $state\n" if $main::Debug{serial};
    }
    else {
        print "Error, serial port set_rts for $port_name failed, port has not been set\n";
    }
}

sub write_data {
	my ($self, $serial_data) = @_;

	&send_serial_data($self->{device_name}, $serial_data);
}

sub send_serial_data {
	my ($port_name, $serial_data)=@_;

    return if &main::proxy_send($port_name, 'send_serial_data', $serial_data);

                                # The ncpuxa code works on a socket, not a serial port
                                # but may be called as a Serial_Item
    unless ($main::Serial_Ports{$port_name}{object} or lc $port_name eq 'ncpuxa') {
        print "Error, serial port for $port_name has not been set: data=$serial_data\n";
        return;
    }

    if (lc $port_name eq 'homevision') {
        print "Using homevision to send: $serial_data\n";
        &Homevision::send($main::Serial_Ports{Homevision}{object}, $serial_data);
    }
    elsif (lc $port_name eq 'ncpuxa') {
        &main::print_log("Using ncpuxa to send: $serial_data");
        &ncpuxa_mh::send($main::config_parms{ncpuxa_port}, $serial_data);
    }
    else {
		my $datatype  = $main::Serial_Ports{$port_name}{datatype};
		my $prefix    = $main::Serial_Ports{$port_name}{prefix};

		$serial_data = $prefix . $serial_data if $prefix and $prefix ne '';
		$serial_data .= "\r" unless $datatype and $datatype eq 'raw';

        my $results = $main::Serial_Ports{$port_name}{object}->write($serial_data);

#      &main::print_log("serial port=$port_name out=$serial_data results=$results") if $main::Debug{serial};
        print "serial  port=$port_name out=$serial_data results=$results\n" if $main::Debug{serial};
    }
}

my $x10_save_unit;

sub send_x10_data {
	# This function can either be called as a class method or a library function
	# If being called as a member function, then pull the object ref off the
	# argument list.
	my $self=undef;
	if (ref($_[0])) {
		$self=shift @_;
	}
    my ($interface, $serial_data, $module_type) = @_;
    my ($isfunc);

                                # Use proxy mh if present (avoids mh pauses for slow X10 xmits)
    return if &main::proxy_send($interface, 'send_x10_data', $serial_data, $module_type);
# This function can either be called as a class method or a library function

    if ($serial_data =~ /^X[A-P][1-9A-G]$/) {
        $isfunc = 0;
        $x10_save_unit = $serial_data;
    }
    else {
        $isfunc = 1;
    }
    print "X10: interface=$interface isfunc=$isfunc save_unit=$x10_save_unit data=$serial_data\n" if $main::Debug{x10};

    if ($interface eq 'cm11') {
                                # CM11 wants individual codes without X
        print "db1 CM11: Sending x10 data: $serial_data\n" if $main::Debug{cm11};

				# Standard 1-cm11 code
	if (!$main::config_parms{cm11_bak_port}) {
	    &ControlX10::CM11::send($main::Serial_Ports{cm11}{object},
				    substr($serial_data, 1));
	}
				# Dual cm11 code
	else {
				# if both units are active then
                                #   use the one with the most time left on the counter as it was the most recently found to be active
				# otherwise use the main one if it's active or the backup if it's active
	    if (($main::cm11_objects{active}->state() eq 'on') && ($main::cm11_objects{bak_active}->state() eq 'on')) {
		if ($main::cm11_objects{timer}->seconds_remaining() >= $main::cm11_objects{bak_timer}->seconds_remaining()) {
		    print "db CM11: using primary cm11\n" if $main::Debug{cm11};
		    &ControlX10::CM11::send($main::Serial_Ports{cm11}{object},substr($serial_data, 1));
		} else {
		    print "db CM11: using backup cm11\n" if $main::Debug{cm11};
		    &ControlX10::CM11::send($main::Serial_Ports{cm11_bak}{object},substr($serial_data, 1));
		}
	    } elsif ($main::cm11_objects{active}->state() eq 'on') {
		print "db CM11: using primary cm11\n" if $main::Debug{cm11};
		&ControlX10::CM11::send($main::Serial_Ports{cm11}{object},substr($serial_data, 1));
	    } elsif ($main::cm11_objects{bak_active}->state() eq 'on') {
		print "db CM11: using backup cm11\n" if $main::Debug{cm11};
		&ControlX10::CM11::send($main::Serial_Ports{cm11_bak}{object},substr($serial_data, 1));
	    } else {
		print "db CM11: Error - no cm11's are working ...\n" if $main::Debug{cm11};
	    }
	}
    }


    elsif ($interface eq 'ti103') {
                                # TI103 wants individual codes without X
        print "db1 TI103: Sending x10 data: $serial_data\n" if $main::Debug{ti103};
        &ControlX10::TI103::send($main::Serial_Ports{ti103}{object}, substr($serial_data, 1));
    }

    elsif ($interface eq 'bx24') {
                                # BX24 wants individual codes without X
        &X10_BX24::SendX10($serial_data);
    }

    elsif ($interface eq 'lynx10plc') {
                                # lynx10plc wants individual codes without X
        &Lynx10PLC::send_plc($main::Serial_Ports{Lynx10PLC}{object},
                             $serial_data, $module_type);
    }
    elsif ($interface eq '2412n') {
	if ( $isfunc ) {
	    use X2412N;
	    X2412N::send($x10_save_unit, $serial_data);
	}
    }
    elsif ($interface eq 'cm17') {
	# cm17 wants A1K, not XA1AK
	my $Command  = substr($x10_save_unit, 1) . substr($serial_data, 2);
	if ($isfunc) {
	    ::print_log("Sending $Command");
	    &ControlX10::CM17::send($main::Serial_Ports{cm17}{object}, $Command);
	}
    }
    elsif ($interface eq 'homevision') {
                                # homevision wants XA1AK
        if ($isfunc) {
            print "Using homevision to send: " .
                $x10_save_unit . substr($serial_data, 1) . "\n";
            &Homevision::send($main::Serial_Ports{Homevision}{object},
                              $x10_save_unit . substr($serial_data, 1));
        }
    }
    elsif ($interface eq 'homebase') {
                                # homebase wants individual codes without X
        print "Using homebase to send: $serial_data\n";
        &HomeBase::send_X10($main::Serial_Ports{HomeBase}{object}, substr($serial_data, 1));
    }
    elsif ($interface eq 'stargate') {
                                # Stargate wants individual codes without X
        print "Using stargate to send: $serial_data\n";
        &Stargate::send_X10($main::Serial_Ports{Stargate}{object}, substr($serial_data, 1));
    }
    elsif ($interface eq 'houselinc') {
                                # houselinc wants XA1AK
        if ($isfunc) {
            print "Using houselinc to send: " .
                $x10_save_unit . substr($serial_data, 1) . "\n";
            &HouseLinc::send_X10($main::Serial_Ports{HouseLinc}{object},
                                 $x10_save_unit . substr($serial_data, 1));
        }
    }
    elsif ($interface eq 'marrick') {
                                # marrick wants XA1AK
        if ($isfunc) {
            print "Using marrick to send: " .
                $x10_save_unit . substr($serial_data, 1) . "\n";
            &Marrick::send_X10($main::Serial_Ports{Marrick}{object},
                               $x10_save_unit . substr($serial_data, 1));
        }
    }
    elsif ($interface eq 'ncpuxa') {
                                # ncpuxa wants individual codes with X
        &main::print_log("Using ncpuxa to send: $serial_data");
        &ncpuxa_mh::send($main::config_parms{ncpuxa_port}, $serial_data);
    }
    elsif ($interface eq 'weeder') {
                                # Weeder wants XA1AK or XA1ALALAL
        my ($device, $house, $command) = $serial_data =~ /^X(\S\S)(\S)(\S+)/;

                                # Allow for +-xx%
        my $dim_amount = 3;
        if ($command =~ /[\+\-]\d+/) {
            $dim_amount = int(10 * abs($command) / 100); # about 10 levels to 100%
            $command = ($command > 0) ? 'L' : 'M';
        }
                                # Weeder table does not match what we defined in CM11,CM17,X10_Items.pm
                                #  - Dim -> L, Bright -> M,  AllOn -> I, AllOff -> H
        if ($command eq 'M') {
            $command =  'L' . (($house . 'L') x $dim_amount);
        }
        elsif ($command eq 'L') {
            $command =  'M' . (($house . 'M') x $dim_amount);
        }
        elsif ($command eq 'O') {
            $command =  'I';
        }
        elsif ($command eq 'P') {
            $command =  'H';
        }
        $serial_data = 'X' . $device . $house . $command;

        $main::Serial_Ports{weeder}{object}->write($serial_data);

				# Give weeder a chance to do the previous command
				# Surely there must be a better way!
        select undef, undef, undef, 1.2;
    }
    elsif ($interface eq 'wish') {
                                # wish wants individual codes without X
        &main::print_log("Using wish to send: $serial_data");
        &X10_Wish::send(substr($serial_data, 1));
    }
    else {
        print "\nError, X10 interface not found: interface=$interface, data=$serial_data\n";
    }

}

sub get_supported_interfaces {
	my ($self)=@_;
	return \@supported_interfaces;
}

sub serial_items_by_id {
	return &Device_Item::items_by_id(@_);
}
sub serial_item_by_id {
	return &Device_Item::item_by_id(@_);
}

1;
