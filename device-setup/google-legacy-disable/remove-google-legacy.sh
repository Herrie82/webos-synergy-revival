#!/bin/sh
# remove-google-legacy.sh -- fully remove the DEFUNCT stock "com.palm.google" Synergy stack from
# webOS (TouchPad / topaz). Mirrors device-setup/skype-disable and device-setup/legacy-im-disable
# exactly (same non-destructive move pattern).
#
# The stock com.palm.google account (2011-era) offers five capabilities, all now dead:
#   - MESSAGING/IM (com.palm.google.talk, serviceName type_gtalk -> prpl-jabber): Google Talk's
#     XMPP chat servers shut down years ago.
#   - CONTACTS (com.palm.service.contacts.google) and CALENDAR (com.palm.service.calendar.google):
#     both use Google's old ClientLogin-era sync APIs, deprecated/shut down long ago in favor of
#     OAuth2 + modern REST APIs the stock 2011 image never speaks.
#   - MAIL (com.palm.google.mail): rides the SHARED com.palm.imap service (generic IMAP/SMTP)
#     with imap.gmail.com/smtp.gmail.com pre-filled. Google removed "less secure app access"
#     (plain username+password IMAP) in 2022 -- this can no longer authenticate either.
#   - DOCUMENTS (com.palm.google.documents): a bare capability declaration with no implementation
#     at all, already inert. This repo's own cloud/gdrive (com.palm.gdrive, modern OAuth2+PKCE) is
#     the actual, working replacement -- a completely separate account template, no relation.
#
# This removes: the account template (com.palm.google), the Contacts + Calendar service
# directories, their LS2 roles + D-Bus services, their db8 kinds + permissions, and -- now that
# nothing references type_gtalk/prpl-jabber any more -- the now-orphaned libjabber.so/libxmpp.so
# libpurple plugins (deliberately kept by device-setup/legacy-im-disable specifically because this
# account template was still alive; see that package's README for the full reasoning trail).
#
# NOT touched: com.palm.imap (the service/role/D-Bus/kind backing the generic "IMAP" account
# type) -- Google's MAIL capability only reuses it with Gmail's hostnames pre-filled, it has no
# Google-specific service of its own, and the standalone IMAP account type is still genuinely
# useful. Also not touched: the immessage/imcommand.libpurple:1 kinds (shared with every connector
# this repo ships) and imlibpurple itself -- Google Talk's capabilityProvider entry disappears
# along with the whole account template, no separate kind ever existed for it.
#
# NON-DESTRUCTIVE by default: everything is MOVED to $BAK (a single tree preserving relative
# paths), nothing is deleted, so it is fully reversible. Idempotent. Run on-device with the
# rootfs writable:
#     mount -o remount,rw / ; sh /media/internal/remove-google-legacy.sh
# Reboot afterwards so the accounts service drops the cached template. The registered db8 kinds
# are left in the store but are inert; a re-flash of an image built with this patch applied never
# registers them.

BAK=/media/cryptofs/google-legacy-disabled-backup

# move <absolute path> -> mirror it under $BAK (creating parent dirs). No-op if it doesn't exist.
move() {
    src="$1"
    [ -e "$src" ] || return 0
    dst="$BAK$src"
    mkdir -p "$(dirname "$dst")"
    mv -f "$src" "$dst" && echo "moved $src"
}

# move_symlink <absolute path> -> just delete it (confirmed on a real device: /media/cryptofs
# cannot hold symlinks at all, failing safely with the source left in place). Nothing meaningful
# to back up anyway: the real target file is moved separately under its own name. Idempotent.
move_symlink() {
    [ -L "$1" ] && rm -f "$1" && echo "removed symlink $1"
    return 0
}

# 1. Contacts sync.
move /usr/palm/services/com.palm.service.contacts.google
move /usr/share/ls2/roles/prv/com.palm.service.contacts.google.json
move /usr/share/ls2/roles/pub/com.palm.service.contacts.google.json
move /usr/share/dbus-1/system-services/com.palm.service.contacts.google.service
move /etc/palm/db/kinds/com.palm.contact.google
move /etc/palm/db/kinds/com.palm.contact.transport.google
move /etc/palm/db/kinds/com.palm.account.contacts.google
move /etc/palm/db/permissions/com.palm.contact.google
move /etc/palm/db/permissions/com.palm.contact.transport.google
move /etc/palm/db/permissions/com.palm.account.contacts.google

# 2. Calendar sync.
move /usr/palm/services/com.palm.service.calendar.google
move /usr/share/ls2/roles/prv/com.palm.service.calendar.google.json
move /usr/share/ls2/roles/pub/com.palm.service.calendar.google.json
move /usr/share/dbus-1/system-services/com.palm.service.calendar.google.service
move /etc/palm/db/kinds/com.palm.calendar.google
move /etc/palm/db/kinds/com.palm.calendarevent.google
move /etc/palm/db/kinds/com.palm.calendar.transport.google
move /etc/palm/db/kinds/com.palm.calendarevent.transport.google
move /etc/palm/db/kinds/com.palm.account.calendar.google
move /etc/palm/db/permissions/com.palm.calendar.google
move /etc/palm/db/permissions/com.palm.calendarevent.google

# 3. The account template itself. (MAIL rides the shared com.palm.imap service -- untouched --
#    and IM/DOCUMENTS have no dedicated kind/service of their own; removing the template is enough.)
move /usr/palm/public/accounts/com.palm.google

# 4. Now-orphaned Jabber/XMPP libpurple plugin (prpl-jabber). This account template's
#    type_gtalk/com.palm.google.talk capability (step 3) was the last remaining consumer -- see
#    device-setup/legacy-im-disable/README.md for the full trail of why it was kept until now.
move_symlink /usr/lib/purple-2/libjabber.so
move_symlink /usr/lib/purple-2/libjabber.so.0
move /usr/lib/purple-2/libjabber.so.0.0.0
move /usr/lib/purple-2/libxmpp.so

echo "Legacy Google account (Contacts/Calendar/Talk) fully removed (moved to $BAK). Reboot to drop the cached template. rm -rf $BAK to reclaim the space permanently."
