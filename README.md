# Raspberry Pi Encrypted Boot with SSH

> [!IMPORTANT]
> This guide is only tested on the [Raspberry Pi 5](https://www.raspberrypi.com/products/raspberry-pi-5/) with [Raspberry Pi OS Lite 64-bit 2026-04-21](https://www.raspberrypi.com/software/operating-systems/).
> Other platforms and distributions may work, but there may be unexpected issues or side effects.

## Introduction

This guide will show you how to encrypt your Raspberry Pi's root partition and set up an [initramfs](https://en.wikipedia.org/wiki/Initial_ramdisk) that will prompt for the password, decrypt the partition and gracefully resume boot. You will also learn how to enable SSH during this pre-boot stage, allowing you to unlock the partition remotely. There are also optional steps for WiFi setup.

This guide operates directly on an image file and therefore does not require an SD card for the setup. The resulting image can be flashed to an SD card as usual.

## Requirements

- A Raspberry Pi Linux image (e.g. [Raspberry Pi OS Lite 64-bit 2026-04-21](https://www.raspberrypi.com/software/operating-systems/))
- A computer (host) running Linux (e.g. [Kali Linux 2025.3](https://www.kali.org/get-kali/#kali-platforms))

> [!WARNING]
> Your host's Linux should be as similar as possible to the Raspberry Pi's Linux. If you are preparing Debian 13 (Trixie)/kernel 6.18 for the Raspberry Pi, use similar versions on the host, otherwise you may encounter issues inside the chroot.

## On the host

Install dependencies:

- You can skip `binfmt-support` and `qemu-user-static` if your host Linux's architecture matches that of the Raspberry Pi's Linux image.
- If your host Linux doesn't use systemd, such as WSL on Windows, you need to manually run `update-binfmts --enable` after installing `binfmt-support`.

```sh
apt update
apt install -y parted kpartx cryptsetup-bin rsync binfmt-support qemu-user-static
```

Create two copies of the Raspberry Pi's Linux image — one to read from (base), and one to write to (target):

- pi-base.img
- pi-target.img

Increase the size of the target image or you may run into issues:

```bash
dd if=/dev/zero bs=1G count=1 >> pi-target.img
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
loop0       7:0    0    3G  1 loop            # pi-base.img (readonly)
├─loop0p1 253:0    0  512M  1 part            # ├─ boot
└─loop0p2 253:1    0  2.5G  1 part            # └─ root
loop1       7:1    0    4G  0 loop            # pi-target.img
├─loop1p1 253:2    0  512M  0 part            # ├─ boot
└─loop1p2 253:3    0  3.5G  0 part            # └─ root
```

Mount the base image's root partition:

```sh
mkdir -p /mnt/original/
mount /dev/mapper/loop0p2 /mnt/original/
```

Replace the target image's root partition with a new, encrypted partition:

> [!WARNING]
> The default encryption algorithm is `aes-xts-plain64`, which is fast only on the Raspberry Pi 5 due to its hardware AES acceleration. If you have an older generation, then use [aes-adiantum](https://github.com/google/adiantum) instead via `-c xchacha20,aes-adiantum-plain64`. It is much faster than AES in software.

> [!CAUTION]
> By default cryptsetup will [benchmark](https://man7.org/linux/man-pages/man8/cryptsetup-luksformat.8.html) your host and choose a LUKS2 Argon2 memory cost between 64 MiB and 1 GiB for unlocking. If this exceeds your Raspberry Pi's available RAM, it can make the partition impossible to unlock. To work around this, set the memory cost in KiB via [--pbkdf-memory](https://man7.org/linux/man-pages/man8/cryptsetup-luksformat.8.html). You can also lower the thread count via [--pbkdf-parallel](https://man7.org/linux/man-pages/man8/cryptsetup-luksformat.8.html). For example: `--pbkdf-memory 512000 --pbkdf-parallel=1`

```sh
cryptsetup luksFormat /dev/mapper/loop1p2
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
mkdir -p /mnt/chroot/boot/firmware/
mount /dev/mapper/loop1p1 /mnt/chroot/boot/firmware/
mount -t proc none /mnt/chroot/proc/
mount -t sysfs none /mnt/chroot/sys/
mount -o bind /dev /mnt/chroot/dev/
mount -o bind /dev/pts /mnt/chroot/dev/pts/
```

Enter the chroot:

```sh
LANG=C chroot /mnt/chroot/ /bin/bash
```

## In the chroot

### Prepare

Install the dependencies and update the Raspberry Pi kernel. For Raspberry Pi 5, keep both the `2712` and `v8` kernel packages installed so you can choose between the 16K and 4K page-size kernels:

```sh
apt update
apt install -y busybox cryptsetup dropbear-initramfs xz-utils linux-image-rpi-2712 linux-image-rpi-v8
```

### Device configuration

Edit [/etc/fstab](https://linux.die.net/man/5/fstab) and replace the root entry with your decrypted (virtual) partition's device name:

```sh
# Original:
PARTUUID=e8af6eb2-02 / ext4 defaults,noatime          0 1
# Replace with:
/dev/mapper/crypted  / ext4 defaults,noatime          0 1
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

Edit `/boot/firmware/cmdline.txt` and update the root entry:

```sh
# Original:
root=PARTUUID=21e60f8c-02
# Replace with:
root=/dev/mapper/crypted cryptdevice=UUID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:crypted
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

Copy `xz` to the initramfs so kernel modules compressed as `.ko.xz` can be decompressed:

```sh
cat > /etc/initramfs-tools/hooks/xz << 'EOF'
#!/bin/sh
set -e

PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
    prereqs) prereqs; exit 0 ;;
esac

. /usr/share/initramfs-tools/hook-functions

copy_exec /usr/bin/xz
copy_exec /usr/lib/*-linux-gnu/liblzma.so.*
EOF
chmod 0755 /etc/initramfs-tools/hooks/xz
```

### SSH

Write your SSH public key inside Dropbear's initramfs `authorized_keys` and fix permissions. This key is only for the pre-boot SSH server used to unlock LUKS:

```sh
echo "/REDACTED/" > /etc/dropbear/initramfs/authorized_keys
chmod 0600 /etc/dropbear/initramfs/authorized_keys
```

### WiFi support

This step is optional. If you want the Raspberry Pi to be decryptable over WiFi, check out the guides below. Note that the differences between distros is very small, so you can easily adapt any particular guide.

#### Raspberry Pi OS

- [Wireless-USB2.md](Wireless-USB2.md)

#### Ubuntu (obsolete)

- [Wireless-Builtin.md](Wireless-Builtin.md)
- [Wireless-USB.md](Wireless-USB.md)

### Build initramfs


Note your kernel version. If there are multiple, choose the one you want to run. The `2712` suffix is for Raspberry Pi 5, while `v8` is for all previous generations:

```sh
ls /lib/modules/
```

Build the new initramdisk using the kernel version from above:

```sh
kversion="6.18.29+rpt-rpi-2712" # "6.18.29+rpt-rpi-v8" for 4K pages
mkinitramfs -o /boot/firmware/initramfs_2712 $kversion # "initramfs8" for 4K pages
```

### Cloud-init

Raspberry Pi OS now uses cloud-init for first-boot configuration. The image includes a NoCloud datasource configured in `/etc/cloud/cloud.cfg.d/99_raspberry-pi.cfg`, seeded from `/boot/firmware/`. For a non-interactive default user and key-only SSH login, edit `/boot/firmware/user-data`.

For example, this creates a `pi` user with sudo access, no usable password, and SSH key-only login. Replace `/REDACTED/` with your SSH public key:

```yaml
#cloud-config

hostname: pi-server
ssh_pwauth: false
disable_root: true

users:
  - name: pi
    gecos: Raspberry Pi
    groups: [adm, dialout, cdrom, audio, users, sudo, video, games, plugdev, input, gpio, spi, i2c, netdev, render, lpadmin]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - /REDACTED/

runcmd:
  - [ systemctl, enable, --now, ssh.service ]
```

You can validate the file from inside the chroot:

```sh
cloud-init schema --config-file /boot/firmware/user-data
```

### Legacy first-run

Raspberry Pi Imager's legacy first-run helper is still available for advanced cases that cloud-init does not cover. If needed, create `/boot/firmware/firstrun.sh`, for example:

```sh
#!/bin/bash
set +e

/usr/lib/userconf-pi/userconf # USERNAME [PASS_HASH]

/usr/lib/raspberrypi-sys-mods/imager_custom set_hostname # HOSTNAME
/usr/lib/raspberrypi-sys-mods/imager_custom import_ssh_id # USERID1 [USERID2]...
/usr/lib/raspberrypi-sys-mods/imager_custom enable_ssh # [-k|--key-only]|[-p|--pass-auth] [-d|--disabled] [KEY_LINE1 [KEY_LINE2]...]
/usr/lib/raspberrypi-sys-mods/imager_custom set_wlan # [-h|--hidden] [-p|--plain] SSID [PASS [COUNTRY]]
/usr/lib/raspberrypi-sys-mods/imager_custom set_wlan_country # COUNTRY
/usr/lib/raspberrypi-sys-mods/imager_custom set_keymap # KEYMAP
/usr/lib/raspberrypi-sys-mods/imager_custom set_timezone # TIMEZONE

rm -f /boot/firmware/firstrun.sh
sed -i 's| systemd.run.*||g' /boot/firmware/cmdline.txt
exit 0
```

Make sure the newly created file is executable:

```sh
chmod +x /boot/firmware/firstrun.sh
```

And finally append this to your `/boot/firmware/cmdline.txt`:

```bash
[...] systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target
```

### Finish


Sync and exit the chroot:

```sh
sync
history -c && exit
```

## On the host

Unmount everything and clean up any remaining artifacts:

```sh
umount /mnt/chroot/boot/firmware
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

Finally, reboot the system one last time for good measure:

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
