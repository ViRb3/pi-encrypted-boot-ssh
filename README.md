# Raspberry Pi Encrypted Boot with SSH

> Tested on Raspberry Pi [3B](https://www.raspberrypi.org/products/raspberry-pi-3-model-b/) & [4B](https://www.raspberrypi.org/products/raspberry-pi-4-model-b/) with [Ubuntu Server 21.04](https://ubuntu.com/download/raspberry-pi)

## Introduction

This guide will show you how to encrypt your Raspberry Pi's root partition and set up an [initramfs](https://en.wikipedia.org/wiki/Initial_ramdisk) that will prompt for the password, decrypt the partition and gracefully resume boot. You will also learn how to enable SSH during this pre-boot stage, allowing you to unlock the partition remotely.

While the steps are written for the Raspberry Pi, they should be easily transferrable to other SBCs and computers as a whole.

This guide operates directly on an image file and therefore does not require an SD card for the setup. The resulting image can be flashed to an SD card as usual.

## Table of Content

- [Raspberry Pi Encrypted Boot with SSH](#raspberry-pi-encrypted-boot-with-ssh)
  - [Introduction](#introduction)
  - [Table of Content](#table-of-content)
  - [Requirements](#requirements)
  - [On the host](#on-the-host)
  - [In the chroot](#in-the-chroot)
    - [Prepare](#prepare)
    - [Device configuration](#device-configuration)
    - [Cryptsetup](#cryptsetup)
    - [SSH](#ssh)
    - [Build initramfs](#build-initramfs)
    - [Cleanup](#cleanup)
  - [On the host](#on-the-host-1)
  - [On the Raspberry Pi](#on-the-raspberry-pi)
  - [Avoiding SSH key collisions](#avoiding-ssh-key-collisions)
  - [Resources](#resources)

## Requirements

- A Raspberry Pi Linux image (e.g. [Ubuntu Server 21.04](https://ubuntu.com/download/raspberry-pi))
- A computer (host) running Linux (e.g. [Xubuntu 21.04](https://xubuntu.org/download))

  > :warning: **NOTE:** Your host's Linux should be as similar as possible to the Raspberry Pi's Linux. If you are preparing Ubuntu 21.04 for the Raspberry Pi, use the same version on the host, otherwise you may encounter issues inside the chroot.

## On the host

Install dependencies:

> You can skip `qemu-user-static` if your host Linux's architecture matches that of the Raspberry Pi's Linux image.

```sh
apt update
apt install -y kpartx cryptsetup-bin qemu-user-static
```

Create two copies of the Raspberry Pi's Linux image - one to read from (base), and one to write to (target):

- ubuntu-base.img
- ubuntu-target.img

Map both images as devices, ensuring the base is readonly:

```sh
kpartx -ar "$PWD/ubuntu-base.img"
kpartx -a "$PWD/ubuntu-target.img"
```

If your system automatically mounted any partitions, unmount them:

```sh
umount /media/**/*
```

Run [lsblk](https://linux.die.net/man/8/lsblk) and verify the process was successful - you should see two loopback devices, each with two partitions:

```sh
NAME      MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT # COMMENT
loop0       7:0    0  3.3G  0 loop            # ubuntu-base.img
├─loop0p1 253:0    0  256M  0 part            # ├─ boot
└─loop0p2 253:1    0    3G  0 part            # └─ root
loop1       7:1    0  3.3G  1 loop            # ubuntu-target.img
├─loop1p1 253:2    0  256M  1 part            # ├─ boot
└─loop1p2 253:3    0    3G  1 part            # └─ root
```

Mount the base image's root partition:

```sh
mkdir -p /mnt/original/
mount /dev/mapper/loop0p2 /mnt/original/
```

Replace the target image's root partition with a new, encrypted partition:

> :warning: **NOTE:**
>
> In this example we will use [aes-adiantum](https://github.com/google/adiantum) as the encryption method since it is much faster on targets that lack hardware AES acceleration. Ensure that both the host's and Pi's kernel (>= [5.0.0](https://kernelnewbies.org/Linux_5.0#Adiantum_file_system_encryption_for_low_power_devices), must include .ko) and [cryptsetup](https://linux.die.net/man/8/cryptsetup) (>= [2.0.6](https://mirrors.edge.kernel.org/pub/linux/utils/cryptsetup/v2.0/v2.0.6-ReleaseNotes)) support your encryption method.
>
> By default cryptsetup will benchmark the system that is creating the encrypted partition to find suitable memory difficulty. This is usually half of the machine's available RAM. Since the calculation is is done on the host, it is very likely to exceed the Raspberry Pi's maximum RAM and make it impossible to unlock the partition. To prevent this, set the [--pbkdf-memory](https://linux.die.net/man/8/cryptsetup) argument to something less than the Pi's maximum RAM.

```sh
cryptsetup luksFormat -c xchacha20,aes-adiantum-plain64 --pbkdf-memory 512000 /dev/mapper/loop1p2
```

Open (decrypt) the new partition:

```
cryptsetup open /dev/mapper/loop1p2 crypted
```

Then format and mount it:

```
mkfs.ext4 /dev/mapper/crypted
mkdir -p /mnt/chroot/
mount /dev/mapper/crypted /mnt/chroot/
```

Copy the base image's root partition files to the target image's new, encrypted root partition. You can use [dd](https://linux.die.net/man/1/dd), but [rsync](https://linux.die.net/man/1/rsync) is faster:

```sh
rsync --archive --hard-links --acls --xattrs --one-file-system --numeric-ids --info="progress2" /mnt/original/* /mnt/chroot/
```

Set up a [chroot](https://linux.die.net/man/1/chroot) by mounting the target image's boot partition and required virtual filesystems from the host:

```sh
mkdir -p /mnt/chroot/boot/
mount /dev/mapper/loop1p1 /mnt/chroot/boot/
mount -t proc none /mnt/chroot/proc/
mount -t sysfs none /mnt/chroot/sys/
mount -o bind /dev /mnt/chroot/dev/
mount -o bind /dev/pts /mnt/chroot/dev/pts/
```

Enter the chroot:

```sh
LANG=C chroot /mnt/chroot/
```

## In the chroot

### Prepare

Install dependencies:

```sh
apt update
apt install -y busybox cryptsetup dropbear-initramfs
```

If the chroot cannot resolve hostnames, you might have a symlinked [resolv.conf](https://linux.die.net/man/5/resolv.conf) that is invalid in the chroot context. To work around this, back it up and create a simple nameserver replacement:

```sh
mv /etc/resolv.conf /etc/resolv.conf.bak
echo "nameserver 1.1.1.1" > /etc/resolv.conf
```

### Device configuration

Run [blkid](https://linux.die.net/man/8/blkid) and note the details of your encrypted and decrypted partitions:

```sh
# encrypted
/dev/mapper/loop1p2: UUID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" TYPE="crypto_LUKS" PARTUUID="cccccccc-cc"
# decrypted
/dev/mapper/crypted: UUID="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" BLOCK_SIZE="4096" TYPE="ext4"
```

Edit [/etc/fstab](https://linux.die.net/man/5/fstab) and replace the root entry with your decrypted (virtual) partition's device name:

```sh
/dev/mapper/crypted /               ext4  discard,errors=remount-ro 0 1
LABEL=system-boot   /boot/firmware  vfat  defaults                  0 1
```

Edit [/etc/crypttab](https://linux.die.net/man/5/crypttab) and add an entry with your encrypted (raw) partition's UUID:

```sh
crypted UUID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa none luks,initramfs
```

Edit `/boot/cmdline.txt` and update the root entry:

```sh
root=/dev/mapper/crypted cryptdevice=UUID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:crypted
```

### Cryptsetup

Edit the cryptsetup initramfs hook to ensure cryptsetup ends up in the initramfs:

```sh
echo "CRYPTSETUP=y" >> /etc/cryptsetup-initramfs/conf-hook
```

At least on Ubuntu Server 21.04, the [initramfs-tools](https://manpages.ubuntu.com/manpages/xenial/man8/initramfs-tools.8.html) `cryptroot` hook will resolve any UUIDs to device names during initramfs generation. This is a problem because the device names will likely differ between the host and the Raspberry Pi, resulting in failure to boot. To work around this, apply the following patch:

```patch
patch --no-backup-if-mismatch /usr/share/initramfs-tools/hooks/cryptroot << 'EOF'
--- cryptroot
+++ cryptroot
@@ -33,7 +33,7 @@
         printf '%s\0' "$target" >>"$DESTDIR/cryptroot/targets"
         crypttab_find_entry "$target" || return 1
         crypttab_parse_options --missing-path=warn || return 1
-        crypttab_print_entry
+        printf '%s %s %s %s\n' "$_CRYPTTAB_NAME" "$_CRYPTTAB_SOURCE" "$_CRYPTTAB_KEY" "$_CRYPTTAB_OPTIONS" >&3
     fi
 }
EOF
```

If you are planning to run on a Raspberry Pi 3, the default timeout when waiting for decryption (e.g. 10 seconds) may be too short and you may get a timeout error. To work around this, bump the timeout:

```sh
sed -i 's/^TIMEOUT=.*/TIMEOUT=100/g' /usr/share/cryptsetup/initramfs/bin/cryptroot-unlock
```

### SSH

Write your SSH public key inside dropbear's `authorized_keys` and fix permissions:

```sh
echo "/REDACTED/" > /etc/dropbear-initramfs/authorized_keys
chmod 0600 /etc/dropbear-initramfs/authorized_keys
```

### Build initramfs

Note whether you already have an initramdisk - it should be under `/boot/initrd.img`. This will decide whether you need to update your boot config later on.

Note your kernel version. If there are multiple, choose the one you want to run:

```sh
ls /lib/modules/
```

Build the new initramdisk using the kernel version from above, overwriting the old initramdisk if it exists:

```sh
mkinitramfs -o /boot/initrd.img "5.4.0-1008-raspi"
```

If you had an initramdisk when you checked in the beginning of this section, then your system is already configured to use an initramfs - no changes are necessary. Otherwise, add an entry to your boot config:

```sh
echo initramfs initrd.img >> /boot/config.txt
```

### Cleanup

Revert any changes if you have made them before:

```sh
mv /etc/resolv.conf.bak /etc/resolv.conf
```

Sync and exit the chroot:

```sh
sync
history -c && exit
```

## On the host

Unmount everything and clean up any remaining artifacts:

```sh
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
```

You are now ready to flash `ubuntu-target.img` to an SD card.

## On the Raspberry Pi

Boot the Raspberry Pi with the new SD card. It will obtain an IP address from the DHCP server and start listening for SSH connections. To decrypt the root partition and continue boot, from any shell, simply run `cryptroot-unlock`.

Once booted into the decrypted system, you will notice that the root partition is still sized at ~3GB, no matter how much space you have on the SD card. To fix this, delete and recreate the partition, this time using all available space, then tell cryptsetup to resize it:

```sh
echo -e "d\n2\nn\np\n2\n\n\nw" | fdisk /dev/mmcblk0
cryptsetup resize crypted
```

Finally, reboot the system for the changes to take effect:

```sh
reboot
```

## Avoiding SSH key collisions

To avoid host key collisions you can configure a separate trusted hosts store in the `~/.ssh/config` of your client:

```ssh
Host box
	Hostname 192.168.0.30
	User root

Host box-initramfs
	Hostname 192.168.0.30
	User root
	UserKnownHostsFile ~/.ssh/known_hosts.initramfs
```

## Resources

- https://www.kali.org/docs/arm/raspberry-pi-with-luks-disk-encryption/
- https://wiki.archlinux.org/index.php/Dm-crypt/Specialties
- https://wiki.gentoo.org/wiki/Custom_Initramfs
- https://www.raspberrypi.org/forums/viewtopic.php?t=252980
- https://thej6s.com/articles/2019-03-05__decrypting-boot-drives-remotely/
- https://www.pbworks.net/ubuntu-guide-dropbear-ssh-server-to-unlock-luks-encrypted-pc/
