#!/bin/bash
set -e

PROG=$0
PROGS="dd curl mkfs.ext4 mkfs.vfat fatlabel parted partprobe grub2-install"
DISTRO=/run/rootfsbase
ISOMNT=/run/initramfs/live
ISOBOOT=${ISOMNT}/boot
TARGET=/run/cos/target
RECOVERYDIR=/run/cos/recovery
RECOVERYSQUASHFS=${ISOMNT}/recovery.squashfs
ARCH=$(uname -p)

if [ "${ARCH}" == "aarch64" ]; then
  ARCH="arm64"
fi

source /usr/lib/cos/functions.sh

if [ "$COS_DEBUG" = true ]; then
    set -x
fi

umount_target() {
    sync
    umount ${TARGET}/oem
    umount ${TARGET}/usr/local
    umount ${TARGET}/boot/efi || true
    umount ${TARGET}
    if [ -n "$LOOP" ]; then
        losetup -d $LOOP
    fi
}

cleanup2()
{
    sync
    umount_target || true
    umount ${STATEDIR}
    umount ${RECOVERYDIR}
    [ -n "$COS_INSTALL_ISO_URL" ] && umount ${ISOMNT} || true
}

cleanup()
{
    EXIT=$?
    cleanup2 2>/dev/null || true
    return $EXIT
}

usage()
{
    echo "Usage: $PROG [--force-efi] [--force-gpt] [--iso https://.../OS.iso] [--debug] [--tty TTY] [--poweroff] [--no-format] [--config https://.../config.yaml] DEVICE"
    echo ""
    echo "Example: $PROG /dev/vda"
    echo ""
    echo "DEVICE must be the disk that will be partitioned (/dev/vda). If you are using --no-format it should be the device of the COS_STATE partition (/dev/vda2)"
    echo ""
    echo "The parameters names refer to the same names used in the cmdline, refer to README.md for"
    echo "more info."
    echo ""
    exit 1
}

prepare_recovery() {
    echo "Preparing recovery.."
    mkdir -p $RECOVERYDIR
    mount $RECOVERY $RECOVERYDIR
    mkdir -p $RECOVERYDIR/cOS

    if [ -e "$RECOVERYSQUASHFS" ]; then
        echo "Copying squashfs.."
        cp -a $RECOVERYSQUASHFS $RECOVERYDIR/cOS/recovery.squashfs
    else
        echo "Copying image file.."
        cp -a $STATEDIR/cOS/active.img $RECOVERYDIR/cOS/recovery.img
        sync
        tune2fs -L COS_SYSTEM $RECOVERYDIR/cOS/recovery.img
    fi

    sync
}

prepare_passive() {
    echo "Preparing passive boot.."
    cp -a ${STATEDIR}/cOS/active.img ${STATEDIR}/cOS/passive.img
    sync
    tune2fs -L COS_PASSIVE ${STATEDIR}/cOS/passive.img
    sync
}

do_format()
{
    echo "Formatting drives.."

    if [ "$COS_INSTALL_NO_FORMAT" = "true" ]; then
        STATE=$(blkid -L COS_STATE || true)
        if [ -z "$STATE" ] && [ -n "$DEVICE" ]; then
            tune2fs -L COS_STATE $DEVICE
            STATE=$(blkid -L COS_STATE)
        fi
        OEM=$(blkid -L COS_OEM || true)
        STATE=$(blkid -L COS_STATE || true)
        RECOVERY=$(blkid -L COS_RECOVERY || true)
        BOOT=$(blkid -L COS_GRUB || true)
        return 0
    fi

    dd if=/dev/zero of=${DEVICE} bs=1M count=1
    parted -s ${DEVICE} mklabel ${PARTTABLE}

    # TODO: Size should be tweakable
    if [ "$PARTTABLE" = "gpt" ] && [ "$BOOTFLAG" == "esp" ]; then
        BOOT_NUM=1
        OEM_NUM=2
        STATE_NUM=3
        RECOVERY_NUM=4
        PERSISTENT_NUM=5
        parted -s ${DEVICE} mkpart primary fat32 0% 50MB # efi
        parted -s ${DEVICE} mkpart primary ext4 50MB 100MB # oem
        parted -s ${DEVICE} mkpart primary ext4 100MB 15100MB # state
        parted -s ${DEVICE} mkpart primary ext4 15100MB 23100MB # recovery
        parted -s ${DEVICE} mkpart primary ext4 23100MB 100% # persistent
        parted -s ${DEVICE} set 1 ${BOOTFLAG} on
    elif [ "$PARTTABLE" = "gpt" ] && [ "$BOOTFLAG" == "bios_grub" ]; then
        BOOT_NUM=
        OEM_NUM=2
        STATE_NUM=3
        RECOVERY_NUM=4
        PERSISTENT_NUM=5
        parted -s ${DEVICE} mkpart primary 0% 1MB # BIOS boot partition for GRUB
        parted -s ${DEVICE} mkpart primary ext4 1MB 51MB # oem
        parted -s ${DEVICE} mkpart primary ext4 51MB 15051MB # state
        parted -s ${DEVICE} mkpart primary ext4 15051MB 23051MB # recovery
        parted -s ${DEVICE} mkpart primary ext4 23051MB 100% # persistent
        parted -s ${DEVICE} set 1 ${BOOTFLAG} on
    else
        BOOT_NUM=
        OEM_NUM=1
        STATE_NUM=2
        RECOVERY_NUM=3
        PERSISTENT_NUM=4
        parted -s ${DEVICE} mkpart primary ext4 0% 50MB # oem
        parted -s ${DEVICE} mkpart primary ext4 50MB 15050MB # state
        parted -s ${DEVICE} mkpart primary ext4 15050MB 23050MB # recovery
        parted -s ${DEVICE} mkpart primary ext4 23050MB 100% # persistent
        parted -s ${DEVICE} set 2 ${BOOTFLAG} on
    fi

    partprobe ${DEVICE} 2>/dev/null || true
    sleep 2

    dmsetup remove_all 2>/dev/null || true

    PREFIX=${DEVICE}
    if [ ! -e ${PREFIX}${STATE_NUM} ]; then
        PREFIX=${DEVICE}p
    fi

    if [ ! -e ${PREFIX}${STATE_NUM} ]; then
        echo Failed to find ${PREFIX}${STATE_NUM} or ${DEVICE}${STATE_NUM} to format
        exit 1
    fi

    if [ -n "${BOOT_NUM}" ]; then
        BOOT=${PREFIX}${BOOT_NUM}
    fi
    STATE=${PREFIX}${STATE_NUM}
    OEM=${PREFIX}${OEM_NUM}
    RECOVERY=${PREFIX}${RECOVERY_NUM}
    PERSISTENT=${PREFIX}${PERSISTENT_NUM}

    mkfs.ext4 -F -L COS_STATE ${STATE}
    if [ -n "${BOOT}" ]; then
        mkfs.vfat -F 32 ${BOOT}
        fatlabel ${BOOT} COS_GRUB
    fi

    mkfs.ext4 -F -L COS_RECOVERY ${RECOVERY}
    mkfs.ext4 -F -L COS_OEM ${OEM}
    mkfs.ext4 -F -L COS_PERSISTENT ${PERSISTENT}
}

