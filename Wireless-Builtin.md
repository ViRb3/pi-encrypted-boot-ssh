# WiFi Support

This guide will show you how to set up the Raspberry Pi's built-in WiFi module for use during initramfs. The steps here are intended for Ubuntu, slight changes will be necessary for Raspberry Pi OS.

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
  copy_modules_dir kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac
  # copy additional firmware files, ignoring error if they are already copied
  for f in /lib/firmware/brcm/brcmfmac*; do
  	copy_file firmware "$f" || true
  done

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
  # created by initramfs
  # for some reason it lists wlan0 as ethernet, which breaks netplan - remove it
  rm -f /run/netplan/wlan0.yaml
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
    wlan0:
      optional: true
      access-points:
        "Foo":
          password: "Bar"
      dhcp4: true
```

You're done! Follow the rest of the guide to finish building your initramfs.

## Resources

- https://gist.github.com/telenieko/d17544fc7e4b347beffa87252393384c
- https://morfikov.github.io/post/wsparcie-dla-wifi-w-initramfs-initrd-by-odszyfrowac-luks-przez-ssh-bezprzewodowo/
- https://morfikov.github.io/post/odszyfrowanie-luks-przez-ssh-z-poziomu-initramfs-initrd-na-raspberry-pi/
- https://github.com/endlessm/linux-firmware/tree/master/brcm
- https://forums.gentoo.org/viewtopic-t-1040452-start-0.html
- https://github.com/lamby/initramfs-tools/blob/pass-reproducible-option/hook-functions
- https://github.com/unixabg/cryptmypi/blob/master/hooks/0000-experimental-initramfs-wifi.hook
- https://askubuntu.com/questions/1250133/interface-ip-conflict-after-dropbear-initramfs-boot
