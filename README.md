# Raspberry Pi Encrypted Boot with SSH
> Tested on Raspberry Pi [3B](https://www.raspberrypi.org/products/raspberry-pi-3-model-b/) & [4B](https://www.raspberrypi.org/products/raspberry-pi-4-model-b/) with [Ubuntu Server 19.10.1](https://ubuntu.com/download/raspberry-pi)

## Introduction
This guide will show you how to encrypt your Raspberry Pi's root partition and set up an [initramfs](https://en.wikipedia.org/wiki/Initial_ramdisk) that will prompt for the password, decrypt the partition and gracefully resume boot. You will also learn how to enable SSH during this pre-boot stage, allowing you to unlock the partition remotely.

While the steps are written for the Raspberry Pi, they should be easily transferrable to other SBCs and computers as a whole.

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
- Raspberry Pi
- OS image
- SD card
  - make sure there is enough space for the OS

While this guide operates directly on the SD card, you can easily work on an image file instead and then flash the result to an SD card. This can be done by creating _two_ copies of the initial OS image file and mounting both via [kpartx](https://linux.die.net/man/8/kpartx). One will be readonly and used to fill the new, empty, encrypted root partition of the other.

## On the host
Assuming the host is x86-64 and the Raspberry Pi is aarch64/arm, [qemu](https://www.qemu.org/) wil be required - install it
```sh
apt update
apt install -y qemu-user-static
```

Format the root partition. In this example the device is `/dev/sdb2` - adapt as necessary!
```sh
echo -e "d\n2\nw" | fdisk /dev/sdb
echo -e "n\np\n2\n\n\nw" | fdisk /dev/sdb
```

Create a new, encrypted partition in its place. In this example we will use [aes-adiantum](https://github.com/google/adiantum) since it is much faster on targets that lack hardware AES acceleration. Ensure that both the host's and Pi's kernel (>= [5.0.0](https://kernelnewbies.org/Linux_5.0#Adiantum_file_system_encryption_for_low_power_devices), must include .ko) and [cryptsetup](https://linux.die.net/man/8/cryptsetup) (>= [2.0.6](https://mirrors.edge.kernel.org/pub/linux/utils/cryptsetup/v2.0/v2.0.6-ReleaseNotes)) support it!
> :warning: __NOTE:__ By default cryptsetup will benchmark the system that is creating the encrypted partition to find suitable memory difficulty. This is usually half of the machine's available RAM. Since the calculation is is done on the host, it is very likely to exceed the Raspberry Pi's maximum RAM and make it impossible to unlock the partition. To prevent this, set the [--pbkdf-memory](https://linux.die.net/man/8/cryptsetup) argument to something less than the Pi's maximum RAM.
```sh
cryptsetup luksFormat -c xchacha20,aes-adiantum-plain64 --pbkdf-memory 512000 /dev/sdb2
cryptsetup open /dev/sdb2 crypted
mkfs.ext4 /dev/mapper/crypted
mkdir -p /mnt/chroot/
mount /dev/mapper/crypted /mnt/chroot/
```

Mount the original image and its root partition. In this example the device is `/dev/mapper/loop0p2` - adapt as necessary!
```sh
kpartx -ar "ubuntu-19.10.1-preinstalled-server-arm64+raspi3.img"
mkdir -p /mnt/original/
mount /dev/mapper/loop0p2 /mnt/original/
```

Copy its contents to the new, empty, encrypted root partition. You could alternatively [dd](https://linux.die.net/man/1/dd) the raw partition, but [rsync](https://linux.die.net/man/1/rsync) is faster.
```sh
rsync -avh /mnt/original/* /mnt/chroot/
```

Set up a [chroot](https://linux.die.net/man/1/chroot) by mounting the boot partition and required virtual filesystems from the host
```sh
mkdir -p /mnt/chroot/boot/
mount /dev/sdb1 /mnt/chroot/boot/
mount -t proc none /mnt/chroot/proc/
mount -t sysfs none /mnt/chroot/sys/
mount -o bind /dev /mnt/chroot/dev/
mount -o bind /dev/pts /mnt/chroot/dev/pts/
```

Prepare and enter the chroot. Depending on the image architecture you may have to use different qemu binaries.
```sh
cp /usr/bin/qemu-arm-static /mnt/chroot/usr/bin/
cp /usr/bin/qemu-aarch64-static /mnt/chroot/usr/bin/
LANG=C chroot /mnt/chroot/
```

## In the chroot
### Prepare
Install dependencies
```sh
apt update
apt install -y busybox cryptsetup dropbear-initramfs
```

If the chroot cannot resolve hostnames, you might have a symlinked [resolv.conf](https://linux.die.net/man/5/resolv.conf) that is invalid in the chroot context. To work around this, back it up and create a simple nameserver replacement.
```sh
mv /etc/resolv.conf /etc/resolv.conf.bak
echo "nameserver 1.1.1.1" > /etc/resolv.conf
```
 
### Device configuration
Run [blkid](https://linux.die.net/man/8/blkid) and note the following
```sh
/dev/sdb2: UUID="b2094afd-bba5-4b1f-8d16-e0086f0a605b" TYPE="crypto_LUKS" PARTUUID="3d2c824d-02"
/dev/mapper/crypted: UUID="5e5f88a1-8aae-4c1a-a9a6-d8a7adcd2db9" TYPE="ext4"
```

Edit [/etc/fstab](https://linux.die.net/man/5/fstab) and replace the root entry with your `decrypted` (virtual) partition. In this example - `/dev/mapper/crypted`, NOT `/dev/sdb2`.
```sh
/dev/mapper/crypted  /               ext4  defaults  0 0
LABEL=system-boot    /boot/firmware  vfat  defaults  0 1
```

Edit [/etc/crypttab](https://linux.die.net/man/5/crypttab) and add an entry with your `encrypted` (raw) partition. In this example - `/dev/sdb2`.
> :warning: __NOTE:__ Since the device name will likely be different on the Raspberry Pi, make sure to use the name that will be found on the Pi. Do not use UUIDs since cryptsetup will try to play smart and resolve them to a device name at _build_ time.
```sh
crypted  /dev/mmcblk0p2  none  luks
```

Edit `/boot/cmdline.txt` and update the root entry.
On Ubunu Server this is `nobtcmd.txt` or `btcmd.txt`, depending on the operating mode.
```sh
root=/dev/mapper/crypted cryptdevice=/dev/mmcblk0p2:crypted rootfstype=ext4
```

### Cryptsetup
Edit the cryptsetup initramfs hook to ensure cryptsetup ends up in the initramfs
```sh
echo "CRYPTSETUP=y" >> /etc/cryptsetup-initramfs/conf-hook
```

### SSH
Write your SSH public key inside `/etc/dropbear-initramfs/authorized_keys` and `chmod 0600` the file

### Build initramfs
Note the kernel version
```sh
ls /lib/modules/
```

Build the new initramfs, overwriting the old one
```sh
mkinitramfs -o /boot/initrd.img "5.3.0-1014-raspi2"
```

If your system is not configured to use an initramfs (e.g. if there was nothing to overwrite), add an entry to your boot config
```sh
echo initramfs initrd.img >> /boot/config.txt
```

### Cleanup
Revert any changes you have made before
```sh
mv /etc/resolv.conf.bak /etc/resolv.conf
```
Sync and exit the chroot
```sh
sync
exit
```

## On the host
Unmount everything
```sh
umount /mnt/chroot/boot
umount /mnt/chroot/sys
umount /mnt/chroot/proc
umount /mnt/chroot/dev/pts
umount /mnt/chroot/dev
umount /mnt/chroot
cryptsetup close crypted
kpartx -d "ubuntu-19.10.1-preinstalled-server-arm64+raspi3.img"
```

## On the Raspberry Pi
Boot the Raspberry Pi with the new SD card. It will obtain an IP address from the DHCP server and start listening for SSH connections. To decrypt the root partition and continue boot, from any shell, simply run `cryptroot-unlock`.

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