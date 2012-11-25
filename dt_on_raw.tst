#!/bin/bash

#define timeout 900
#define author Michal Mazur
#define email arg@semihalf.com

. ./tests/test_utils.sh

# List of block size to test
bs_list=( 512 8192 131072 524288 )


# Check for required interfaces and tools
hdd_count=0; eth_count=0; sd_count=0; usb_count=1;
CheckInterfaceExist $hdd_count $eth_count $sd_count $usb_count
if [ $? -ne 0 ]; then
	echo "Test Failed - no USB device detected"
	exit 1
fi

tools="dt cat echo find xargs grep readlink"
CheckToolExist $tools
if [ $? -ne 0 ]; then
	echo "Test Failed - required tools are not available"
	exit 1
fi

# Generate list of available USB devices
path_list=`find /dev/disk/by-path/ -iname '*usb*' -not -iname '*part*' 2> /dev/null`
dev_list=""
for path in ${path_list[*]}; do
	device=`readlink "$path" | xargs basename`
	ls /dev/${device}
	if [ $? -eq 0 ]; then
		dev_list+="$device "
	fi
done
if [ "$dev_list" == "" ]; then
	echo "Test Failed - no USB device found"
	exit 1
fi
echo "Detected USB devices: ${dev_list}"

### Run test for each USB device ###
for device in  ${dev_list[*]}; do
	echo "Run dt test on ${device} device..."

	# Check if device is not mounted
	mount | grep ${device}
	if [ $? -eq 0 ]; then
		echo "Test Failed - /dev/${device} is mounted"
		exit 1
	fi

	### Test the device ###
	for bsize in ${bs_list[*]}; do
		echo "Run the dt test with block size set to ${bsize}B..."

		dt of=/dev/${device} bs=${bsize} passes=2 limit=400m enable=fsync
		if [ $? -ne 0 ]; then
			echo "Test Failed - Data Test exited error $?"
			exit 1
		fi
	done
done

echo "Test Passed"
exit 0
