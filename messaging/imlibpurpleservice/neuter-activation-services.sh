#!/bin/sh
# neuter-activation-services.sh
#
# Disable the on-demand LS2/DBus ACTIVATION services for the IM transport so ONLY the upstart-resident
# daemon ever runs. Run after any deploy that (re)installs these files; a reboot is needed afterwards
# for ls-hubd to drop them from its cached service catalog.
#
# WHY: imlibpurpletransport is meant to run as a single RESIDENT daemon, started by upstart via
# /var/imdaemon.sh (which exports IM_RESIDENT=1 so it does NOT self-terminate on idle). But several
# DBus activation .service files also name it:
#   com.palm.imlibpurple.service        (Exec=imlibpurpleservice, the main one)
#   com.palm.{whatsapp,telegram,signal}.call.service  (Exec=imlibpurpletransport, for VoIP)
# When any client calls one of these bus names while the resident transport is briefly busy or
# mid-(re)register, ls-hubd ACTIVATES the .service and spawns a SECOND, non-resident transport. That
# second process collides with the resident one:
#   LunaService-CRITICAL: Attempted to register for a service name that already exists: com.palm.imlibpurple
# and dies. Under load this churns 100+ collisions per boot and prevents accounts from STAYING online
# (they log in, then the churn knocks them off). Voice calling does NOT need the .call activation
# services — the resident transport registers com.palm.whatsapp.call itself (in-plugin, glue/call.c),
# so these are pure liability. Neuter them; upstart is the only launch path.
#
# NEVER kill -9 the transport (corrupts the PmLog init semaphore) — SIGTERM / stop imtransport only.

set -e
DBS=/usr/share/dbus-1/system-services
SERVICES="com.palm.imlibpurple.service com.palm.whatsapp.call.service com.palm.telegram.call.service com.palm.signal.call.service"

nr() { printf '%s\n' "$1" | novacom run file://bin/sh; }

nr "mount -o remount,rw / 2>/dev/null || true
for s in $SERVICES; do
  if [ -f $DBS/\$s ]; then mv $DBS/\$s $DBS/\$s.disabled && echo \"  neutered \$s\"; fi
done
mount -o remount,ro / 2>/dev/null || true
echo 'done — reboot so ls-hubd drops the neutered services from its catalog.'"
