# WiFi USB Support

This guide will show you how to set up a WiFi USB dongle for use during initramfs.

## Installing driver

The steps below are written for the [TP-LINK T4U](https://www.tp-link.com/uk/home-networking/adapter/archer-t4u/) USB dongle, which uses the Realtek RTL88x2B driver. As of Linux 5.15, this driver is not included in the kernel, so it needs to be built and installed manually. If your driver comes with your kernel, you can skip this step.

First, install [dkms](https://help.ubuntu.com/community/DKMS):

```bash
apt install dkms
```

Build your initramfs once to generate dependencies needed by dkms. Replace the kernel version if necessary (check `/usr/lib/modules/`):

```bash
mkinitramfs -o /boot/initrd.img "5.15.0-1005-raspi"
```

Prepare the driver:

```bash
git clone "https://github.com/RinCat/RTL88x2BU-Linux-Driver.git" /usr/src/rtl88x2bu-git
sed -i 's/PACKAGE_VERSION="@PKGVER@"/PACKAGE_VERSION="git"/g' /usr/src/rtl88x2bu-git/dkms.conf
dkms add -m rtl88x2bu -v git
```

By default, this driver's Makefile will use all of your CPU cores. This has the side effect of also using additional RAM, and if you're on a 1GB RAM device, it may run out of memory. To work around, disable the parallel build:

```bash
sed -i 's/-j$(nproc)//g' /usr/src/rtl88x2bu-git/dkms.conf
```

Build and install the driver:

```bash
dkms autoinstall -k "5.15.0-1005-raspi"
```

Finally, make the new driver load on boot in the decrypted OS:

```bash
echo "88x2bu.ko" >> /etc/modules-load.d/modules.conf 
```

## Set up initramfs

On Ubuntu 22.04, external (USB) WiFi dongles have a deterministic interface naming scheme that uses the device's MAC address, like: `wlx112233445566`. Replace the interface name with yours in the examples below.

Create the following files and customize them if necessary:

- `/etc/initramfs-tools/scripts/init-premount/a_enable_wireless`

  ```bash
  #!/bin/sh
  PREREQ=""
  prereqs()
  {
      echo "$PREREQ"
  }

  case $1 in
  prereqs)
      prereqs
      exit 0
      ;;
  esac

  sleep 1
  /sbin/wpa_supplicant -i wlx112233445566 -c /etc/wpa_supplicant.conf -P /run/initram-wpa_supplicant.pid -B
  ```

- `/etc/initramfs-tools/hooks/enable-wireless`

  ```bash
  #!/bin/sh
  set -e
  PREREQ=""
  prereqs()
  {
      echo "${PREREQ}"
  }
  case "${1}" in
      prereqs)
          prereqs
          exit 0
          ;;
  esac
  
  . /usr/share/initramfs-tools/hook-functions
  
  copy_exec /sbin/wpa_supplicant
  
  # copy WiFi driver
  manual_add_modules 88x2bu
  
  copy_file config /etc/initramfs-tools/wpa_supplicant.conf /etc/wpa_supplicant.conf
  ```
  
- `/etc/initramfs-tools/scripts/init-bottom/kill_wireless`

  ```bash
  #!/bin/sh
  PREREQ=""
  prereqs()
  {
      echo "$PREREQ"
  }

  case $1 in
  prereqs)
      prereqs
      exit 0
      ;;
  esac

  # allow the decrypted OS to handle WiFi on its own
  kill $(cat /run/initram-wpa_supplicant.pid)
  ip link set wlx112233445566 down
  # created by initramfs
  # for some reason it lists wlx112233445566 as ethernet, which breaks netplan - remove it
  rm -f /run/netplan/wlx112233445566.yaml
  ```

- `/etc/initramfs-tools/wpa_supplicant.conf`

  ```bash
  ctrl_interface=/tmp/wpa_supplicant
  country=GB
  
  network={
      ssid="Foo"
      scan_ssid=1
      psk="Bar"
      key_mgmt=WPA-PSK
  }
  ```

Chmod all scripts you just created:

```bash
chmod +x /etc/initramfs-tools/scripts/init-premount/a_enable_wireless
chmod +x /etc/initramfs-tools/hooks/enable-wireless
chmod +x /etc/initramfs-tools/scripts/init-bottom/kill_wireless
```

Set up WiFi for the decrypted OS. On Ubuntu, you do this by creating e.g. `/etc/netplan/10-user.yaml`:

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      optional: true
  wifis:
    wlx112233445566:
      optional: true
      access-points:
        "Foo":
          password: "Bar"
      dhcp4: true
```

You're done! Follow the rest of the guide to finish building your initramfs.

## Resources

- [Wireless-Builtin.md](Wireless-Builtin.md)
- https://github.com/RinCat/RTL88x2BU-Linux-Driver
