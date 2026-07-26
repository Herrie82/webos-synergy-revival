#!/bin/sh
# neuter-activation-services.sh
#
# Disable the on-demand LS2/DBus ACTIVATION services for the IM transport so ONLY the upstart-resident
# daemon ever runs. Run after any deploy that (re)installs these files; a reboot is needed afterwards
# for ls-hubd to drop them from its cached service catalog.
#
# WHY: imlibpurpletransport is meant to run as a single RESIDENT daemon, started by upstart via
# /var/imdaemon.sh (which exports IM_RESIDENT=1 so it does NOT self-terminate on idle). Several
# DBus activation .service files also name it:
#   com.palm.imlibpurple.service        (Exec=imlibpurpleservice, the main one)
#   com.palm.{whatsapp,telegram,signal}.call.service  (Exec=imlibpurpletransport, for VoIP)
# When a client calls one of the .CALL bus names while the resident transport is briefly busy, ls-hubd
# ACTIVATES the .service and spawns a SECOND, non-resident transport that collides with the resident:
#   LunaService-CRITICAL: Attempted to register for a service name that already exists: com.palm.imlibpurple
# and dies. Voice calling does NOT need the .call activation services — the resident transport registers
# com.palm.whatsapp.call itself (in-plugin, glue/call.c) — so the .call ones are pure liability. Neuter them.
#
# *** DO NOT neuter com.palm.imlibpurple.service (the MAIN messaging service). *** It was neutered once
# (9519c97) to chase the churn, and that BROKE ALL OUTGOING messages + reactions: the activitymanager
# fires the "pending messages/commands" watch activities by CALLING palm://com.palm.imlibpurple/sendIM
# and /sendCommand; with the service file gone, ls-hubd rejects that call
#   ls-hubd-CRITICAL: Service not listed in service files: "com.palm.imlibpurple" (requester activitymanager)
# so sendIM/sendCommand never fire, the outbound activities get torn down (their callback fails), and
# immessage/imcommand rows sit folder=outbox status=pending forever (INCOMING still works, masking it as
# a plugin bug). The churn it was meant to fix is actually driven by transport CRASHES (fix those, e.g.
# the Teams trouter flood), not by this service — with the resident up it just routes to the live one.
#
# NEVER kill -9 the transport (corrupts the PmLog init semaphore) — SIGTERM / stop imtransport only.

set -e
DBS=/usr/share/dbus-1/system-services
# ONLY the .call activation services. NOT com.palm.imlibpurple.service (see the block above).
SERVICES="com.palm.whatsapp.call.service com.palm.telegram.call.service com.palm.signal.call.service"

nr() { printf '%s\n' "$1" | novacom run file://bin/sh; }

nr "mount -o remount,rw / 2>/dev/null || true
for s in $SERVICES; do
  if [ -f $DBS/\$s ]; then mv $DBS/\$s $DBS/\$s.disabled && echo \"  neutered \$s\"; fi
done
mount -o remount,ro / 2>/dev/null || true
echo 'done — reboot so ls-hubd drops the neutered services from its catalog.'"
