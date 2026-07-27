#!/bin/sh
# provision-cdav-db.sh   (runs ON the device)
#
# Register the C+DAV connector's db8 kinds + permissions. The kinds EXTEND the native
# com.palm.contact / com.palm.calendar / com.palm.calendarevent kinds, so anything the
# connector syncs shows up directly in the stock Contacts and Calendar apps.
#
# putKind and putPermissions are OWNER-scoped: each must be called as the kind's declared
# owner (org.webosports.service.cdav) or db8 returns -3963 (permission denied). Idempotent --
# safe to re-run. luna-send in a novacom shell never prints the reply; check side effects.
#
# Kind/permission files are expected in /etc/palm/db/{kinds,permissions} (deploy-cdav.sh puts
# them there so the configurator also re-applies them across reboots).

DBK=/etc/palm/db/kinds
DBP=/etc/palm/db/permissions
FAIL=0

# Order matters a little: parents/plain kinds before the ones that reference them is not
# required for putKind (db8 resolves extends lazily), but we register account/config kinds
# first, then the PIM kinds.
for k in \
    org.webosports.cdav.account.config \
    org.webosports.cdav.account.contacts \
    org.webosports.cdav.account.calendar \
    org.webosports.cdav.contactset \
    org.webosports.cdav.contact \
    org.webosports.cdav.calendar \
    org.webosports.cdav.calendarevent ; do
    f="$DBK/$k"
    [ -f "$f" ] || { echo "MISSING kind $f"; FAIL=1; continue; }
    owner=$(grep '"owner"' "$f" | head -1 | sed 's/.*: *"//; s/".*//')
    [ -n "$owner" ] || owner=org.webosports.service.cdav
    echo "putKind $k (owner $owner)"
    luna-send -i -n 1 -a "$owner" -f palm://com.palm.db/putKind "$(cat "$f")" </dev/null || FAIL=1
done

for p in \
    org.webosports.cdav.account.config \
    org.webosports.cdav.account.contacts \
    org.webosports.cdav.account.calendar \
    org.webosports.cdav.contactset \
    org.webosports.cdav.contact \
    org.webosports.cdav.calendar \
    org.webosports.cdav.calendarevent ; do
    f="$DBP/$p"
    [ -f "$f" ] || { echo "MISSING perm $f"; FAIL=1; continue; }
    owner=$(grep '"owner"' "$DBK/$p" 2>/dev/null | head -1 | sed 's/.*: *"//; s/".*//')
    [ -n "$owner" ] || owner=org.webosports.service.cdav
    echo "putPermissions $p (owner $owner)"
    luna-send -i -n 1 -a "$owner" -f palm://com.palm.db/putPermissions "{\"permissions\":$(cat "$f")}" </dev/null || FAIL=1
done

echo "provision-cdav-db: done (FAIL=$FAIL)."
exit $FAIL
