#!/bin/bash

#define timeout 900
#define author Michal Mazur
#define email arg@semihalf.com

. ./tests/test_utils.sh

# Mount point
TEMP_DIR="/tmp"
MOUNT_POINT="$TEMP_DIR/usbdisk"

# List of filesystems to test
fs_list=( vfat )

# List of block size to test
bs_list=( 512 4096 32768 131072 524288 )


# Check for required interfaces and tools
hdd_count=0; eth_count=0; sd_count=0; usb_count=1;
CheckInterfaceExist $hdd_count $eth_count $sd_count $usb_count
if [ $? -ne 0 ]; then
	echo "Test Failed - no USB device detected"
	exit 1
fi

tools="dt fdisk mount umount cat echo mkdir cmp find xargs grep readlink"
for fs in ${fs_list[*]}; do
	tools+=" mkfs.$fs"
done
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

# Check mount point
mount | grep ${MOUNT_POINT}
if [ $? -eq 0 ]; then
	echo "Test Failed - ${MOUNT_POINT} already used to mount"
	exit 1
fi

mkdir -p ${MOUNT_POINT}
if [ $? -ne 0 ]; then
	echo "Test Failed - ${MOUNT_POINT} cannot be created"
	exit 1
fi

### Run test for each USB device ###
for device in  ${dev_list[*]}; do
	echo "Run test on device $device"

	# Check if device is not mounted
	mount | grep ${device}
	if [ $? -eq 0 ]; then
		echo "Test Failed - /dev/${device} already mounted"
		exit 1
	fi

	# Create a single partition on the entire USB device
	echo "Create new partition table on USB device..."
	echo -e "c\no\nn\np\n1\n\n\nt\n83\nw\n" | fdisk -u /dev/${device}
	if [ $? -ne 0 ]; then
		echo "Test Failed - fdisk exited $?"
		exit 1
	fi

	# Run test on a randomly selected filesystem
	fsp=$(( $RANDOM % ${#fs_list[*]} ))
	fs=${fs_list[$fsp]}

	echo "Prepare and mount $fs filesystem..."
	if [ "$fs" == "xfs" ]; then
		MKFS="mkfs.xfs -f"
	else
		MKFS="mkfs -t $fs"
	fi
	${MKFS} /dev/${device}1
	if [ $? -ne 0 ]; then
		echo "Test Failed - cannot create $fs filesystem"
		exit 1
	fi
	mount -t ${fs} /dev/${device}1 ${MOUNT_POINT}
	if [ $? -ne 0 ]; then
		echo "Test Failed - cannot mount $fs filesystem"
		exit 1
	fi

	### Test the device ###
	for bsize in ${bs_list[*]}; do
		echo "Run the dt test with block size set to ${bsize}B..."

		dt of=${MOUNT_POINT}/testfile bs=${bsize} passes=2 limit=512m enable=fsync
		if [ $? -ne 0 ]; then
			echo "Test Failed - Data Test exited error $?"
			umount -f /dev/${device}1
			exit 1
		fi
	done

	# Unmount the USB device
	umount -f /dev/${device}1
	if [ $? -ne 0 ]; then
		echo "Test Failed - cannot unmount filesystem"
		exit 1
	fi
done

echo "Test Passed"
exit 0
