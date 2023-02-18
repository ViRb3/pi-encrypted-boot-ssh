# Raspberry Pi Encrypted Boot with SSH

> ⚠️ This guide is only supported for Raspberry Pi [3B](https://www.raspberrypi.org/products/raspberry-pi-3-model-b/) & [4B](https://www.raspberrypi.org/products/raspberry-pi-4-model-b/) with [Ubuntu Server 22.04](https://ubuntu.com/download/raspberry-pi) and [Raspberry Pi OS Lite 11 (5.15)](https://www.raspberrypi.com/software/operating-systems/). \
> Other platforms and distributions may work, but there will be unexpected issues or side effects.

## Introduction

This guide will show you how to encrypt your Raspberry Pi's root partition and set up an [initramfs](https://en.wikipedia.org/wiki/Initial_ramdisk) that will prompt for the password, decrypt the partition and gracefully resume boot. You will also learn how to enable SSH during this pre-boot stage, allowing you to unlock the partition remotely. There are also optional steps for WiFi setup.

While the steps are written for the Raspberry Pi, they should be easily transferrable to other SBCs and computers as a whole. However, only the Raspberry Pi is officially supported by this guide.

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
    - [WiFi support](#wifi-support)
      - [Ubuntu](#ubuntu)
      - [Raspberry Pi OS](#raspberry-pi-os)
    - [Build initramfs](#build-initramfs)
      - [Ubuntu](#ubuntu-1)
      - [Raspberry Pi OS](#raspberry-pi-os-1)
    - [Cleanup](#cleanup)
  - [On the host](#on-the-host-1)
  - [On the Raspberry Pi](#on-the-raspberry-pi)
  - [Avoiding SSH key collisions](#avoiding-ssh-key-collisions)
  - [Resources](#resources)

## Requirements

- A Raspberry Pi Linux image (e.g. [Ubuntu Server 22.04](https://ubuntu.com/download/raspberry-pi) or [Raspberry Pi OS Lite 11 (5.15)](https://www.raspberrypi.com/software/operating-systems/))
- A computer (host) running Linux (e.g. [Xubuntu 22.04](https://xubuntu.org/download))

  > :warning: **NOTE:** Your host's Linux should be as similar as possible to the Raspberry Pi's Linux. If you are preparing Ubuntu 22.04 for the Raspberry Pi, use the same version on the host, otherwise you may encounter issues inside the chroot.

## On the host

Install dependencies:

- You can skip `qemu-user-static` if your host Linux's architecture matches that of the Raspberry Pi's Linux image.

```sh
apt update
apt install -y kpartx cryptsetup-bin qemu-user-static
```

Create two copies of the Raspberry Pi's Linux image — one to read from (base), and one to write to (target):

- pi-base.img
- pi-target.img

If you're planning to install additional software (e.g. WiFi drivers), increase the size of the target image or you may not have enough space:

```bash
apt install qemu-utils
qemu-img resize pi-target.img +1G
parted pi-target.img resizepart 2 100%
```

Map both images as devices, ensuring the base is readonly:

```sh
kpartx -ar "$PWD/pi-base.img"
kpartx -a "$PWD/pi-target.img"
```

If your system automatically mounted any partitions, unmount them:

```sh
umount /media/**/*
```

Run [lsblk](https://linux.die.net/man/8/lsblk) and verify the process was successful — you should see two loopback devices, each with two partitions:

```sh
NAME      MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT # COMMENT
loop0       7:0    0  3.3G  0 loop            # pi-base.img
├─loop0p1 253:0    0  256M  0 part            # ├─ boot
└─loop0p2 253:1    0    3G  0 part            # └─ root
loop1       7:1    0  3.3G  1 loop            # pi-target.img
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
> By default cryptsetup will use a memory-hard PBKDF algorithm that requires 4GB of RAM. With these settings, you are likely to exceed the Raspberry Pi's maximum RAM and make it impossible to unlock the partition. To work around this, set the [--pbkdf-memory](https://linux.die.net/man/8/cryptsetup) and [--pbkdf-parallel](https://linux.die.net/man/8/cryptsetup) arguments so when you multiply them, the result is less than your Pi's total RAM:

```sh
cryptsetup luksFormat -c xchacha20,aes-adiantum-plain64 --pbkdf-memory 512000 --pbkdf-parallel=1 /dev/mapper/loop1p2
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

Since Ubuntu has a symlinked [resolv.conf](https://linux.die.net/man/5/resolv.conf) that is invalid in the chroot context, you will not have internet access. To work around this, back it up and create a simple nameserver replacement:

```sh
mv /etc/resolv.conf /etc/resolv.conf.bak
echo "nameserver 1.1.1.1" > /etc/resolv.conf
```

Next, install the dependencies:

```sh
apt update
apt install -y busybox cryptsetup dropbear-initramfs
```

### Device configuration

Edit [/etc/fstab](https://linux.die.net/man/5/fstab) and replace the root entry with your decrypted (virtual) partition's device name:

```sh
#PARTUUID=e8af6eb2-02 / ext4 defaults,noatime          0 1
#LABEL=writable	      /	ext4 discard,errors=remount-ro 0 1
/dev/mapper/crypted   / ext4 defaults,noatime          0 1
```

Run [blkid](https://linux.die.net/man/8/blkid) and note the details of your encrypted partition:

```sh
blkid | grep crypto_LUKS

/dev/mapper/loop1p2: UUID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" TYPE="crypto_LUKS" PARTUUID="cccccccc-cc"
```

Edit [/etc/crypttab](https://linux.die.net/man/5/crypttab) and add an entry with your encrypted (raw) partition's UUID:

```sh
crypted UUID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa none luks,initramfs
```

Edit `/boot/cmdline.txt` and update the root entry:

```sh
#root=PARTUUID=21e60f8c-02
#root=/dev/mmcblk0p2
root=/dev/mapper/crypted cryptdevice=UUID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:crypted
```

Enable SSH for the decrypted OS:

```sh
touch /boot/ssh
```

### Cryptsetup

Edit the cryptsetup initramfs hook to ensure cryptsetup ends up in the initramfs:

```sh
echo "CRYPTSETUP=y" >> /etc/cryptsetup-initramfs/conf-hook
```

The [initramfs-tools](https://manpages.ubuntu.com/manpages/xenial/man8/initramfs-tools.8.html) `cryptroot` hook will resolve any UUIDs to device names during initramfs generation. This is a problem because the device names will likely differ between the host and the Raspberry Pi, resulting in failure to boot. To work around this, apply the following patch:

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

The default timeout when waiting for decryption (10 seconds) may be too short and result in a timeout error. To work around this, bump the value:

```sh
sed -i 's/^TIMEOUT=.*/TIMEOUT=100/g' /usr/share/cryptsetup/initramfs/bin/cryptroot-unlock
```

### SSH

Write your SSH public key inside dropbear's and your decrypted OS's `authorized_keys` and fix permissions:

```sh
mkdir -p /root/.ssh && chmod 0700 /root/.ssh
# Ubuntu
echo "/REDACTED/" | tee /etc/dropbear/initramfs/authorized_keys /root/.ssh/authorized_keys
chmod 0600 /etc/dropbear/initramfs/authorized_keys /root/.ssh/authorized_keys
# Raspberry Pi OS
echo "/REDACTED/" | tee /etc/dropbear-initramfs/authorized_keys /root/.ssh/authorized_keys
chmod 0600 /etc/dropbear-initramfs/authorized_keys /root/.ssh/authorized_keys
```

### WiFi support

This step is optional. If you want the Raspberry Pi to be decryptable over WiFi, check out the guides below. Note that the differences between distros is very small, so you can easily adapt any particular guide.

#### Ubuntu

- [Wireless-Builtin.md](Wireless-Builtin.md)
- [Wireless-USB.md](Wireless-USB.md)

#### Raspberry Pi OS

- [Wireless-USB2.md](Wireless-USB2.md)

### Build initramfs

#### Ubuntu

Note your kernel version. If there are multiple, choose the one you want to run:

```sh
ls /lib/modules/
```

Build the new initramdisk using the kernel version from above, overwriting the old initramdisk:

```sh
mkinitramfs -o /boot/initrd.img "5.15.0-1005-raspi"
```

#### Raspberry Pi OS

Enable automatic initramfs generation on kernel update:

```sh
sed -i 's/^#INITRD=Yes$/INITRD=Yes/g' /etc/default/raspberrypi-kernel
```

This will create a differently suffixed file on every update. To make your Raspberry boot from the latest one every time, create the following file:

- `/etc/initramfs-tools/hooks/update_initrd`

  ```sh
  #!/bin/sh -e
  # Update reference to $INITRD in $BOOTCFG, making the kernel use the new
  # initrd after the next reboot.
  BOOTLDR_DIR=/boot
  BOOTCFG=$BOOTLDR_DIR/config.txt
  INITRD_PFX=initrd.img-
  INITRD=$INITRD_PFX$version
  
  case $1 in
      prereqs) echo; exit
  esac
  
  FROM="^ *\\(initramfs\\) \\+$INITRD_PFX.\\+ \\+\\(followkernel\\) *\$"
  INTO="\\1 $INITRD \\2"
  
  T=`umask 077 && mktemp --tmpdir genramfs_XXXXXXXXXX.tmp`
  trap "rm -- \"$T\"" 0
  
  sed "s/$FROM/$INTO/" "$BOOTCFG" > "$T"
  
  # Update file only if necessary.
  if ! cmp -s "$BOOTCFG" "$T"
  then
      cat "$T" > "$BOOTCFG"
  fi
  ```

Then make it executable:

```sh
chmod +x /etc/initramfs-tools/hooks/update_initrd
```

Note your kernel version. If there are multiple, choose the one you want to run:

```sh
ls /lib/modules/
```

Build the new initramdisk using the kernel version from above, and make the Raspberry boot from this ramdisk:

```sh
mkinitramfs -o /boot/initrd.img-5.15.61-v8+ "5.15.61-v8+"
echo "initramfs initrd.img-5.15.61-v8+ followkernel" >> /boot/config.txt
```

Customize headless setup and first run optimizations as they will error with and prevent booting:

```sh
sed -i 's/^main$/fix_wpa;regenerate_ssh_host_keys/g' /usr/lib/raspberrypi-sys-mods/firstboot
echo "pi:$6$Gpq1Y5a26F7cPIuL$VeIz04vCAZFE6RfFnH.BInFyiHp.pylFKzLYoVfDav1dCYAeUJqISZngIaQNcdr1SJfJWXbmBk7DftioULVYW0" > /boot/userconf.txt
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
kpartx -d "$PWD/pi-base.img"
kpartx -d "$PWD/pi-target.img"
```

You are now ready to flash `pi-target.img` to an SD card.

## On the Raspberry Pi

Boot the Raspberry Pi with the new SD card. It will obtain an IP address from the DHCP server and start listening for SSH connections. To decrypt the root partition and continue boot, from any shell, simply run `cryptroot-unlock`.

Once booted into the decrypted system, you will notice that the root partition is still sized at ~3GB, no matter how much space you have on the SD card. To fix this, resize the partition:

```sh
parted /dev/mmcblk0 resizepart 2 100%
cryptsetup resize crypted
resize2fs /dev/mapper/crypted
```

Finally, reboot the system for good measure:

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
- https://raspberrypi.stackexchange.com/questions/92557/how-can-i-use-an-init-ramdisk-initramfs-on-boot-up-raspberry-pi/
- https://www.raspberrypi.com/documentation/computers/configuration.html#setting-up-a-headless-raspberry-pi