do_mount()
{
    echo "Mounting critical endpoints.."

    mkdir -p ${TARGET}

    STATEDIR=/tmp/mnt/STATE
    mkdir -p $STATEDIR || true
    mount ${STATE} $STATEDIR

    mkdir -p ${STATEDIR}/cOS
    # TODO: Size should be tweakable
    dd if=/dev/zero of=${STATEDIR}/cOS/active.img bs=1M count=3240
    mkfs.ext2 ${STATEDIR}/cOS/active.img -L COS_ACTIVE
    sync
    LOOP=$(losetup --show -f ${STATEDIR}/cOS/active.img)
    mount -t ext2 $LOOP $TARGET

    mkdir -p ${TARGET}/boot
    if [ -n "${BOOT}" ]; then
        mkdir -p ${TARGET}/boot/efi
        mount ${BOOT} ${TARGET}/boot/efi
    fi

    mkdir -p ${TARGET}/oem
    mount ${OEM} ${TARGET}/oem
    mkdir -p ${TARGET}/usr/local
    mount ${PERSISTENT} ${TARGET}/usr/local
}

get_url()
{
    FROM=$1
    TO=$2
    case $FROM in
        ftp*|http*|tftp*)
            n=0
            attempts=5
            until [ "$n" -ge "$attempts" ]
            do
                curl -o $TO -fL ${FROM} && break
                n=$((n+1))
                echo "Failed to download, retry attempt ${n} out of ${attempts}"
                sleep 2
            done
            ;;
        *)
            cp -f $FROM $TO
            ;;
    esac
}

get_iso()
{
    if [ -n "$COS_INSTALL_ISO_URL" ]; then
        ISOMNT=$(mktemp -d -p /tmp cos.XXXXXXXX.isomnt)
        TEMP_FILE=$(mktemp -p /tmp cos.XXXXXXXX.iso)
        get_url ${COS_INSTALL_ISO_URL} ${TEMP_FILE}
        ISO_DEVICE=$(losetup --show -f $TEMP_FILE)
        mount -o ro ${ISO_DEVICE} ${ISOMNT}
    fi
}

do_copy()
{
    echo "Copying cOS.."

    rsync -aqAX --exclude='mnt' --exclude='proc' --exclude='sys' --exclude='dev' --exclude='tmp' ${DISTRO}/ ${TARGET}
     if [ -n "$COS_INSTALL_CONFIG_URL" ]; then
        OEM=${TARGET}/oem/99_custom.yaml
        get_url "$COS_INSTALL_CONFIG_URL" $OEM
        chmod 600 ${OEM}
    fi
}

SELinux_relabel()
{
    if which setfiles > /dev/null && [ -e ${TARGET}/etc/selinux/targeted/contexts/files/file_contexts ]; then
        setfiles -r ${TARGET} ${TARGET}/etc/selinux/targeted/contexts/files/file_contexts ${TARGET}
    fi
}

