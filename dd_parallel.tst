#!/bin/bash

#define timeout 900
#define author Michal Mazur
#define email arg@semihalf.com

. ./tests/test_utils.sh

# Mount point
TEMP_DIR="/tmp"
MOUNT_POINT="$TEMP_DIR/usbdisk"

# List of filesystems to test
fs_list=( "raw ext4" )

# List of required tools
tools="dt fdisk mount umount cat echo rm cp mkdir cmp find xargs grep readlink md5sum"

# Required interfaces
hdd_count=0; eth_count=0; sd_count=0; usb_count=1;

# Test parameters for DT
dt_write_params="runtime=120s pattern=0xc6dec6de disable=verify"
dt_read_params="pattern=0xc6dec6de"


usb_prepare_fs() {
	echo "Prepare $fs filesystem on $device device"

	# Check mount point
	mount | grep "${MOUNT_POINT}/${device}"
	if [ $? -eq 0 ]; then
		echo "Test Failed - ${MOUNT_POINT}/${device} already used to mount"
		return 1
	fi

	mkdir -p ${MOUNT_POINT}/${device}
	if [ $? -ne 0 ]; then
		echo "Test Failed - ${MOUNT_POINT}/${device} cannot be created"
		return 1
	fi

	# Check if device is not mounted
	mount | grep ${device}
	if [ $? -eq 0 ]; then
		echo "Test Failed - /dev/${device} already mounted"
		return 1
	fi

	# Create a single partition on the entire USB device
	echo "Create new partition table on USB device..."
	echo -e "c\no\nn\np\n1\n\n\nt\n83\nw\n" | fdisk -u /dev/${device} > /dev/null
	if [ $? -ne 0 ]; then
		echo "Test Failed - fdisk exited $?"
		return 1
	fi

	echo "Prepare and mount $fs filesystem..."
	if [ "$fs" == "xfs" ]; then
		MKFS="mkfs.xfs -f"
	else
		MKFS="mkfs -t $fs"
	fi
	${MKFS} /dev/${device}1 > /dev/null
	if [ $? -ne 0 ]; then
		echo "Test Failed - cannot create $fs filesystem"
		return 1
	fi

	return 0
}

usb_umount_all() {
	local err=0
	local device

	for devu in $devid_list; do
		device=${dev_list[$devu]}
		umount -f /dev/${device}1

		if [ $? -ne 0 ]; then
			echo "Test Failed - cannot unmount $device device"
			err=1
		fi

		mount | grep ${device}

		if [ $? -eq 0 ]; then
			echo "Test Failed - failed to unmount $device device"
			err=1
		fi
	done
	
	if [ $err -ne 0 ]; then
		return 1
	fi

	return 0
}

usb_mount_all() {
	local err=0
	local ret
	local device

	for devm in $devid_list; do
		device=${dev_list[$devm]}
		mount -t ${fs} /dev/${device}1 ${MOUNT_POINT}/${device}

		if [ $? -ne 0 ]; then
			echo "Test Failed - cannot mount $device device"

			# Unmount all devices
			ret=`usb_umount_all`
			echo "$ret"
			
			return 1
		fi
	done

	return 0
}

usb_run_test() {
	local testcase=$1
	local err=0
	local devid
	local dt_params

	echo "Run parallel $testcase test..."
	err=0
	rm -f ${TEMP_DIR}/dd_parallel_* > /dev/null

	for devid in $devid_list; do
		if [ $testcase == "write" ]; then
			echo "Write data to ${dev_list[$devid]} device (${testfile[$devid]})..."

			dt_params="dispose=keep enable=fsync ${dt_write_params}"
			dt of=${testfile[$devid]} ${dt_params} &> ${TEMP_DIR}/dd_parallel_${devid}.bgd &
		else
			echo "Read data from ${dev_list[$devid]} device (${testfile[$devid]})..."

			dt_params="limit=${size_list[$devid]} ${dt_read_params}"
			dt if=${testfile[$devid]} ${dt_params} &> ${TEMP_DIR}/dd_parallel_${devid}.bgd &
		fi
		pid_list[$devid]=$!
	done

	# Wait until all threads finish
	for devid in $devid_list; do
		wait ${pid_list[$devid]}

		grep 'errors detected: 0' ${TEMP_DIR}/dd_parallel_${devid}.bgd > /dev/null
		if [ $? -ne 0 ]; then
			err=$(( 1 + $devid ))
		fi

		if [ $testcase == "write" ]; then
			ret=`grep 'Total bytes transferred' ${TEMP_DIR}/dd_parallel_${devid}.bgd`
			if [ $? -ne 0 ]; then
				err=$(( 1 + $devid ))
			fi

			size_list[$devid]=`echo "${ret}" | awk '{ print $4 }'`
			if [ $? -ne 0 ] || [ ! ${size_list[$devid]} -gt 0 ]; then
				err=$(( 1 + $devid ))
			fi
		fi
	done

	# Collect logs
	cat ${TEMP_DIR}/dd_parallel_* >> tests/usb/dd_parallel.bgd

	if [ $err -ne 0 ]; then
		devid=$(( $err - 1 ))
		device=${dev_list[$devid]}

		echo "Test Failed - error during $testcase ($device device)"

		if [ "$fs" != "raw" ]; then
			for devid in $devid_list; do
				device=${dev_list[$devid]}
				umount -f /dev/${device}1
			done
		fi

		return 1
	fi

	return 0
}

