# FIDO2LUKS extended

An initramfs-tools extension to unlock LUKS encrypted volumes at boot time using a FIDO2 token (YubiKey, Nitrokey,...). Based on [`fido2luks`](https://github.com/bertogg/fido2luks) by Alberto Garcia.

`fido2luks-extended` is designed for scenarios where a FIDO2 token has been enrolled into a LUKS volume using `systemd-cryptenroll --fido2-device`, but SystemD itself is not used in the initramfs.

Updated script has support for Plymouth bootsplash, has multilingual support (currently English and Slovenian language) and can suppress technical/debug messages and shown only user-friendly output.

<img width="556" height="353" alt="image" src="https://github.com/user-attachments/assets/47e7e01f-b0ff-4fbe-a4d6-f766086c74f2" />

Script was tested with Yubikey 5 NFC and Nitrokey 3A Mini on Debian 13.4, however it should support any FIDO2 key.

To disable technical/debug messages (and show only messages suitable for non-technical users) change:

`FIDO2LUKS_DEBUG=${FIDO2LUKS_DEBUG:-1}`

to:

`FIDO2LUKS_DEBUG=${FIDO2LUKS_DEBUG:-0}`

Default language is English, you can change it to Slovenian:

`FIDO2LUKS_LANG=${FIDO2LUKS_LANG:-sl}`

## Installation

The most simple method is to run: `apt install ./fido2luks-extended_0.0.1_all.deb`.

If you prefer manual installation you can run:
```
mkdir -p /etc/initramfs-tools/hooks
mkdir -p /lib/fido2luks-extended
mkdir -p /usr/share/doc/fido2luks-extended

cp fido2luks-extended /etc/initramfs-tools/hooks/fido2luks-extended
cp keyscript.sh /lib/fido2luks-extended/keyscript.sh
cp README.md /usr/share/doc/fido2luks-extended/README.md

chmod 755 /etc/initramfs-tools/hooks/fido2luks-extended
chmod 755 /lib/fido2luks-extended/keyscript.sh
chmod 644 /usr/share/doc/fido2luks-extended/README.md

mkdir -p /usr/share/man/man8
gzip -9n -c fido2luks-extended.8 > /usr/share/man/man8/fido2luks-extended.8.gz
chmod 644 /usr/share/man/man8/fido2luks-extended.8.gz
```

## How to use it

⚠️ **Warning**: in theory, this can render your system unbootable, so make sure that you have a backup of your files or a working initramfs that you can use as a fallback in case things go wrong. In practice, I did not had any problems with this script, but you have been warned.

1. Install FIDO2 tools:
   ```
   apt install libfido2-dev libfido2-1 fido2-tools -y
   ```
   
2. Enroll your FIDO2 token into the LUKS volume, for example, if you have `/dev/nvme0n1p5` (so called "Encrypted LVM" on Debian):
  1. `systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=true --fido2-with-user-presence=true /dev/nvme0n1p5`
  2. After that, if you run `cryptsetup luksDump /dev/nvme0n1p5` you should be able to see the `systemd-fido2` token data.

3. Edit `/etc/crypttab` and add `keyscript=/lib/fido2luks-extended/keyscript.sh` to the options of the volume that you want to unlock (for instance `nvme0n1p5_crypt`):
   ```
   sed -i \
   '/^nvme0n1p5_crypt /{
     /keyscript=/! s#$#,keyscript=/lib/fido2luks-extended/keyscript.sh#
     s#keyscript=[^, ]*#keyscript=/lib/fido2luks-extended/keyscript.sh#
   }' \
   /etc/crypttab
   ```

4. Generate a new initramfs with `update-initramfs -u`.

That's it. Next time you boot the system, `fido2luks-extended` should detect if your FIDO2 token (security USB key) is inserted and use it to unlock the LUKS volume. If the token is not detected then it will fall back to using a regular passphrase as usual (called recovery passphrase).

If you have multiple tokens you can enroll all of them, and `fido2luks-extended` will detect which one to use at boot time.

If the token is connected but not detected during boot, make sure that the initramfs contains the necessary drivers. Check your `initramfs.conf` and set `MODULES=most` or add the necessary modules manually.

You can access man page with `man fido2luks-extended`.

## Some useful commands with your FIDO2 key

List currently connected FIDO tokens:
```
fido2-token -L
```

Get FIDO2 properties:
```
fido2-token -I /dev/hidraw1
```

Sets an initial FIDO2 PIN:
```
fido2-token -S /dev/hidraw1
```

Change the existing FIDO2 PIN:
```
fido2-token -C /dev/hidraw1
```

Check if FIDO2 PIN is set:
```
fido2-token -I /dev/hidraw1 | grep 'clientPin\|pin retries'
```

Sample output:
```
options: rk, up, noplat, credMgmt, clientPin, nolargeBlobs, pinUvAuthToken, makeCredUvNotRqd
pin retries: 8
```

- `clientPin`: FIDO2 PIN is configured
- `pin retries`: number of remaining PIN retries

## Important information about security

Using a FIDO2 security key with LUKS disk encryption significantly improves security. To unlock the disk, multiple factors are required:
- Something you have (the FIDO2 security key)
- Something you know (the PIN for your FIDO2 security key)
- User presence, confirmed by physically touching the key

Importantly, the PIN is verified inside the FIDO2 device itself, not by LUKS. The LUKS system never sees or stores the PIN.

However, security key can be lost, damaged, or unavailable. Also, there is a chance that kernel or initramfs updates may temporarily break FIDO2 support and in that case you will not be able to unlock the disk with FIDO2 security key. And finally, entering the wrong PIN too many times can lock the USB key.

And if the PIN becomes blocked and must be reset, the FIDO2 credentials stored on the device are typically erased. This means the associated LUKS key will no longer work.

For these reasons, it is strongly recommended to always keep a backup LUKS passphrase and, ideally, multiple FIDO2 keys (this script already supports multiple security USB keys and (multiple) LUKS passwords).

Best practice for high assurance would be:
- use 2–3 FIDO2 keys (different vendors if possible)
- strong LUKS passphrase stored securely (for instance printed and sealed somewhere)

## How this scipt works

If you are not interested in the technical details you can skip this section.

When SystemD enrolls a FIDO2 token into a LUKS volume it uses an extension called hmac-secret, supported by many hardware tokens.

In a nutshell, the token calculates an HMAC using a secret that never leaves the device and a salt provided by the user. The result is sent back to the user and is used to unlock the LUKS volume.

Since nothing is stored on the hardware token itself the user needs to provide some data that is kept on the LUKS header:
- A credential ID (previously generated during the enrollment process).
- A _relying party_ ID (`io.systemd.cryptsetup` in this case).
- The aforementioned salt (which should be random and different for each LUKS volume).
- Some settings such as whether to require a PIN or presence verification (usually physically touching the USB key).

Check out the scripts in the examples/ directory to see how to generate your own credentials and secrets. See also the `fido2-cred(1)` and `fido2-assert(1)` manpages for more details.

## Credits and license

Original  [`fido2luks`](https://github.com/bertogg/fido2luks) script was written by Alberto Garcia. `fido2luks-extended` with Plymouth bootsplash integration, multilingual support, support for managing debug messages, countdown for confirming physical presence, support for all usable SystemD/FIDO2 token records from the LUKS2 header and some security hardening was writen by Matej Kovačič.

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.

