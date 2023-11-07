# WiFi USB Support

This guide will show you how to set up a WiFi USB dongle for use during initramfs. The steps here are intended for Raspberry Pi OS, slight changes will be necessary for Ubuntu.

## Installing driver

The steps below are written for the [Alfa AWUS036AXML](https://alfa-network.eu/alfa-usb-adapter-awus036axml) USB dongle, which uses the Mediatek MT7921AU driver. The driver is part of the Linux kernel starting from 6.1.

## Set up initramfs

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
  
  echo "Waiting for wlan device to come up..."
  while [ ! -d "/sys/class/net/wlan0" ]; do
      sleep 1
  done
  
  echo "Initializing wpa-supplicant..."
  /sbin/wpa_supplicant -i wlan0 -c /etc/wpa_supplicant.conf -P /run/initram-wpa_supplicant.pid -B
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
  manual_add_modules mt7921u
  
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
  echo "Stopping wlan device..."
  kill $(cat /run/initram-wpa_supplicant.pid)
  ip link set wlan0 down
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

Note that this will only set up WiFi in the initramfs. The decrypted OS needs to be configured separately.

Chmod all scripts you just created:

```bash
chmod +x /etc/initramfs-tools/scripts/init-premount/a_enable_wireless
chmod +x /etc/initramfs-tools/hooks/enable-wireless
chmod +x /etc/initramfs-tools/scripts/init-bottom/kill_wireless
```

You may want to disable onboard WiFi from the decrypted OS so it doesn't conflict with your external USB card:

```sh
echo "dtoverlay=disable-wifi" >> /boot/config.txt
```

You're done! Follow the rest of the guide to finish building your initramfs.

## Resources

- [Wireless-Builtin.md](Wireless-Builtin.md)
- https://github.com/morrownr/USB-WiFi/blob/main/home/USB_WiFi_Adapters_that_are_supported_with_Linux_in-kernel_drivers.md
