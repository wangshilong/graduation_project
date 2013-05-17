#!/bin/bash

# Build test env:
# 1: Get 4 block device for test
# 2: git clone btrfs-progs and linux-btrfs tree, then set them to PROGS_DIR and KERNEL_DIR
# 3: Make and install linux-btrfs kernel, and set it to default boot option in grub.conf
#    cd "$BTRFS_KERNEL_DIR"
#    make clean
#    make mrproper
#    cp /boot/config-* .config
#    make oldnoconfig
#    make
#    make modules_install install
#    vi /boot/grub/grub.conf
#       set default boot item to new kernel
# 4: cron to run this script 2 time every day
#    one for sync,compile apply kernel and reboot
#    another for test function

DEV[0]=/dev/vdd
DEV[1]=/dev/vde
DEV[2]=/dev/vdf
DEV[3]=/dev/vdg

PROGS_DIR=/data/git/btrfs-progs
KERNEL_DIR=/data/git/linux-btrfs

TMP_FILE=$(mktemp)
if [ -z "$TMP_FILE" ]
then
	echo "Create temp file failed"
	exit 1
fi

LOG_BASEDIR=/var/log/btrfst

# -C: Check is exist "$LOG_BASEDIR"/do_btrfs_test
#     Delete this file and continue if this file exist
# -T: Test btrfs's function
# -S: Sync, compile, apply kernel
# -R: Restart
#
# To do a simple test:  -T or -S
# To apply and restart: -SR
# Continue test after reboot: -CT

if [ "$1" = "-T" ]
then
	FUNCTION="T"
fi
if [ "$1" = "-C" ]
then
	FUNCTION="C"
fi
if [ -z "$FUNCTION" ]
then
	if [ -f "$LOG_BASEDIR"/do_btrfs_test ]
	then
		FUNCTION="T"
		rm -rf "$LOG_BASEDIR"/do_btrfs_test
		LOG_DIR=$(cat "$LOG_BASEDIR"/do_btrfs_test)
	else
		FUNCTION="C"
	fi
fi

if [ ! -d "LOG_DIR" ]
then
	LOG_DIR="$LOG_BASEDIR/"$(date +%Y%m%d_%H%M%S)
fi

LOG_FILE="$LOG_DIR"/btrfst.log
mkdir -p "$LOG_DIR"

# Ex:
# Print normal information:
#   showinfo "Hello world"      -- as echo "Hello world", plus output them into log file
#   showinfo -n "Hello world"   -- as echo -n "Hello world", plus output them into log file
#
# Print result:
#   showinfo OK                 -- print [OK] in OK color, plus output them into log file
#   showinfo NG                 -- print [NG] in NG color, plus output them into log file
#   showinfo INFO               -- print [INFO] in INFO color, plus output them into log file
#   showinfo NG "init fail"     -- print [init fail] in NG color, plus output them into log file
#   showinfo -n NG "something"  -- print [something] in NG color with "-n" argument, plus output them into log file
showinfo()
{
	local OPTION=""
	local COLOR_CTL
	local OUTPUT
	local RESULT_FLAG

	OPTIND=1
	while getopts 'ne' opt
	do
		if [ "$opt" != "?" ]
		then
			OPTION="$OPTION -$opt"
		fi
	done
	shift $(($OPTIND - 1))

	case "$1" in
	"OK")
		RESULT_FLAG=1
		OUTPUT="$1"
		shift 1
		COLOR_CTL="\033[32m"
		;;
	"NG")
		RESULT_FLAG=1
		OUTPUT="$1"
		shift 1
		COLOR_CTL="\033[31m"
		;;
	"INFO")
		RESULT_FLAG=1
		OUTPUT="$1"
		shift 1
		COLOR_CTL="\033[35m"
		;;
	*)
		RESULT_FLAG=0
		COLOR_CTL="\033[0m"
		;;
	esac

	if [ -n "$*" ]
	then
		OUTPUT="$*"
	fi

	if ((RESULT_FLAG))
	then
		OUTPUT="[$OUTPUT]"
	fi

	echo -e $OPTION "$COLOR_CTL""$OUTPUT""\033[0m" | tee -a "$LOG_FILE"

	return 0
}

do_error()
{
	# Send mail here
	exit 1
}

_get_source_dir()
{
	local TARGET="$1"
	
	case "$TARGET" in
	kernel)
		echo "$KERNEL_DIR"
		;;
	progs)
		echo "$PROGS_DIR"
		;;
	*)
		return 1
		;;
	esac
	
	return 0
}

