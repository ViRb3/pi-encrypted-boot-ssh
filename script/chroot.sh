#! /bin/bash
set -e

# the original resolv.conf isn't valid in a chroot so we make a backup and change it to something that does work
mv /etc/resolv.conf /etc/resolv.conf.bak
echo "nameserver 1.1.1.1" > /etc/resolv.conf

apt update
apt install -y busybox cryptsetup dropbear-initramfs

# the below handles drive mapping so that the encrypted partition is mounted correctly at boot
echo "/dev/mapper/crypted /               ext4  discard,errors=remount-ro 0 1
LABEL=system-boot   /boot/firmware  vfat  defaults                  0 1" > /etc/fstab

ENCRYPTED_PARTITION_UUID=$(blkid | grep LUKS | grep loop | grep -o -E ' UUID=[^ ]+' | sed -e 's/UUID=//'  -e 's/^ "//' -e 's/"$//')

echo "crypted UUID=$ENCRYPTED_PARTITION_UUID none luks,initramfs" > /etc/crypttab

echo "root=/dev/mapper/crypted cryptdevice=UUID=$ENCRYPTED_PARTITION_UUID:crypted" > /boot/cmdline.txt

# add a hook for initramfs to configure crypt setup
echo "CRYPTSETUP=y" >> /etc/cryptsetup-initramfs/conf-hook

# there's an issue where partitions aren't mapped correctly without this patch
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

# add the provided public key to dropbear's authorized keys
cat id_rsa.pub > /etc/dropbear-initramfs/authorized_keys
chmod 0600 /etc/dropbear-initramfs/authorized_keys

# configure dropbear
sed -i 's/#DROPBEAR_OPTIONS=/DROPBEAR_OPTIONS="-p 22222 -I 60 -sjk"/' /etc/dropbear-initramfs/config

# make the initramfs
mkinitramfs -v -o /boot/initrd.img "$(ls /lib/modules/)"

# clean up & exit
mv /etc/resolv.conf.bak /etc/resolv.conf
sync
history -c && exit
