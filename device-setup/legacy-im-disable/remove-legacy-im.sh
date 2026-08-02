#!/bin/sh
# remove-legacy-im.sh -- fully remove the DEFUNCT AOL/AIM and Yahoo! stacks from webOS
# (TouchPad / topaz). Mirrors device-setup/skype-disable/remove-skype.sh exactly.
#
# AOL Instant Messenger shut down in 2017; Yahoo! Messenger shut down in 2018 (Yahoo!'s
# IM/Contacts/Calendar sync backends are dead well before that). The stock image still ships
# both full Synergy stacks: AOL rides the shared imlibpurple/imaccountvalidator infrastructure
# (com.palm.aol account + com.palm.imaccountvalidator validator service, both otherwise unused --
# every connector this repo ships uses its own customUI instead); Yahoo! has its own dedicated
# closed-source IM transport (imyahootransport) PLUS separate Contacts and Calendar sync services
# (yahoo-service, com.palm.service.contacts.yahoo, com.palm.service.calendar.yahoo) -- none of
# which route through libpurple at all.
#
# This removes: the launch path (D-Bus services, LS2 roles, the imyahoo db8-watch activity), the
# db8 kinds + permissions (com.palm.*.yahoo / com.palm.imyahoo / com.palm.contact.imyahoo, com.palm
# .yahoo.authservice), the account templates (com.palm.aol, com.palm.yahoo), the service directories,
# and the binaries (imaccountvalidator, imyahootransport, yahoo-service).
#
# Deliberately NOT touched (out of scope, low value, some risk): the AOL/Yahoo trusted root CA
# certs under /etc/ssl/certs/trustedcerts (harmless unused trust anchors), the shared framework
# icon assets under /usr/palm/frameworks/mojo* (aol-*.png / yahoo-*.png -- generic image bundles,
# not worth the risk of an unexpected shared-path reference), ipkg's own package bookkeeping under
# /usr/lib/ipkg/info (package-manager metadata, not consulted at runtime), the one-time
# 012-yahooimtransport-imcontact-fixup.js migration script (already ran, inert), and
# /usr/palm/data/com.palm.service.contacts.yahoo (possible user data, same "never touch data"
# principle as skype-disable's own scope).
#
# NON-DESTRUCTIVE by default: everything is MOVED to $BAK (a single tree preserving relative
# paths), nothing is deleted, so it is fully reversible. Idempotent. Run on-device with the
# rootfs writable:
#     mount -o remount,rw / ; sh /media/internal/remove-legacy-im.sh
# Reboot afterwards so the accounts service drops the cached templates and the activity manager
# deregisters the (now file-less) imyahoo activity. The registered db8 kinds are left in the store
# but are inert; a re-flash of an image built with this patch applied never registers them.

BAK=/var/legacy-im-disabled-backup

# move <absolute path> -> mirror it under $BAK (creating parent dirs). No-op if it doesn't exist.
move() {
    src="$1"
    [ -e "$src" ] || return 0
    dst="$BAK$src"
    mkdir -p "$(dirname "$dst")"
    mv -f "$src" "$dst" && echo "moved $src"
}

# 1. AOL/AIM -- rides the shared imlibpurple bridge; imaccountvalidator is the generic
#    username/password validator whose ONLY stock consumer is com.palm.aol (every connector this
#    repo ships uses its own customUI instead, confirmed by grep across every account template).
move /usr/palm/public/accounts/com.palm.aol
move /usr/bin/imaccountvalidator
move /usr/share/ls2/roles/prv/com.palm.imaccountvalidator.json
move /usr/share/dbus-1/system-services/com.palm.imaccountvalidator.service

# 2. Yahoo! IM (its own dedicated transport, NOT libpurple-based).
move /usr/bin/imyahootransport
move /usr/share/ls2/roles/prv/com.palm.imyahoo.json
move /usr/share/dbus-1/system-services/com.palm.imyahoo.service
move /etc/palm/activities/com.palm.imyahoo
move /etc/palm/db/kinds/com.palm.imcommand.yahoo
move /etc/palm/db/kinds/com.palm.imloginstate.yahoo
move /etc/palm/db/kinds/com.palm.immessage.yahoo
move /etc/palm/db/kinds/com.palm.contact.imyahoo
move /etc/palm/tempdb/kinds/com.palm.imbuddystatus.yahoo