do_sync()
{
	local TARGET="$1"
	showinfo -n "Sync $TARGET: "
	local TARGET_DIR=$(_get_source_dir "$TARGET") || if true; then showinfo NG "UNKNOWN_ARGS";return 1;fi

	git --git-dir="$TARGET_DIR"/.git pull >>"$LOG_DIR"/git_pull.log 2>&1 || if true; then showinfo NG;return 1;fi

	showinfo OK
	return 0
}

do_compile()
{
	local TARGET="$1"
	showinfo -n "Compiling $TARGET: "
	local TARGET_DIR=$(_get_source_dir "$TARGET") || if true; then showinfo NG "UNKNOWN_ARGS";return 1;fi
	local ret

	if [ "$TARGET" = "kernel" ]
	then
		# We don't care about warnings in these 2 step, because it's not btrfs code
		make -C "$TARGET_DIR" oldnoconfig  >>"$LOG_DIR"/compile.log 2>&1 || if true; then showinfo NG "COMPILE_OLDCONFIG_FAILED";return 1;fi
		make -C "$TARGET_DIR"              >>"$LOG_DIR"/compile.log 2>&1 || if true; then showinfo NG "COMPILE_KERNELSRC_FAILED";return 1;fi

		make -C "$TARGET_DIR" -m fs/btrfs/ >>"$LOG_DIR"/compile.log 2>"$TMP_FILE"
	else
		make -C "$TARGET_DIR"              >>"$LOG_DIR"/compile.log   2>"$TMP_FILE"
	fi
	ret="$?"

	cat "$TMP_FILE" >> "$LOG_DIR"/compile.log
	if [ "$ret" != "0" ]
	then
		showinfo NG "COMPILE_BTRFS_FAILED"
		return 1
	fi
	if [ -s "$TMP_FILE" ]
	then
		showinfo "There warning or error in compile:"
		cat "$TMP_FILE"
		showinfo NG
		return 1
	fi

	showinfo OK
	return 0
}

apply_kernel()
{
	showinfo -n "Applying kernel: "

	make -C "$KERNEL_DIR" modules_install install > "$LOG_DIR"/compile_kernel.log 2>&1 || if true; then showinfo NG "INITFS_FAILED";return 1;fi

	showinfo OK
	return 0
}

update_all()
{
	showinfo "Starting update on "$(date +%Y-%m-%d_%H:%M:%S)

	do_sync    progs  || do_error
	do_sync    kernel || do_error
	do_compile progs  || do_error
	do_compile kernel || do_error
	apply_kernel      || do_error

	touch /var/local/do_btrfs_test
}

initdev()
{
	local maxsize=0
	local maxsizedev=""
	local devsize
	local devfile

	showinfo -n "Initing block dev: "

	for devfile in "${DEV[@]}"
	do
		devsize=$(blockdev --getsz "${devfile}")
		if ((devsize > maxsize))
		then
			maxsize="$devsize"
			maxsizedev="$devfile"
		fi
	done
	if [ \( "$maxsize" = 0 \) -o \( -z "$maxsizedev" \) ]
	then
		showinfo NG "FIND_MAX_SIZE_DEV_FAILED"
		return 1
	fi

	showinfo -n "$maxsizedev "
	dd if=/dev/urandom of="$maxsizedev" bs=1M 2>/dev/null

	for devfile in "${DEV[@]}"
	do
		if [ "$devfile" = "$maxsizedev" ]
		then
			continue
		fi
		showinfo -n "$devfile "
		dd if="$maxsizedev" of="$devfile" bs=1M 2>/dev/null
	done

	showinfo OK
	return 0
}

initfs()
{
	local fs_dev="$1"
	if [ -b "$fs_dev" ]
	then
		"$PROGS_DIR"/mkfs.btrfs "$fs_dev" >>"$LOG_DIR"/initfs.log 2>&1 || if true; then showinfo NG "INITFS_FAILED";return 1;fi
	fi
	return 0
}

chkfs()
{
	local fs_dev="$1"
	if [ -b "$fs_dev" ]
	then
		"$PROGS_DIR"/btrfsck "$fs_dev" >>"$LOG_DIR"/chkfs.log 2>&1 || if true; then showinfo NG "INITFS_FAILED";return 1;fi
	fi
	mount "$fs_dev" /media
	umount /media
	return 0
}

if false
then
	update_all
	exit 0
fi

# initdev || exit 1
initfs ${DEV[0]} || exit 1
chkfs ${DEV[0]} 2>/dev/null || exit 1
