#! /bin/bash

# check for root up front
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# double check that there's a public key available for dropbear
if [ ! -f "./id_rsa.pub" ]; then
    echo "Place a public key called \"id_rsa.pub\" in the same directory as this script to use with dropbear"
    exit 1
fi

# take in a password as input and double check it, later use this to encrypt the disk
echo -n 'Enter a password that will be used to encrypt your image: ' 
read -r -s PASSWORD
echo
echo -n 'Verify the password: '
read -r -s PASSWORD_VERIFICATION
echo
if [ "$PASSWORD" != "$PASSWORD_VERIFICATION" ]; then
  echo "Verification failed, please try again."
  exit 1
fi

# update repos and install required packages
apt-get update
apt-get install -y curl xz-utils kpartx cryptsetup-bin rsync qemu-user-static

# download, decompress, and make a copy of ubuntu server
curl https://cdimage.ubuntu.com/releases/21.04/release/ubuntu-21.04-preinstalled-server-arm64+raspi.img.xz -o ubuntu-base.img.xz
xz -d -v ubuntu-base.img.xz
cp ubuntu-base.img ubuntu-target.img

# create device mapper entries with kpartx
kpartx -arv "$PWD/ubuntu-base.img"
kpartx -av  "$PWD/ubuntu-target.img"

# get the base loop entry, this will be something like "loop0", target loop entry will be similar
BASE_LOOP_DEV=$(losetup | grep ubuntu-base | tail -1 | awk '{print $1}' | sed 's/\/dev\///')
# set the base loop entry root partition, this will be something like "loop0p2", target partitions will be similar
BASE_LOOP_ROOT="${BASE_LOOP_DEV}p2"
TARGET_LOOP_DEV=$(losetup | grep ubuntu-target | tail -1 | awk '{print $1}' | sed 's/\/dev\///')
TARGET_LOOP_BOOT="${TARGET_LOOP_DEV}p1"
TARGET_LOOP_ROOT="${TARGET_LOOP_DEV}p2"

# mount the base root partition
mkdir -p /mnt/original/
mount /dev/mapper/"$BASE_LOOP_ROOT" /mnt/original/

# encrypt and open the target root parition
echo "$PASSWORD" | cryptsetup luksFormat -c xchacha20,aes-adiantum-plain64 --pbkdf-memory 512000 /dev/mapper/"$TARGET_LOOP_ROOT"
echo "$PASSWORD" | cryptsetup open /dev/mapper/"$TARGET_LOOP_ROOT" crypted

# format the newly encrypted target root partition
mkfs.ext4 /dev/mapper/crypted

# make a chroot folder and mount the now ext4 formatted target root partition
mkdir -p /mnt/chroot/
mount /dev/mapper/crypted /mnt/chroot/

# the target partition is empty because it's been formatted so we copy over the original files from the base image
rsync --archive --hard-links --acls --xattrs --one-file-system --numeric-ids --info="progress2" /mnt/original/* /mnt/chroot/

# set up a chroot environment to use with the target image so we can customize it
mkdir -p /mnt/chroot/boot/
mount /dev/mapper/"$TARGET_LOOP_BOOT" /mnt/chroot/boot/
mount -t proc none /mnt/chroot/proc/
mount -t sysfs none /mnt/chroot/sys/
mount -o bind /dev /mnt/chroot/dev/
mount -o bind /dev/pts /mnt/chroot/dev/pts/
cp chroot.sh /mnt/chroot/chroot.sh
cp id_rsa.pub /mnt/chroot/id_rsa.pub

# chroot into the target image and run the chroot script
LANG=C chroot /mnt/chroot ./chroot.sh

# clean up
umount /mnt/chroot/boot
umount /mnt/chroot/sys
umount /mnt/chroot/proc
umount /mnt/chroot/dev/pts
umount /mnt/chroot/dev
umount /mnt/chroot
cryptsetup close crypted
umount /mnt/original
rm -d /mnt/chroot
rm -d /mnt/original
kpartx -d "$PWD/ubuntu-base.img"
kpartx -d "$PWD/ubuntu-target.img"
rm ubuntu-base.img

echo "encryption complete, ubuntu-target.img ready to flash."
exit 0