# 3. Yahoo! Contacts sync.
move /usr/palm/services/com.palm.service.contacts.yahoo
move /usr/share/ls2/roles/prv/com.palm.service.contacts.yahoo.json
move /usr/share/ls2/roles/pub/com.palm.service.contacts.yahoo.json
move /usr/share/dbus-1/system-services/com.palm.service.contacts.yahoo.service
move /etc/palm/db/kinds/com.palm.contact.yahoo
move /etc/palm/db/kinds/com.palm.contact.transport.yahoo
move /etc/palm/db/kinds/com.palm.account.contacts.yahoo
move /etc/palm/db/permissions/com.palm.contact.yahoo
move /etc/palm/db/permissions/com.palm.contact.transport.yahoo
move /etc/palm/db/permissions/com.palm.account.contacts.yahoo

# 4. Yahoo! Calendar sync.
move /usr/palm/services/com.palm.service.calendar.yahoo
move /usr/share/ls2/roles/prv/com.palm.service.calendar.yahoo.json
move /usr/share/ls2/roles/pub/com.palm.service.calendar.yahoo.json
move /usr/share/dbus-1/system-services/com.palm.service.calendar.yahoo.service
move /etc/palm/db/kinds/com.palm.calendar.yahoo
move /etc/palm/db/kinds/com.palm.calendarevent.yahoo
move /etc/palm/db/kinds/com.palm.calendar.transport.yahoo
move /etc/palm/db/kinds/com.palm.calendarevent.transport.yahoo
move /etc/palm/db/kinds/com.palm.account.calendar.yahoo
move /etc/palm/db/permissions/com.palm.calendar.yahoo
move /etc/palm/db/permissions/com.palm.calendarevent.yahoo

# 5. Yahoo! master/auth service + account template.
move /usr/bin/yahoo-service
move /usr/share/ls2/roles/prv/com.palm.yahoo.json
move /usr/share/dbus-1/system-services/com.palm.yahoo.service
move /etc/palm/db/kinds/com.palm.yahoo.authservice
move /usr/palm/public/accounts/com.palm.yahoo

# 6. Orphaned oscar/AIM/ICQ libpurple plugins + redundant SSL backends. Confirmed dead two ways:
#    (a) with com.palm.aol gone (step 1), nothing anywhere references type_aim/type_icq or
#        prpl-aim/prpl-icq any more (no other stock or shipped-connector account ever did); and
#    (b) libpurple's own plugin.c rejects any plugin whose baked-in major_version doesn't match
#        PURPLE_MAJOR_VERSION (2) of the engine that now owns /usr/lib -- these were built against
#        webOS's ancient pre-2.0 libpurple, so they'd be silently skipped even if left in place.
#    ssl-gnutls.so/ssl-nss.so are likewise orphaned: nothing in this repo uses anything but
#    ssl-openssl.so, confirmed by grep.
#    NOT touched: libjabber.so/libxmpp.so (prpl-jabber). com.palm.google's MESSAGING capability
#    (com.palm.google.talk, not hidden) maps type_gtalk -> prpl-jabber (see imlibpurpleservice's
#    LibpurpleAdapter.cpp) -- Google's XMPP chat servers are long dead, but that account template
#    is very much alive (Mail/Contacts/Calendar/Documents), so removing its IM plugin risks an
#    uglier failure mode on an account type people still use daily. Left alone on purpose.
move /usr/lib/purple-2/libaim.so
move /usr/lib/purple-2/libicq.so
move /usr/lib/purple-2/liboscar.so
move /usr/lib/purple-2/liboscar.so.0
move /usr/lib/purple-2/liboscar.so.0.0.0
move /usr/lib/purple-2/ssl-gnutls.so
move /usr/lib/purple-2/ssl-nss.so

# 7. Stop anything already running (graceful SIGTERM; safe to signal).
for p in imyahootransport yahoo-service imaccountvalidator; do
    pkill -TERM -f "/usr/bin/$p" 2>/dev/null && echo "stopped: $p"
done

echo "AOL/AIM + Yahoo! fully removed (moved to $BAK). Reboot to drop cached templates + the imyahoo activity. rm -rf $BAK to reclaim the space permanently."