# Check for required interfaces and tools
for fs in ${fs_list[*]}; do
	if [ "$fs" != "raw" ]; then
		tools+=" mkfs.$fs"
	fi
done
CheckToolExist $tools
if [ $? -ne 0 ]; then
	echo "Test Failed - required tools are not available"
	exit 1
fi

CheckInterfaceExist $hdd_count $eth_count $sd_count $usb_count
if [ $? -ne 0 ]; then
	echo "Test Failed - no USB device detected"
	exit 1
fi

# Generate list of available USB devices
path_list=`find /dev/disk/by-path/ -iname '*usb*' -not -iname '*part*' 2> /dev/null`
dev_list=()
for path in ${path_list[*]}; do
	device=`readlink "$path" | xargs basename`
	ls /dev/${device} &> /dev/null
	if [ $? -eq 0 ]; then
		dev_list+=($device)
	fi
done
if [ ${#dev_list[*]} -eq 0 ]; then
	echo "Test Failed - no USB device found"
	exit 1
fi
devid_list=`seq 0 $(( ${#dev_list[*]} - 1 ))`
echo "Detected USB devices: ${dev_list[*]}"

# Run test on a randomly selected filesystem or raw
fsp=$(( $RANDOM % ${#fs_list[*]} ))
for fs in ${fs_list[$fsp]}; do
	if [ "$fs" == "raw" ]; then
		echo "Run test on raw device"
	else
		echo "Run test on $fs filesystem"
	fi

	# Prepare all USB devices
	for devid in $devid_list; do
		device=${dev_list[$devid]}
		if [ "$fs" == "raw" ]; then
			testfile[$devid]="/dev/${device}"
		else
			testfile[$devid]="${MOUNT_POINT}/${device}/testfile"

			sbret=`usb_prepare_fs`
			echo "$sbret"
			if [ $? -ne 0 ]; then
				exit 1
			fi
		fi
	done

	# Mount all USB devices
	if [ "$fs" != "raw" ]; then
		sbret=`usb_mount_all`
		echo "$sbret"
		if [ $? -ne 0 ]; then
			exit 1
		fi
	fi

	# Start the parallel test
	rm -f tests/usb/dd_parallel.bgd > /dev/null
	sbret=`usb_run_test write`
	echo "$sbret"
	if [ $? -ne 0 ]; then
		exit 1
	fi

	# Re-mount devices
	if [ "$fs" != "raw" ]; then
		sbret=`usb_umount_all`
		echo "$sbret"
		if [ $? -ne 0 ]; then
			exit 1
		fi

		sleep 20

		sbret=`usb_mount_all`
		echo "$sbret"
		if [ $? -ne 0 ]; then
			exit 1
		fi
	fi

	# Parallel read
	sbret=`usb_run_test read`
	echo "$sbret"
	if [ $? -ne 0 ]; then
		exit 1
	fi

	echo "Test finished ($fs) - no errors found"

	# Unmount devices
	if [ "$fs" != "raw" ]; then
		sbret=`usb_umount_all`
		echo "$sbret"
		if [ $? -ne 0 ]; then
			exit 1
		fi
	fi
done

echo "Test Passed"
exit 0
