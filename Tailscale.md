# Tailscale Support

This guide shows how to add Tailscale to the initramfs so that its Dropbear SSH server can be reached through your tailnet. Complete the main guide through the [SSH section](README.md#ssh), then perform these steps inside the chroot before building the initramfs.

Tailscale still needs ordinary internet connectivity first. Ethernet uses the initramfs DHCP setup; WiFi also requires one of the [WiFi guides](README.md#wifi-support).

> [!IMPORTANT]
> Use a separate Tailscale identity for the initramfs. Do not copy `/var/lib/tailscale/tailscaled.state` from the decrypted system. Running two daemons from the same state can cause identity and key-rotation problems.

> [!CAUTION]
> The Tailscale state is a device credential and will be embedded in the unencrypted initramfs on the boot partition. Anyone who can read or clone that partition can impersonate this node until you remove it from the tailnet. Use a dedicated tag with a narrowly scoped access policy, protect the SD card physically, and remove the node from the Tailscale admin console if the card or image is lost.

## Configure tailnet access

In the Tailscale admin console, create a tag such as `tag:initramfs` and permit only trusted users or devices to reach TCP port 22 on that tag. Remember that Tailscale grants are additive, so an existing broad grant may still give other tailnet members access. A minimal policy fragment could look like this; merge it into your existing policy rather than replacing it:

```json
{
  "groups": {
    "group:unlockers": ["you@example.com"]
  },
  "tagOwners": {
    "tag:initramfs": ["group:unlockers"]
  },
  "grants": [
    {
      "src": ["group:unlockers"],
      "dst": ["tag:initramfs"],
      "ip": ["tcp:22"]
    }
  ]
}
```

Create a **one-off, non-ephemeral, tagged** auth key for `tag:initramfs`. If your tailnet uses device approval, make it pre-approved as well. A tagged node has key expiry disabled by default; otherwise, explicitly disable key expiry for this node after it is registered. Do not use a reusable or ephemeral key for the setup below.

## Install Tailscale

Install Tailscale from its official Debian 13 (Trixie) repository:

```sh
apt install -y ca-certificates curl
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
  | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
  | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
apt update
apt install -y tailscale
```

## Provision the initramfs identity

The temporary daemon uses userspace networking only for enrollment inside the chroot. The initramfs will use the kernel TUN interface so Dropbear can listen on the Tailscale address. Replace the hostname if desired:

```bash
install -d -m 0700 /etc/initramfs-tools/tailscale /run/tailscale-enroll

/usr/sbin/tailscaled \
  --tun=userspace-networking \
  --state=/etc/initramfs-tools/tailscale/tailscaled.state \
  --statedir=/run/tailscale-enroll \
  --socket=/run/tailscale-enroll/tailscaled.sock \
  --encrypt-state=false \
  >/tmp/tailscale-enroll.log 2>&1 &
tailscaled_pid=$!

while [ ! -S /run/tailscale-enroll/tailscaled.sock ]; do
  kill -0 "$tailscaled_pid" 2>/dev/null \
    || { echo "tailscaled exited, see /tmp/tailscale-enroll.log" >&2; break; }
  sleep 1
done
read -rsp "One-off Tailscale auth key: " TS_AUTHKEY; echo
/usr/bin/tailscale --socket=/run/tailscale-enroll/tailscaled.sock up \
  --auth-key="$TS_AUTHKEY" \
  --hostname=pi-initramfs \
  --advertise-tags=tag:initramfs \
  --accept-dns=false \
  --netfilter-mode=off
unset TS_AUTHKEY

/usr/bin/tailscale --socket=/run/tailscale-enroll/tailscaled.sock status
kill "$tailscaled_pid"
wait "$tailscaled_pid" || true
chmod 0600 /etc/initramfs-tools/tailscale/tailscaled.state
rm -rf /run/tailscale-enroll /tmp/tailscale-enroll.log
```

The one-off auth key is invalid after enrollment and is not copied into the image. The resulting state file is copied instead. Record the node's stable Tailscale IPv4 address from the admin console, or use its MagicDNS name, normally `pi-initramfs.<your-tailnet>.ts.net`.

## Add Tailscale to the initramfs

Create a hook that copies Tailscale, its state and the TUN driver:

```sh
cat > /etc/initramfs-tools/hooks/tailscale << 'EOF'
#!/bin/sh
set -e

PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
    prereqs) prereqs; exit 0 ;;
esac

. /usr/share/initramfs-tools/hook-functions

copy_exec /usr/bin/tailscale
copy_exec /usr/sbin/tailscaled
copy_file config /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
copy_file config /etc/initramfs-tools/tailscale/tailscaled.state /etc/tailscale/tailscaled.state
manual_add_modules tun
EOF
chmod 0755 /etc/initramfs-tools/hooks/tailscale
```

Start Tailscale after Dropbear has initiated the normal initramfs network configuration. The daemon will keep retrying while DHCP or WiFi finishes connecting:

```sh
cat > /etc/initramfs-tools/scripts/init-premount/tailscale << 'EOF'
#!/bin/sh

PREREQ="dropbear"
prereqs() { echo "$PREREQ"; }
case "$1" in
    prereqs) prereqs; exit 0 ;;
esac

modprobe tun || echo "tailscale: could not load tun module" >&2
mkdir -p /dev/net /run/tailscale /var/lib/tailscale
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
fi

echo "Starting Tailscale for initramfs..."
/usr/sbin/tailscaled \
    --state=/etc/tailscale/tailscaled.state \
    --statedir=/var/lib/tailscale \
    --socket=/run/tailscale/tailscaled.sock \
    --encrypt-state=false \
    >/run/tailscale/tailscaled.log 2>&1 &
echo $! >/run/tailscale/tailscaled.pid
EOF
chmod 0755 /etc/initramfs-tools/scripts/init-premount/tailscale
```

Finally, stop the initramfs daemon before switching to the decrypted root filesystem:

```sh
cat > /etc/initramfs-tools/scripts/init-bottom/tailscale << 'EOF'
#!/bin/sh

PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
    prereqs) prereqs; exit 0 ;;
esac

if [ -r /run/tailscale/tailscaled.pid ]; then
    pid="$(cat /run/tailscale/tailscaled.pid)"
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
fi
EOF
chmod 0755 /etc/initramfs-tools/scripts/init-bottom/tailscale
```

Tailscale requires a reasonably correct system clock for its encrypted control connections. The Raspberry Pi 5 has a hardware RTC; for reliable cold boots after long power outages, fit an RTC battery and verify the clock is retained. If Tailscale does not appear online, connect through the LAN address or console and inspect `/run/tailscale/tailscaled.log` from the initramfs shell.

Installing the package does not enroll the decrypted operating system: the initramfs state above is deliberately separate. After the first unlock, run `sudo tailscale up` in the normal OS if you also want Tailscale there, and give it a different hostname such as `pi-server`.

## Build and verify

Return to the main guide and [build the initramfs](README.md#build-initramfs). Then verify that the Tailscale binaries, state and TUN module were included:

```sh
# "initramfs8" for 4K pages
lsinitramfs /boot/firmware/initramfs_2712 \
  | grep -E '(^usr/(bin/tailscale|sbin/tailscaled)$|tailscaled\.state$|tun\.ko)'
```

## Unlock over Tailscale

Boot the Raspberry Pi and allow a short time for `pi-initramfs` to appear online. Connect using its MagicDNS name or Tailscale IP:

```sh
ssh root@pi-initramfs
```

From the SSH shell, unlock the root partition and resume boot:

```sh
cryptroot-unlock
```

## Resources

- https://tailscale.com/docs/features/access-control/auth-keys
- https://tailscale.com/docs/concepts/userspace-networking
- https://tailscale.com/docs/reference/tailscaled
- https://tailscale.com/docs/reference/netfilter-modes
