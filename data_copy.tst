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

# List of block size to test (max 8)
bs_list=( 64 512 4096 16384 65536 131072 262144 1048576 )

# Check for required interfaces and tools
hdd_count=0; eth_count=0; sd_count=0; usb_count=1;
CheckInterfaceExist $hdd_count $eth_count $sd_count $usb_count
if [ $? -ne 0 ]; then
	echo "Test Failed - no USB device detected"
	exit 1
fi

tools="dd dt fdisk mount umount cat echo rm cp mkdir cmp find xargs grep readlink md5sum"
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

# Prepare 64B test file
rm -f ${TEMP_DIR}/usbtestfile* &> /dev/null
dt of=${TEMP_DIR}/usbtestfile_0 limit=8q dispose=keep pattern=0xc6dec6de &> /dev/null
if [ $? -ne 0 ]; then
	echo "Test Failed - cannot create test file"
	exit 1
fi


### Run test for each USB device ###
for device in  ${dev_list[*]}; do
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
	echo "Copy files on USB device..."
	time_start=`date +%s`
	time_diff=0
	ret=0
	sumsize=0
	fsize=64
	fsrc="${TEMP_DIR}/usbtestfile"
	while : ; do
		for cnt in `seq 0 7`; do
			dbs=$(( $cnt % ${#bs_list[*]} ))
			bsize=${bs_list[$dbs]}
			fdst="${MOUNT_POINT}/testfile_${fsize}"

			echo "Copy ${fsize}B file with ${bsize} block size..."

			rm -f ${TEMP_DIR}/usb_dd.log &> /dev/null
			if [ $cnt -eq 0 ]; then
				cat ${fsrc}_* | dd of=${fdst}_${cnt} bs=${bsize} conv=fsync &> ${TEMP_DIR}/usb_dd.log
				ret=$?
				fsrc=${fdst}
			else
				dd if=${fsrc}_0 of=${fdst}_${cnt} bs=${bsize} conv=fsync &> ${TEMP_DIR}/usb_dd.log
				ret=$?
			fi
			if [ $ret -ne 0 ]; then
				cat ${TEMP_DIR}/usb_dd.log | grep -i "No space left"
				if [ $? -eq 0 ] && [ $sumsize -gt 500000000 ]; then
					echo "No more space left on the device"
					rm -f ${fdst}_${cnt}
					break
				fi

				echo "Test Failed - cannot copy files to the $device device"
				umount -f /dev/${device}1
				exit 1
			fi
			sumsize=$(($sumsize + $fsize))

			time_curr=`date +%s`
			time_diff=$(($time_curr - $time_start))

			if [ $time_diff -gt 180 ]; then
				ret=1
				break
			fi
		done

		if [ $ret -ne 0 ]; then
			break
		fi

		fsize=$(($fsize * 8))
	done

	echo "Summary size of copied files: $sumsize (time: $time_diff s)"

	echo "Re-mount SD card..."
	umount -f /dev/${device}1
	if [ $? -ne 0 ]; then
		echo "Test Failed - cannot unmount filesystem"
		exit 1
	fi
	mount | grep ${device}
	if [ $? -eq 0 ]; then
		echo "Test Failed - failed to unmount ${device} device"
		exit 1
	fi
	
	sleep 10
	mount -t $fs /dev/${device}1 ${MOUNT_POINT}
	if [ $? -ne 0 ]; then
		echo "Test Failed - cannot mount $fs filesystem"
		umount -f /dev/${device}1
		exit 1
	fi

	echo "Verify files..."
	file_list=`find ${MOUNT_POINT} -name 'testfile_*'`
	for file in ${file_list[*]}; do
		dt if=${file} pattern=0xc6dec6de | grep 'errors detected: 0' > /dev/null
		if [ $? -ne 0 ]; then
			echo "Test Failed - File $file is corrupted"
			umount -f /dev/${device}1
			exit 1
		fi
		echo "File $file is correct"
	done

	rm -f ${MOUNT_POINT}/testfile_*

	# Unmount the USB device
	umount -f /dev/${device}1
	if [ $? -ne 0 ]; then
		echo "Test Failed - cannot unmount filesystem"
		exit 1
	fi
done

echo "Test Passed"
exit 0
