#!/bin/sh
# remove-skype.sh -- fully remove the DEFUNCT Skype stack from webOS (TouchPad / topaz).
#
# Skype's backend was shut down years ago; the stock image still ships a Skype mediator (skypem) +
# SkypeKit engine that get woken on demand via the com.palm.skype LS2/D-Bus service and db8-watch
# activities, plus a full set of Skype db8 kinds, an account template and the com.palm.app.skype app --
# all dead weight (CPU/RAM/power/rootfs space) for a service that can never connect.
#
# This removes ALL of it: the launch path (D-Bus services, activities, skypekit upstart jobs, LS2
# roles), the db8 kinds + permissions (com.palm.skype/* under db and tempdb), the account template,
# the com.palm.app.skype app, and the binaries (skypem, skypevalidator, the SkypeKit engine, the gst
# plugin, /var/skypekit).
#
# NON-DESTRUCTIVE by default: everything is MOVED to $BAK (a single tree preserving relative paths),
# nothing is deleted, so it is fully reversible and frees the read-only rootfs (the backup lives on
# the writable /var partition). Once you are happy it is gone for good you can `rm -rf $BAK`.
# Idempotent. Run on-device with the rootfs writable:
#     mount -o remount,rw / ; sh /media/internal/remove-skype.sh
# Reboot afterwards so the accounts service drops the cached Skype template and the activity manager
# deregisters the (now file-less) Skype activities. The registered db8 kinds are left in the store but
# are inert (no Skype service, template or data references them); a re-flash of an image built with
# this patch applied never registers them in the first place.

BAK=/var/skype-disabled-backup

# move <absolute path> -> mirror it under $BAK (creating parent dirs). No-op if it doesn't exist.
move() {
    src="$1"
    [ -e "$src" ] || return 0
    dst="$BAK$src"
    mkdir -p "$(dirname "$dst")"
    mv -f "$src" "$dst" && echo "moved $src"
}

# 1. Launch path: D-Bus services (Exec skypem/skypevalidator), db8-watch activities, skypekit upstart
#    jobs, LS2 roles.
move /usr/share/dbus-1/system-services/com.palm.skype.service
move /usr/share/dbus-1/system-services/com.palm.skypevalidator.service
move /etc/palm/activities/com.palm.skype
move /etc/palm/activities/com.palm.skypevalidator
move /etc/event.d/skypekit
move /etc/event.d/skypekit-offport
move /usr/share/ls2/roles/prv/com.palm.skype.json
move /usr/share/ls2/roles/prv/com.palm.skypevalidator.json

# 2. db8 kinds + permissions (the com.palm.skype dirs hold com.palm.*.skypem:1 kinds; both db + tempdb).
move /etc/palm/db/kinds/com.palm.skype
move /etc/palm/db/permissions/com.palm.skype
move /etc/palm/tempdb/kinds/com.palm.skype
move /etc/palm/tempdb/permissions/com.palm.skype

# 3. Account template + the Skype app (so Accounts no longer offers "Skype" and the app is gone).
move /usr/palm/public/accounts/com.palm.skype
move /usr/palm/applications/com.palm.app.skype

# 4. Binaries, SkypeKit engine + runtime dir.
move /usr/bin/skypem
move /usr/bin/skypevalidator
move /usr/bin/linux-armv7-skypekit-voicepcm-videortp
move /var/skypekit
# DO NOT move /usr/lib/gstreamer-0.10/libpalmgstskype.so despite the name: Teams, tdlib-purple
# (Telegram) and the combined WhatsApp/Facebook plugin all have a hard ELF NEEDED on it (confirmed
# via `readelf -d`) AND an RPATH of exactly /usr/lib/gstreamer-0.10 baked into each -- they reuse
# its H.264/media glue code for their own calling features, unrelated to actual Skype. A missing
# NEEDED library fails that plugin's entire dlopen (same failure class as a truncated libopus.so.0
# elsewhere in this repo), silently breaking Teams/Telegram/WhatsApp messaging, not just calling.
# Confirmed on-device: this file was moved by an earlier run of this script and had to be manually
# restored from $BAK afterward -- leave it in place.

# 5. Stop anything already running (graceful SIGTERM; these are safe to signal).
for p in /usr/bin/skypem linux-armv7-skypekit-voicepcm-videortp /usr/bin/skypevalidator; do
    pkill -TERM -f "$p" 2>/dev/null && echo "stopped: $p"
done

echo "Skype fully removed (moved to $BAK). Reboot to drop cached template + activities. rm -rf $BAK to reclaim the space permanently."