install_grub()
{
    echo "Installing GRUB.."

    if [ "$COS_INSTALL_DEBUG" ]; then
        GRUB_DEBUG="cos.debug"
    fi

    if [ -z "${COS_INSTALL_TTY}" ]; then
        TTY=$(tty | sed 's!/dev/!!')
    else
        TTY=$COS_INSTALL_TTY
    fi

    if [ "$COS_INSTALL_NO_FORMAT" = "true" ]; then
        return 0
    fi

    if [ "$COS_INSTALL_FORCE_EFI" = "true" ] || [ -e /sys/firmware/efi ]; then
        GRUB_TARGET="--target=${ARCH}-efi --efi-directory=${TARGET}/boot/efi"
    fi

    mkdir ${TARGET}/proc || true
    mkdir ${TARGET}/dev || true
    mkdir ${TARGET}/sys || true
    mkdir ${TARGET}/tmp || true

    grub2-install ${GRUB_TARGET} --root-directory=${TARGET}  --boot-directory=${STATEDIR} --removable ${DEVICE}

    GRUBDIR=
    if [ -d "${STATEDIR}/grub" ]; then
        GRUBDIR="${STATEDIR}/grub"
    elif [ -d "${STATEDIR}/grub2" ]; then
        GRUBDIR="${STATEDIR}/grub2"
    fi

    cp -rfv /etc/cos/grub.cfg $GRUBDIR/grub.cfg

    if [ -e "/dev/${TTY%,*}" ] && [ "$TTY" != tty1 ] && [ "$TTY" != console ] && [ -n "$TTY" ]; then
        sed -i "s!console=tty1!console=tty1 console=${TTY}!g" $GRUBDIR/grub.cfg
    fi
}

setup_style()
{
    if [ "$COS_INSTALL_FORCE_EFI" = "true" ] || [ -e /sys/firmware/efi ]; then
        PARTTABLE=gpt
        BOOTFLAG=esp
        if [ ! -e /sys/firmware/efi ]; then
            echo WARNING: installing EFI on to a system that does not support EFI
        fi
    elif [ "$COS_INSTALL_FORCE_GPT" = "true" ]; then
        PARTTABLE=gpt
        BOOTFLAG=bios_grub
    else
        PARTTABLE=msdos
        BOOTFLAG=boot
    fi
}

validate_progs()
{
    for i in $PROGS; do
        if [ ! -x "$(which $i)" ]; then
            MISSING="${MISSING} $i"
        fi
    done

    if [ -n "${MISSING}" ]; then
        echo "The following required programs are missing for installation: ${MISSING}"
        exit 1
    fi
}

validate_device()
{
    DEVICE=$COS_INSTALL_DEVICE
    if [ ! -b ${DEVICE} ]; then
        echo "You should use an available device. Device ${DEVICE} does not exist."
        exit 1
    fi
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --no-format)
            COS_INSTALL_NO_FORMAT=true
            ;;
        --force-efi)
            COS_INSTALL_FORCE_EFI=true
            ;;
        --force-gpt)
            COS_INSTALL_FORCE_GPT=true
            ;;
        --poweroff)
            COS_INSTALL_POWER_OFF=true
            ;;
        --strict)
            STRICT_MODE=true
            ;;
        --debug)
            set -x
            COS_INSTALL_DEBUG=true
            ;;
        --config)
            shift 1
            COS_INSTALL_CONFIG_URL=$1
            ;;
        --iso)
            shift 1
            COS_INSTALL_ISO_URL=$1
            ;;
        --tty)
            shift 1
            COS_INSTALL_TTY=$1
            ;;
        -h)
            usage
            ;;
        --help)
            usage
            ;;
        *)
            if [ "$#" -gt 2 ]; then
                usage
            fi
            INTERACTIVE=true
            COS_INSTALL_DEVICE=$1
            break
            ;;
    esac
    shift 1
done

if [ -e /etc/environment ]; then
    source /etc/environment
fi

if [ -e /etc/os-release ]; then
    source /etc/os-release
fi

if [ -e /etc/cos/config ]; then
    source /etc/cos/config
fi

if [ -z "$COS_INSTALL_DEVICE" ]; then
    usage
fi

validate_progs
validate_device

trap cleanup exit

if [ "$STRICT_MODE" = "true" ]; then
  cos-setup before-install
else
  cos-setup before-install || true
fi

get_iso
setup_style
do_format
do_mount
do_copy
install_grub

SELinux_relabel

if [ "$STRICT_MODE" = "true" ]; then
  run_hook after-install-chroot $TARGET
else
  run_hook after-install-chroot $TARGET || true
fi

umount_target 2>/dev/null

prepare_recovery
prepare_passive

cos-rebrand

if [ "$STRICT_MODE" = "true" ]; then
  cos-setup after-install
else
  cos-setup after-install || true
fi

if [ -n "$INTERACTIVE" ]; then
    exit 0
fi

if [ "$COS_INSTALL_POWER_OFF" = true ] || grep -q 'cos.install.power_off=true' /proc/cmdline; then
    poweroff -f
else
    echo " * Rebooting system in 5 seconds (CTRL+C to cancel)"
    sleep 5
    reboot -f
fi
